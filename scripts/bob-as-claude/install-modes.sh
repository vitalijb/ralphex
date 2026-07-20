#!/usr/bin/env bash
# install the shipped ralphex modes into Bob's global custom-mode document.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode_dir="$script_dir/modes"
target="${BOB_CUSTOM_MODES_FILE:-${HOME:?HOME is required}/.bob/custom_modes.yaml}"
target_dir="$(dirname "$target")"
modes=(ralphex-task ralphex-review ralphex-plan)

error() {
    echo "error: $*" >&2
    exit 1
}

# accept only a top-level customModes sequence whose mode entries are indented
# consistently. rejecting uncertain documents prevents an atomic merge from
# silently damaging a user's configuration.
document_is_safe() {
    local file="$1"
    [[ ! -s "$file" ]] && return 0
    awk '
        BEGIN { mode_indent = -1 }
        function indentation(line) {
            match(line, /^[ ]*/)
            return RLENGTH
        }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        /^customModes:[[:space:]]*(\[\])?[[:space:]]*(#.*)?$/ {
            if (seen_document) invalid = 1
            seen_document = 1
            next
        }
        {
            if (!seen_document || $0 ~ /^[^[:space:]#]/ || $0 ~ /^\t/) {
                invalid = 1
                next
            }
            current_indent = indentation($0)
            if ($0 ~ /^[ ]*-[ ]+slug:[ ]*/) {
                if (mode_indent < 0) mode_indent = current_indent
                if (current_indent != mode_indent) invalid = 1
                mode_count++
                next
            }
            if (mode_indent < 0 || current_indent <= mode_indent) invalid = 1
        }
        END {
            if (!seen_document || invalid) exit 1
        }
    ' "$file"
}

has_slug() {
    local file="$1"
    local slug="$2"
    grep -Eq -- "^[[:space:]]*-[[:space:]]+slug:[[:space:]]*[\"']?${slug}[\"']?([[:space:]]|#|$)" "$file"
}

for slug in "${modes[@]}"; do
    mode_file="$mode_dir/$slug.yaml"
    [[ -f "$mode_file" ]] || error "shipped mode is missing: $mode_file"
    document_is_safe "$mode_file" || error "shipped mode is not a safe YAML document: $mode_file"
    has_slug "$mode_file" "$slug" || error "shipped mode slug does not match its filename: $mode_file"
done

if [[ -L "$target" ]]; then
    error "refusing to replace symlink: $target"
fi

if [[ -e "$target" && ! -f "$target" ]]; then
    error "custom-mode target is not a regular file: $target"
fi
if [[ -e "$target" ]]; then
    document_is_safe "$target" || error "cannot safely merge existing custom-mode document: $target"
fi

missing=()
if [[ ! -e "$target" || ! -s "$target" ]]; then
    missing=("${modes[@]}")
else
    for slug in "${modes[@]}"; do
        has_slug "$target" "$slug" || missing+=("$slug")
    done
fi

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "ralphex modes already installed in $target"
    exit 0
fi

mkdir -p "$target_dir"
tmp_file=$(mktemp "$target_dir/.custom_modes.yaml.tmp.XXXXXX")
cleanup() {
    if [[ -n "${tmp_file:-}" && -e "$tmp_file" ]]; then
        rm -f "$tmp_file"
    fi
}
trap cleanup EXIT

if [[ ! -e "$target" || ! -s "$target" ]]; then
    printf '%s\n' 'customModes:' > "$tmp_file"
else
    awk '
        /^customModes:[[:space:]]*\[\][[:space:]]*(#.*)?$/ { print "customModes:"; next }
        { print }
    ' "$target" > "$tmp_file"
fi

for slug in "${missing[@]}"; do
    mode_file="$mode_dir/$slug.yaml"
    if [[ -s "$tmp_file" && -n "$(tail -c 1 "$tmp_file")" ]]; then
        printf '\n' >> "$tmp_file"
    fi
    awk 'NR > 1 { print }' "$mode_file" >> "$tmp_file"
done

mv -f "$tmp_file" "$target"
tmp_file=""
echo "installed ralphex modes in $target"
