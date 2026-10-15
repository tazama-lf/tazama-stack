#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Maintainer check (README.md, section 8): for core, extensions and biar,
# compares the ${TAZAMA_*} references in the compose files and env files with
# the keys in secrets.env.template and with the "Original default values"
# table in the group README, in both directions. Also checks that each
# reference uses the fail-fast form matching the template tag:
# [required] -> ${KEY:?...}, [optional] -> ${KEY?...}.
# Keys defined in the group's .env (plain configuration, e.g. TAZAMA_VERSION)
# are ignored. Exit code 0 = consistent, 1 = mismatches.
#
# Usage: bash utils/check-secrets-template.sh

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

# Prints a titled list of unique lines from stdin; counts them as failures.
finding() {
    local title=$1 lines
    lines=$(grep -v '^$' | sort -u)
    [[ -z "$lines" ]] && return
    failures=$((failures + $(printf '%s\n' "$lines" | wc -l)))
    echo "  $title"
    printf '%s\n' "$lines" | sed 's/^/    /'
}

for group in core extensions biar; do
    dir="$repo_root/$group"
    echo "[$group]"

    # Template keys with their tag: "KEY 1" (required) or "KEY 0" (optional)
    template=$(tr -d '\r' < "$dir/secrets.env.template" | awk -v req=1 '
        /^[[:space:]]*#.*\[optional\]/ { req = 0; next }
        /^[[:space:]]*#.*\[required\]/ { req = 1; next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { sub(/^[[:space:]]*/, ""); sub(/=.*/, ""); print $0, req }
    ')
    template_keys=$(printf '%s\n' "$template" | cut -d' ' -f1 | sort -u)

    # Plain configuration keys from .env
    config_keys=""
    [[ -f "$dir/.env" ]] && config_keys=$(tr -d '\r' < "$dir/.env" | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' | tr -d ' =' | sort -u)

    # References "FILE KEY MODIFIER" in compose files and env files; comment lines skipped
    files=("$dir"/docker-compose*.yaml)
    [[ -d "$dir/env" ]] && files+=("$dir"/env/*.env)
    [[ -f "$dir/.env" ]] && files+=("$dir/.env")
    refs=$(for f in "${files[@]}"; do
        tr -d '\r' < "$f" | grep -v '^[[:space:]]*#' \
            | grep -oE '(^|[^$])\$\{TAZAMA_[A-Z0-9_]+[^}]*\}' \
            | sed -E 's/^[^$]?\$\{(TAZAMA_[A-Z0-9_]+)([^}]*)\}$/\1 \2/' \
            | while read -r key modifier; do
                printf '%s\n' "$config_keys" | grep -qx "$key" && continue
                printf '%s %s %s\n' "$(basename "$f")" "$key" "${modifier:-none}"
            done
    done)
    ref_keys=$(printf '%s\n' "$refs" | awk 'NF { print $2 }' | sort -u)

    # README "Original default values" table rows starting with | `TAZAMA_...`
    readme_keys=$(tr -d '\r' < "$dir/README.md" | awk '
        /^#+[[:space:]]/ { in_table = ($0 ~ /Original default values/); next }
        in_table && match($0, /^\|[[:space:]]*`TAZAMA_[A-Z0-9_]+`/) {
            s = substr($0, RSTART, RLENGTH); gsub(/^\|[[:space:]]*`|`$/, "", s); print s
        }' | sort -u)

    finding 'Referenced but not in secrets.env.template:' < <(comm -23 <(printf '%s\n' "$ref_keys") <(printf '%s\n' "$template_keys"))
    finding 'In secrets.env.template but never referenced:' < <(comm -13 <(printf '%s\n' "$ref_keys") <(printf '%s\n' "$template_keys"))
    finding 'Reference form:' < <(printf '%s\n' "$refs" | while read -r file key modifier; do
        [[ -z "$key" ]] && continue
        case "$modifier" in
            :\?*) form=1 ;;
            \?*) form=0 ;;
            *) echo "$key in $file: not in fail-fast form"; continue ;;
        esac
        tag=$(printf '%s\n' "$template" | awk -v k="$key" '$1 == k { print $2 }')
        if [[ -n "$tag" && "$tag" != "$form" ]]; then
            [[ "$tag" == 1 ]] && tag=required || tag=optional
            echo "$key in $file: template says [$tag], reference differs"
        fi
    done)
    finding 'In secrets.env.template but not in the README defaults table:' < <(comm -23 <(printf '%s\n' "$template_keys") <(printf '%s\n' "$readme_keys"))
    finding 'In the README defaults table but not in secrets.env.template:' < <(comm -13 <(printf '%s\n' "$template_keys") <(printf '%s\n' "$readme_keys"))
done

echo ""
if [[ $failures -eq 0 ]]; then
    echo "Secrets templates are consistent."
    exit 0
fi
echo "$failures mismatch(es)."
exit 1
