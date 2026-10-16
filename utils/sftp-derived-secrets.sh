#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Brings the two values derived from TAZAMA_SFTP_PASSWORD in
# <group>/secrets.env up to date (#302):
#   TAZAMA_SFTP_PASSWORD_HASH          - SHA-512 crypt hash for the atmoz/sftp
#                                        user definition (user:<hash>:e:1001)
#   TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED - connection-studio's encrypted SFTP
#                                        password (AES-256-CBC, ivHex:cipherHex)
# The extensions launcher runs it before every deploy. Bash equivalent of
# utils/sftp-derived-secrets.ps1, with the same deterministic salt and IV, so
# both produce identical values:
#   - a value that already matches the password is kept (also a hand-made one);
#   - an empty, missing or stale value is derived again and its line rewritten
#     (the hash single-quoted); a missing line is added below
#     TAZAMA_SFTP_PASSWORD. Other lines, line endings and the file mode stay
#     as they are; the file is replaced atomically.
# The password only reaches openssl on stdin, never a command line, and no
# value is printed. Where openssl has no 'passwd -6' (LibreSSL on macOS), the
# hash is computed by perl in the atmoz/sftp image, again with the password
# on stdin. Exit code 0 = up to date, 1 = cannot derive.
#
# Usage: bash utils/sftp-derived-secrets.sh <group folder>

group_dir="${1:?usage: sftp-derived-secrets.sh <group folder>}"
secrets="$group_dir/secrets.env"
hash_key=TAZAMA_SFTP_PASSWORD_HASH
cipher_key=TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED
hash_re='^\$6\$(rounds=([0-9]+)\$)?([^$:]{1,16})\$[./0-9A-Za-z]{86}$'
itoa='./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

if [[ ! -f "$secrets" ]]; then
    echo "secrets.env not found in $group_dir."
    exit 1
fi
if ! command -v openssl > /dev/null 2>&1; then
    echo "openssl not found - it is needed to derive the SFTP values in $secrets."
    exit 1
fi

# Lines without their CR; the line ending style and the final newline are
# restored on write. Plain indexed arrays only (bash 3.2 on macOS). CR is
# held in a variable: $'\r' inside a double-quoted ${line%...} is taken
# literally by bash 5.2.
cr=$'\r'
lines=()
eol=$'\n'
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"$cr" ]] && eol=$'\r\n'
    lines+=("${line%"$cr"}")
done < "$secrets"
final_eol=0
[[ "$(tail -c 1 "$secrets" | od -An -tx1 | tr -d ' \n')" == 0a ]] && final_eol=1

