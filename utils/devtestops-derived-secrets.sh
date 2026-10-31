#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Brings TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED in <group>/secrets.env up to
# date: TAZAMA_DEVTESTOPS_GITHUB_PAT encrypted with
# TAZAMA_DEVTESTOPS_ENCRYPTION_KEY and TAZAMA_DEVTESTOPS_ENCRYPTION_IV
# (AES-256-CBC, lowercase hex, no IV prefix), as rule-studio-devtestops
# decrypts it (GITHUB_TOKEN). The extensions launcher runs it before every
# deploy. Bash equivalent of utils/devtestops-derived-secrets.ps1; both
# produce identical values:
#   - PAT, key or IV empty: the token is emptied (the service does not start;
#     the deployment continues);
#   - all three set: key and IV lengths are checked, the token is derived and
#     its line rewritten when it differs (a missing line is added below the
#     inputs). Other lines, line endings and the file mode stay as they are;
#     the file is replaced atomically.
# The token only reaches openssl on stdin, never a command line, and no value
# is printed. Exit code 0 = up to date, 1 = cannot derive.
#
# Usage: bash utils/devtestops-derived-secrets.sh <group folder>

group_dir="${1:?usage: devtestops-derived-secrets.sh <group folder>}"
secrets="$group_dir/secrets.env"
token_key=TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED

if [[ ! -f "$secrets" ]]; then
    echo "secrets.env not found in $group_dir."
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

# Sets $found_index (-1 if absent) and $found_value for a key; KEY=VALUE lines
# are parsed like utils/audit-secrets.sh and the last one wins.
lookup() {
    local i value
    found_index=-1
    found_value=""
    for i in "${!lines[@]}"; do
        [[ "${lines[$i]}" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "${lines[$i]}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
        [[ "${BASH_REMATCH[1]}" == "$1" ]] || continue
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
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

last_index=-1
lookup TAZAMA_DEVTESTOPS_GITHUB_PAT; pat="$found_value"
[[ $found_index -gt $last_index ]] && last_index=$found_index
lookup TAZAMA_DEVTESTOPS_ENCRYPTION_KEY; key="$found_value"
[[ $found_index -gt $last_index ]] && last_index=$found_index
lookup TAZAMA_DEVTESTOPS_ENCRYPTION_IV; iv="$found_value"
[[ $found_index -gt $last_index ]] && last_index=$found_index
lookup "$token_key"; current="$found_value"; token_index=$found_index

if [[ -z "$pat" || -z "$key" || -z "$iv" ]]; then
    echo "rule-studio-devtestops will not start: TAZAMA_DEVTESTOPS_GITHUB_PAT, _ENCRYPTION_KEY and _ENCRYPTION_IV are not all set."
    [[ -z "$current" ]] && exit 0
    target=""
else
    if ! command -v openssl > /dev/null 2>&1; then
        echo "openssl not found - it is needed to derive the DevTestOps token in $secrets."
        exit 1
    fi
    key_hex=$(printf '%s' "$key" | to_hex)
    iv_hex=$(printf '%s' "$iv" | to_hex)
    problems=()
    [[ ${#key_hex} -ne 64 ]] && problems+=("TAZAMA_DEVTESTOPS_ENCRYPTION_KEY must be exactly 32 bytes (AES-256 key).")
    [[ ${#iv_hex} -ne 32 ]] && problems+=("TAZAMA_DEVTESTOPS_ENCRYPTION_IV must be exactly 16 bytes (AES IV).")
    if [[ ${#problems[@]} -gt 0 ]]; then
        echo "Cannot derive the DevTestOps token in $secrets:"
        printf '  %s\n' "${problems[@]}"
        exit 1
    fi
    target=$(printf '%s' "$pat" | openssl enc -aes-256-cbc -K "$key_hex" -iv "$iv_hex" | to_hex)
    if [[ -z "$target" ]]; then
        echo "Cannot compute $token_key: openssl failed."
        exit 1
    fi
    if [[ "$(printf '%s' "$current" | tr 'A-F' 'a-f')" == "$target" ]]; then
        echo "DevTestOps token in secrets.env matches TAZAMA_DEVTESTOPS_GITHUB_PAT."
        exit 0
    fi
fi

if [[ $token_index -ge 0 ]]; then
    lines[$token_index]="$token_key=$target"
else
    insert_at=$((last_index + 1))
    lines=("${lines[@]:0:$insert_at}" "$token_key=$target" "${lines[@]:$insert_at}")
fi

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
if [[ -n "$target" ]]; then
    echo "Updated $token_key in secrets.env (derived from TAZAMA_DEVTESTOPS_GITHUB_PAT)."
else
    echo "Emptied $token_key in secrets.env."
fi
exit 0
