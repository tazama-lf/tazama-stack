#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Audits <group>/secrets.env against <group>/secrets.env.template without
# printing any value. Reports keys that are missing, required but empty, or
# unknown, and checks that TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED decrypts to
# TAZAMA_SFTP_PASSWORD, that TAZAMA_SFTP_PASSWORD_HASH matches it, and that
# TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED is TAZAMA_DEVTESTOPS_GITHUB_PAT
# encrypted with the DevTestOps key and IV (these checks need openssl).
# [generated] keys may be empty or missing: the extensions launcher derives
# them before every deployment (utils/sftp-derived-secrets.sh,
# utils/devtestops-derived-secrets.sh).
# Exit code 0 = no findings, 1 = findings.
#
# Usage: bash utils/audit-secrets.sh <group folder>

group_dir="${1:?usage: audit-secrets.sh <group folder>}"
template="$group_dir/secrets.env.template"
secrets="$group_dir/secrets.env"

if [[ ! -f "$template" ]]; then
    echo "Template not found: $template"
    exit 1
fi
if [[ ! -f "$secrets" ]]; then
    echo "secrets.env not found in $group_dir."
    echo "Copy secrets.env.template to secrets.env and fill it in (README.md, section 6)."
    exit 1
fi

# Plain indexed arrays only, so the script also runs on bash 3.2 (macOS).