# Sets $found_index (-1 if absent), $found_value and $found_squoted (0/1) for
# a key; KEY=VALUE lines are parsed like utils/audit-secrets.sh and the last
# one wins.
lookup() {
    local i value
    found_index=-1
    found_value=""
    found_squoted=0
    for i in "${!lines[@]}"; do
        [[ "${lines[$i]}" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "${lines[$i]}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
        [[ "${BASH_REMATCH[1]}" == "$1" ]] || continue
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        found_squoted=0
        [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]] && found_squoted=1
        if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
            value="${value:1:${#value}-2}"
        fi
        found_index=$i
        found_value="$value"
    done
}

to_hex() {
    od -An -v -tx1 | tr -d ' \n'
}

# SHA-512 crypt of $password with a salt spec ("<salt>" or "rounds=<n>$<salt>").
# MSYS_NO_PATHCONV=1: Git Bash would otherwise rewrite a salt that starts
# with '/' into a Windows path before it reaches openssl or docker.
crypt6() {
    local out
    if [[ "$1" != rounds=* ]] \
        && out=$(printf '%s\n' "$password" | MSYS_NO_PATHCONV=1 openssl passwd -6 -salt "$1" -stdin 2> /dev/null) \
        && [[ "${out%"$cr"}" == '$6$'* ]]; then
        printf '%s' "${out%"$cr"}"
        return 0
    fi
    command -v docker > /dev/null 2>&1 || return 1
    out=$(printf '%s' "$password" | MSYS_NO_PATHCONV=1 docker run --rm -i --entrypoint perl atmoz/sftp \
        -e 'local $/; my $p = <STDIN>; print crypt($p, q($6$) . $ARGV[0] . q($))' "$1" 2> /dev/null) || return 1
    [[ "$out" == '$6$'* ]] || return 1
    printf '%s' "$out"
}

lookup TAZAMA_SFTP_PASSWORD; password="$found_value"; password_index=$found_index
lookup TAZAMA_ENRICHMENT_ENCRYPTION_KEY; enc_key="$found_value"
key_hex=$(printf '%s' "$enc_key" | to_hex)
problems=()
if [[ -z "$password" ]]; then
    problems+=("TAZAMA_SFTP_PASSWORD is missing or empty.")
elif [[ $(printf '%s' "$password" | wc -c) -gt 15 ]]; then
    problems+=("TAZAMA_SFTP_PASSWORD must be at most 15 bytes (connection-studio decrypts longer values incorrectly).")
fi
if [[ ${#key_hex} -ne 64 ]]; then
    problems+=("TAZAMA_ENRICHMENT_ENCRYPTION_KEY must be exactly 32 bytes (AES-256 key).")
fi
if [[ ${#problems[@]} -gt 0 ]]; then
    echo "Cannot derive the SFTP values in $secrets:"
    printf '  %s\n' "${problems[@]}"
    exit 1
fi

update_keys=()
update_values=()

lookup "$hash_key"
hash_ok=0
if [[ $found_squoted == 1 && "$found_value" =~ $hash_re ]]; then
    spec="${BASH_REMATCH[3]}"
    [[ -n "${BASH_REMATCH[1]}" ]] && spec="rounds=${BASH_REMATCH[2]}\$$spec"
    computed=$(crypt6 "$spec") && [[ "$computed" == "$found_value" ]] && hash_ok=1
fi
if [[ $hash_ok == 0 ]]; then
    salt=""
    for b in $(printf '%s' "sftp-hash-salt:$enc_key$password" | openssl dgst -sha256 -binary | od -An -v -tu1 -N16); do
        salt="$salt${itoa:$((b & 63)):1}"
    done
    if [[ ${#salt} -ne 16 ]] || ! new_hash=$(crypt6 "$salt"); then
        echo "Cannot compute $hash_key: this openssl has no 'passwd -6' (needs OpenSSL 1.1.1 or later) and Docker is not available."
        exit 1
    fi
    update_keys+=("$hash_key")
    update_values+=("'$new_hash'")
fi

lookup "$cipher_key"
payload="$found_value"
iv="${payload%%:*}"
cipher_hex="${payload#*:}"
cipher_ok=0
if [[ "$payload" == *:* && ${#iv} -eq 32 && -n "$cipher_hex" && $(( ${#cipher_hex} % 32 )) -eq 0 && "$iv$cipher_hex" =~ ^[0-9a-fA-F]+$ ]] \
    && result=$(printf "$(printf '%s' "$cipher_hex" | sed 's/../\\x&/g')" | openssl enc -d -aes-256-cbc -K "$key_hex" -iv "$iv" 2> /dev/null && printf x) \
    && [[ "${result%x}" == "$password" ]]; then
    cipher_ok=1
fi
if [[ $cipher_ok == 0 ]]; then
    iv=$(printf '%s' "$enc_key$password" | openssl dgst -sha256 -binary | to_hex)
    iv="${iv:0:32}"
    cipher_hex=$(printf '%s' "$password" | openssl enc -aes-256-cbc -K "$key_hex" -iv "$iv" | to_hex)
    if [[ ${#iv} -ne 32 || -z "$cipher_hex" ]]; then
        echo "Cannot compute $cipher_key: openssl failed."
        exit 1
    fi
    update_keys+=("$cipher_key")
    update_values+=("$iv:$cipher_hex")
fi

if [[ ${#update_keys[@]} -eq 0 ]]; then
    echo "SFTP values in secrets.env match TAZAMA_SFTP_PASSWORD."
    exit 0
fi

insert_at=$((password_index + 1))
for i in "${!update_keys[@]}"; do
    lookup "${update_keys[$i]}"
    if [[ $found_index -ge 0 ]]; then
        lines[$found_index]="${update_keys[$i]}=${update_values[$i]}"
    else
        lines=("${lines[@]:0:$insert_at}" "${update_keys[$i]}=${update_values[$i]}" "${lines[@]:$insert_at}")
        insert_at=$((insert_at + 1))
    fi
done

# Write a copy (cp -p keeps the mode) in the same folder, then rename it over
# secrets.env.
tmp=$(mktemp "$group_dir/.secrets.env.XXXXXX") || exit 1
if ! { cp -p "$secrets" "$tmp" && {
        for i in "${!lines[@]}"; do
            [[ $i -gt 0 ]] && printf '%s' "$eol"
            printf '%s' "${lines[$i]}"
        done
        [[ $final_eol == 1 ]] && printf '%s' "$eol"
        true
    } > "$tmp" && mv -f "$tmp" "$secrets"; }; then
    rm -f "$tmp"
    echo "Writing $secrets failed."
    exit 1
fi
for k in "${update_keys[@]}"; do
    echo "Updated $k in secrets.env (derived from TAZAMA_SFTP_PASSWORD)."
done
exit 0
