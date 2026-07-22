#!/usr/bin/env bash
# install the shipped ralphex modes into Bob's global custom-mode document.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode_dir="$script_dir/modes"
if [[ -n "${BOB_CUSTOM_MODES_FILE:-}" ]]; then
    target="$BOB_CUSTOM_MODES_FILE"
else
    canonical_target="${HOME:?HOME is required}/.bob/settings/custom_modes.yaml"
    legacy_target="$HOME/.bob/custom_modes.yaml"
    if [[ ! -e "$canonical_target" && -e "$legacy_target" ]]; then
        target="$legacy_target"
    else
        target="$canonical_target"
    fi
fi
target_dir="$(dirname "$target")"
modes=(ralphex-task ralphex-review ralphex-plan)

error() {
    echo "error: $*" >&2
    exit 1
}

# accept a conservative yaml subset with one top-level customModes sequence.
# rejecting unsupported yaml features is preferable to replacing a document
# whose syntax cannot be proved safe without adding a runtime yaml dependency.
document_is_safe() {
    local file="$1"
    local wanted_slug="${2:-}"
    if [[ ! -s "$file" ]]; then
        [[ -z "$wanted_slug" ]]
        return
    fi
    awk -v wanted_slug="$wanted_slug" '
        function indentation(line) {
            match(line, /^[ ]*/)
            return RLENGTH
        }
        function trimmed(value) {
            sub(/^[ ]+/, "", value)
            sub(/[ ]+$/, "", value)
            return value
        }
        function is_hex(char) {
            return char ~ /^[0-9A-Fa-f]$/
        }
        function valid_double_quoted(value, i, length_value, char, escaped, count, j) {
            length_value = length(value)
            if (length_value < 2 || substr(value, length_value, 1) != "\"") return 0
            for (i = 2; i < length_value; i++) {
                char = substr(value, i, 1)
                if (char == "\"") return 0
                if (char != "\\") continue
                if (i + 1 >= length_value) return 0
                i++
                escaped = substr(value, i, 1)
                if (escaped == "x") count = 2
                else if (escaped == "u") count = 4
                else if (escaped == "U") count = 8
                else if (escaped == "0" || escaped == "a" || escaped == "b" ||
                         escaped == "t" || escaped == "n" || escaped == "v" ||
                         escaped == "f" || escaped == "r" || escaped == "e" ||
                         escaped == " " || escaped == "\"" || escaped == "/" ||
                         escaped == "\\" || escaped == "N" || escaped == "_" ||
                         escaped == "L" || escaped == "P") count = 0
                else return 0
                if (i + count >= length_value) return 0
                for (j = 1; j <= count; j++) {
                    if (!is_hex(substr(value, i + j, 1))) return 0
                }
                i += count
            }
            return 1
        }
        function valid_single_quoted(value, i, length_value, quote) {
            quote = sprintf("%c", 39)
            length_value = length(value)
            if (length_value < 2 || substr(value, length_value, 1) != quote) return 0
            for (i = 2; i < length_value; i++) {
                if (substr(value, i, 1) != quote) continue
                if (i + 1 >= length_value || substr(value, i + 1, 1) != quote) return 0
                i++
            }
            return 1
        }
        function scalar_text(value, first, i) {
            value = trimmed(value)
            first = substr(value, 1, 1)
            if (first == "\"" || first == sprintf("%c", 39)) return value
            for (i = 2; i <= length(value); i++) {
                if (substr(value, i, 1) == "#" &&
                    substr(value, i - 1, 1) == " ") {
                    return trimmed(substr(value, 1, i - 1))
                }
            }
            return value
        }
        function scalar_kind(value, first) {
            value = scalar_text(value)
            if (value == "") return 1
            if (value ~ /^[|>][+-]?$/) return 2
            first = substr(value, 1, 1)
            if (first == "\"") return valid_double_quoted(value) ? 3 : 0
            if (first == sprintf("%c", 39)) return valid_single_quoted(value) ? 3 : 0
            if (first == "|" || first == ">" ||
                index("[]{}&,*!%@`#", first) != 0) return 0
            if (value ~ /^[-?:]([[:space:]]|$)/ ||
                value ~ /:([[:space:]]|$)/ ||
                value ~ /[[:space:]]#/) return 0
            return 3
        }
        function slug_value(value, first) {
            value = scalar_text(value)
            first = substr(value, 1, 1)
            if (first == "\"" || first == sprintf("%c", 39)) {
                return substr(value, 2, length(value) - 2)
            }
            return value
        }
        function parse_field(text, indent, separator, key, value, kind, id) {
            separator = index(text, ":")
            if (separator < 2) {
                invalid = 1
                return
            }
            key = substr(text, 1, separator - 1)
            value = substr(text, separator + 1)
            if (key !~ /^[A-Za-z][A-Za-z0-9]*$/) {
                invalid = 1
                return
            }
            id = mode_count SUBSEP key
            if (seen_keys[id]) {
                invalid = 1
                return
            }
            seen_keys[id] = 1
            kind = scalar_kind(value)
            if (kind == 0) {
                invalid = 1
                return
            }
            if (key == "slug") {
                value = slug_value(value)
                if (kind != 3 || value !~ /^[A-Za-z0-9-]+$/ ||
                    seen_slugs[value]) {
                    invalid = 1
                    return
                }
                seen_slugs[value] = 1
                mode_has_slug = 1
            }
            if (kind == 2) {
                block_indent = indent
                block_content_indent = -1
                sequence_indent = -1
            } else {
                block_indent = -1
                block_content_indent = -1
                sequence_indent = kind == 1 ? indent + 2 : -1
            }
        }
        function finish_restricted_group() {
            if (restricted_group && !restriction_has_regex) invalid = 1
            restricted_group = 0
            restricted_item_indent = -1
            restricted_field_indent = -1
            restriction_has_regex = 0
            restriction_id++
        }
        function parse_restriction_field(text, indent, separator, key, value, kind) {
            separator = index(text, ":")
            if (separator < 2) {
                invalid = 1
                return
            }
            key = substr(text, 1, separator - 1)
            value = substr(text, separator + 1)
            restriction_key = restriction_id SUBSEP key
            if ((key != "fileRegex" && key != "description") ||
                restriction_keys[restriction_key]) {
                invalid = 1
                return
            }
            restriction_keys[restriction_key] = 1
            kind = scalar_kind(value)
            if (kind == 0 || kind == 1) {
                invalid = 1
                return
            }
            if (key == "fileRegex") restriction_has_regex = 1
            if (kind == 2) {
                block_indent = indent
                block_content_indent = -1
            }
        }
        BEGIN {
            mode_indent = -1
            field_indent = -1
            block_indent = -1
            sequence_indent = -1
            restricted_item_indent = -1
            restricted_field_indent = -1
        }
        /\t/ {
            invalid = 1
            next
        }
        /^[[:space:]]*$/ { next }
        {
            current_indent = indentation($0)
            if (block_indent >= 0 && current_indent > block_indent) {
                if (block_content_indent < 0) {
                    block_content_indent = current_indent
                } else if (current_indent < block_content_indent) {
                    invalid = 1
                }
                next
            }
            block_indent = -1
            block_content_indent = -1
            if ($0 ~ /^[[:space:]]*#/) next
            if ($0 ~ /^customModes:[ ]*(\[\])?([ ]+#.*)?[ ]*$/) {
                if (seen_document || mode_count) invalid = 1
                seen_document = 1
                empty_sequence = $0 ~ /\[\]/
                next
            }
            if (!seen_document || empty_sequence ||
                $0 ~ /^[^[:space:]#]/) {
                invalid = 1
                next
            }
            if (restricted_group) {
                if (current_indent == restricted_item_indent &&
                    $0 ~ /^[ ]*-[ ]+/) {
                    parse_restriction_field(substr($0, current_indent + 3), restricted_field_indent)
                    next
                }
                if (current_indent == restricted_field_indent &&
                    $0 !~ /^[ ]*-[ ]+/) {
                    parse_restriction_field(substr($0, current_indent + 1), restricted_field_indent)
                    next
                }
                if (current_indent > sequence_indent) {
                    invalid = 1
                    next
                }
                finish_restricted_group()
            }
            if ($0 ~ /^[ ]*-[ ]+/) {
                if (mode_indent < 0) {
                    if (current_indent < 2) {
                        invalid = 1
                        next
                    }
                    mode_indent = current_indent
                    field_indent = mode_indent + 2
                }
                if (current_indent == mode_indent) {
                    if (mode_count && !mode_has_slug) invalid = 1
                    mode_count++
                    mode_has_slug = 0
                    sequence_indent = -1
                    parse_field(substr($0, current_indent + 3), field_indent)
                    next
                }
                if (current_indent == sequence_indent) {
                    item = substr($0, current_indent + 3)
                    if (scalar_text(item) == "- edit") {
                        finish_restricted_group()
                        restricted_group = 1
                        restricted_item_indent = current_indent + 2
                        restricted_field_indent = current_indent + 4
                        next
                    }
                    if (scalar_kind(item) != 3) invalid = 1
                    next
                }
                invalid = 1
                next
            }
            if (!mode_count || current_indent != field_indent) {
                invalid = 1
                next
            }
            parse_field(substr($0, current_indent + 1), field_indent)
        }
        END {
            finish_restricted_group()
            if (!seen_document || invalid ||
                (!empty_sequence && mode_count && !mode_has_slug)) exit 1
            if (wanted_slug != "" && !seen_slugs[wanted_slug]) exit 1
        }
    ' "$file"
}

has_slug() {
    local file="$1"
    local slug="$2"
    document_is_safe "$file" "$slug"
}

mode_indent() {
    local file="$1"
    awk '
        /^[ ]*-[ ]+[A-Za-z][A-Za-z0-9]*:/ {
            match($0, /^[ ]*/)
            print RLENGTH
            exit
        }
    ' "$file"
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

existing_mode_indent=$(mode_indent "$tmp_file")
if [[ -z "$existing_mode_indent" ]]; then
    existing_mode_indent=2
fi
printf -v mode_prefix '%*s' "$((existing_mode_indent - 2))" ''
for slug in "${missing[@]}"; do
    mode_file="$mode_dir/$slug.yaml"
    if [[ -s "$tmp_file" && -n "$(tail -c 1 "$tmp_file")" ]]; then
        printf '\n' >> "$tmp_file"
    fi
    awk -v prefix="$mode_prefix" 'NR > 1 { print prefix $0 }' \
        "$mode_file" >> "$tmp_file"
done

document_is_safe "$tmp_file" ||
    error "generated custom-mode document failed validation: $target"
mv -f "$tmp_file" "$target"
tmp_file=""
echo "installed ralphex modes in $target"