# Template: every KEY= line; the last [required]/[optional]/[generated] tag
# above it decides (template_required: 1 = required, 0 = optional,
# g = generated).
template_keys=()
template_required=()
is_required=1
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*#.*\[optional\] ]]; then is_required=0; continue; fi
    if [[ "$line" =~ ^[[:space:]]*#.*\[required\] ]]; then is_required=1; continue; fi
    if [[ "$line" =~ ^[[:space:]]*#.*\[generated\] ]]; then is_required=g; continue; fi
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        template_keys+=("${BASH_REMATCH[1]}")
        template_required+=("$is_required")
    fi
done < "$template"

# secrets.env: KEY=VALUE lines; surrounding quotes are stripped. Never sourced.
secret_keys=()
secret_values=()
secret_squoted=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        squoted=0
        [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]] && squoted=1
        if [[ ${#value} -ge 2 && ( ( "${value:0:1}" == '"' && "${value: -1}" == '"' ) || ( "${value:0:1}" == "'" && "${value: -1}" == "'" ) ) ]]; then
            value="${value:1:${#value}-2}"
        fi
        secret_keys+=("$key")
        secret_values+=("$value")
        secret_squoted+=("$squoted")
    fi
done < "$secrets"

# Sets $found (0/1), $found_value and $found_squoted (0/1) for a key; the last
# occurrence wins.
lookup_secret() {
    local i
    found=0
    found_value=""
    found_squoted=0
    for i in "${!secret_keys[@]}"; do
        if [[ "${secret_keys[$i]}" == "$1" ]]; then
            found=1
            found_value="${secret_values[$i]}"
            found_squoted="${secret_squoted[$i]}"
        fi
    done
}

in_template() {
    local k
    for k in "${template_keys[@]}"; do
        [[ "$k" == "$1" ]] && return 0
    done
    return 1
}

missing=()
empty=()
unknown=()
for i in "${!template_keys[@]}"; do
    lookup_secret "${template_keys[$i]}"
    if [[ $found -eq 0 ]]; then
        [[ "${template_required[$i]}" == g ]] || missing+=("${template_keys[$i]}")
    elif [[ "${template_required[$i]}" == 1 && -z "$found_value" ]]; then
        empty+=("${template_keys[$i]}")
    fi
done
for key in "${secret_keys[@]}"; do
    if ! in_template "$key"; then
        case " ${unknown[*]} " in *" $key "*) ;; *) unknown+=("$key") ;; esac
    fi
done

findings=0
print_list() {
    local title=$1
    shift
    [[ $# -eq 0 ]] && return
    findings=$((findings + $#))
    echo "$title:"
    printf '  %s\n' "$@"
    echo ""
}

echo "Auditing $secrets (values are never shown)"
echo ""
print_list "Missing keys (in the template, not in secrets.env)" "${missing[@]}"
print_list "Required keys with an empty value" "${empty[@]}"
print_list "Unknown keys (not in the template)" "${unknown[@]}"

cipher_key=TAZAMA_TCS_SFTP_PASSWORD_ENCRYPTED
if in_template "$cipher_key"; then
    lookup_secret "$cipher_key"; payload="$found_value"
    lookup_secret TAZAMA_SFTP_PASSWORD; expected="$found_value"
    lookup_secret TAZAMA_ENRICHMENT_ENCRYPTION_KEY; enc_key="$found_value"
    if [[ -n "$expected" && $(printf '%s' "$expected" | wc -c) -ge 16 ]]; then
        echo "SFTP password check FAILED: TAZAMA_SFTP_PASSWORD must be at most 15 bytes (connection-studio decrypts longer values incorrectly)."
        findings=$((findings + 1))
    fi
    if [[ -z "$expected" || -z "$enc_key" ]]; then
        echo "SFTP ciphertext check skipped: TAZAMA_SFTP_PASSWORD and TAZAMA_ENRICHMENT_ENCRYPTION_KEY must both be set."
        findings=$((findings + 1))
    elif [[ -z "$payload" ]]; then
        echo "SFTP ciphertext check skipped: $cipher_key is not generated yet. The extensions launcher derives it before the next deployment."
    elif ! command -v openssl > /dev/null 2>&1; then
        echo "SFTP ciphertext check skipped: openssl not found."
    else
        iv="${payload%%:*}"
        cipher_hex="${payload#*:}"
        key_hex=$(printf '%s' "$enc_key" | od -An -v -tx1 | tr -d ' \n')
        if [[ ${#key_hex} -ne 64 ]]; then
            echo "SFTP ciphertext check FAILED: TAZAMA_ENRICHMENT_ENCRYPTION_KEY is not exactly 32 bytes."
            findings=$((findings + 1))
        elif [[ "$payload" != *:* || ${#iv} -ne 32 || ! "$iv$cipher_hex" =~ ^[0-9a-fA-F]+$ || $(( ${#cipher_hex} % 2 )) -ne 0 ]]; then
            echo "SFTP ciphertext check FAILED: $cipher_key is not in <iv-hex>:<ciphertext-hex> format (16-byte IV)."
            findings=$((findings + 1))
        elif ! result=$(printf "$(printf '%s' "$cipher_hex" | sed 's/../\\x&/g')" | openssl enc -d -aes-256-cbc -K "$key_hex" -iv "$iv" 2> /dev/null && printf x); then
            echo "SFTP ciphertext check FAILED: cannot decrypt $cipher_key."
            findings=$((findings + 1))
        elif result="${result%x}"; [[ "$result" == "$expected" ]]; then
            echo "SFTP ciphertext check OK: $cipher_key decrypts to TAZAMA_SFTP_PASSWORD."
        else
            echo "SFTP ciphertext check FAILED: $cipher_key does not decrypt to TAZAMA_SFTP_PASSWORD. The extensions launcher derives it again before the next deployment."
            findings=$((findings + 1))
        fi
    fi
    echo ""
fi

hash_key=TAZAMA_SFTP_PASSWORD_HASH
hash_re='^\$6\$(rounds=([0-9]+)\$)?([^$:]{1,16})\$[./0-9A-Za-z]{86}$'
if in_template "$hash_key"; then
    lookup_secret "$hash_key"; hash="$found_value"; hash_squoted="$found_squoted"
    lookup_secret TAZAMA_SFTP_PASSWORD; expected="$found_value"
    if [[ -z "$expected" ]]; then
        echo "SFTP hash check skipped: TAZAMA_SFTP_PASSWORD must be set."
        findings=$((findings + 1))
    elif [[ -z "$hash" ]]; then
        echo "SFTP hash check skipped: $hash_key is not generated yet. The extensions launcher derives it before the next deployment."
    elif [[ "$hash_squoted" != 1 ]]; then
        echo "SFTP hash check FAILED: write $hash_key in single quotes ($hash_key='...'), or Compose expands its \$ signs. The extensions launcher rewrites it before the next deployment."
        findings=$((findings + 1))
    elif [[ ! "$hash" =~ $hash_re ]]; then
        echo "SFTP hash check FAILED: $hash_key is not a SHA-512 crypt hash (\$6\$<salt>\$<hash>). The extensions launcher derives it again before the next deployment."
        findings=$((findings + 1))
    elif [[ -n "${BASH_REMATCH[1]}" ]]; then
        echo "SFTP hash check skipped: hashes with rounds= are not supported by this check."
    elif ! command -v openssl > /dev/null 2>&1; then
        echo "SFTP hash check skipped: openssl not found."
    elif ! computed=$(printf '%s\n' "$expected" | MSYS_NO_PATHCONV=1 openssl passwd -6 -salt "${BASH_REMATCH[3]}" -stdin 2> /dev/null); then
        echo "SFTP hash check skipped: this openssl does not support 'passwd -6' (needs OpenSSL 1.1.1 or later)."
    elif [[ "${computed%$'\r'}" == "$hash" ]]; then
        echo "SFTP hash check OK: $hash_key matches TAZAMA_SFTP_PASSWORD."
    else
        echo "SFTP hash check FAILED: $hash_key does not match TAZAMA_SFTP_PASSWORD. The extensions launcher derives it again before the next deployment."
        findings=$((findings + 1))
    fi
    echo ""
fi

token_key=TAZAMA_DEVTESTOPS_GITHUB_TOKEN_ENCRYPTED
if in_template "$token_key"; then
    lookup_secret "$token_key"; token="$found_value"
    lookup_secret TAZAMA_DEVTESTOPS_GITHUB_PAT; pat="$found_value"
    lookup_secret TAZAMA_DEVTESTOPS_ENCRYPTION_KEY; dto_key="$found_value"
    lookup_secret TAZAMA_DEVTESTOPS_ENCRYPTION_IV; dto_iv="$found_value"
    dto_key_hex=$(printf '%s' "$dto_key" | od -An -v -tx1 | tr -d ' \n')
    dto_iv_hex=$(printf '%s' "$dto_iv" | od -An -v -tx1 | tr -d ' \n')
    if [[ -z "$pat" ]]; then
        echo "DevTestOps token check skipped: TAZAMA_DEVTESTOPS_GITHUB_PAT is not set (rule-studio-devtestops does not start)."
    elif [[ -z "$dto_key" || -z "$dto_iv" ]]; then
        echo "DevTestOps token check FAILED: TAZAMA_DEVTESTOPS_ENCRYPTION_KEY and TAZAMA_DEVTESTOPS_ENCRYPTION_IV must be set when TAZAMA_DEVTESTOPS_GITHUB_PAT is."
        findings=$((findings + 1))
    elif [[ ${#dto_key_hex} -ne 64 || ${#dto_iv_hex} -ne 32 ]]; then
        echo "DevTestOps token check FAILED: TAZAMA_DEVTESTOPS_ENCRYPTION_KEY must be exactly 32 bytes and TAZAMA_DEVTESTOPS_ENCRYPTION_IV exactly 16 bytes."
        findings=$((findings + 1))
    elif [[ -z "$token" ]]; then
        echo "DevTestOps token check skipped: $token_key is not generated yet. The extensions launcher derives it before the next deployment."
    elif ! command -v openssl > /dev/null 2>&1; then
        echo "DevTestOps token check skipped: openssl not found."
    elif ! expected_token=$(printf '%s' "$pat" | openssl enc -aes-256-cbc -K "$dto_key_hex" -iv "$dto_iv_hex" | od -An -v -tx1 | tr -d ' \n') || [[ -z "$expected_token" ]]; then
        echo "DevTestOps token check skipped: openssl failed."
    elif [[ "$(printf '%s' "$token" | tr 'A-F' 'a-f')" == "$expected_token" ]]; then
        echo "DevTestOps token check OK: $token_key matches TAZAMA_DEVTESTOPS_GITHUB_PAT."
    else
        echo "DevTestOps token check FAILED: $token_key does not match TAZAMA_DEVTESTOPS_GITHUB_PAT. The extensions launcher derives it again before the next deployment."
        findings=$((findings + 1))
    fi
    echo ""
fi

if [[ $findings -eq 0 ]]; then
    echo "No findings."
    exit 0
fi
echo "$findings finding(s)."
exit 1
