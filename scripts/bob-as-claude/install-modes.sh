#!/usr/bin/env bash
# install the shipped ralphex modes into Bob's global custom-mode document,
# and optionally grant the approval settings headless bob v2 requires.
#
# usage:
#   install-modes.sh                    # install modes only (default)
#   install-modes.sh --grant-approvals  # also merge ~/.bob/settings/settings.json
#
# --grant-approvals broadens approval.allowed_permissions and the
# execute_command entry of approval.allowedExecutors for ALL bob usage on this
# machine, not just ralphex-invoked runs. It is opt-in on purpose.

set -euo pipefail

grant_approvals=0
for arg in "$@"; do
    case "$arg" in
        --grant-approvals) grant_approvals=1 ;;
        *)
            echo "error: unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

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

# both temp files are tracked from here, before any of them exists, so the trap
# covers every exit path — including --grant-approvals on the "modes already
# installed" branch, which returns before the mode temp file is ever created.
tmp_file=""
approval_tmp_file=""
cleanup() {
    if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
        rm -f "$tmp_file"
    fi
    if [[ -n "$approval_tmp_file" && -e "$approval_tmp_file" ]]; then
        rm -f "$approval_tmp_file"
    fi
    return 0
}
trap cleanup EXIT

# merge the approval settings headless bob v2 needs into settings.json.
# union-only: never removes existing entries, never touches deniedCommands,
# and is a no-op on a second run against the same input.
grant_approval_settings() {
    command -v jq >/dev/null 2>&1 ||
        error "jq is required for --grant-approvals"

    local approval_target
    if [[ -n "${BOB_SETTINGS_FILE:-}" ]]; then
        approval_target="$BOB_SETTINGS_FILE"
    else
        approval_target="${HOME:?HOME is required}/.bob/settings/settings.json"
    fi
    local approval_dir
    approval_dir="$(dirname "$approval_target")"

    if [[ -L "$approval_target" ]]; then
        error "refusing to replace symlink: $approval_target"
    fi
    if [[ -e "$approval_target" && ! -f "$approval_target" ]]; then
        error "approval-settings target is not a regular file: $approval_target"
    fi

    local existing_json
    if [[ -e "$approval_target" && -s "$approval_target" ]]; then
        # a document that is not an object, or whose approval block does not match
        # bob v2's schema, cannot be merged without guessing. Refuse up front
        # rather than letting the queries below abort with a raw jq type error
        # after the modes have already been installed.
        jq -e '
            type == "object" and
            ((.approval // {}) | type == "object") and
            (((.approval // {}).allowed_permissions // []) | type == "array") and
            (((.approval // {}).forbiddenApprovalGroups // []) | type == "array") and
            (((.approval // {}).allowedExecutors // []) |
                type == "array" and
                all(type == "object" and
                    ((.approvedCommands // []) | type == "array") and
                    ((.deniedCommands // []) | type == "array")))
        ' "$approval_target" >/dev/null 2>&1 ||
            error "cannot safely merge existing approval-settings document: $approval_target"
        existing_json="$(cat "$approval_target")"
    else
        existing_json='{}'
    fi

    # bob v2 stores allowedExecutors as an ARRAY of {toolId, approvedCommands,
    # deniedCommands} records and looks the executor up with Array.prototype.find,
    # so an object-shaped value makes every approval throw a TypeError. bob's
    # settings merge also does not recurse into arrays, which means a user-supplied
    # array REPLACES its read-only defaults wholesale — hence the trailing
    # read-only prefixes below, which restate the defaults the bare `git` prefix
    # does not already subsume.
    local wanted_permissions_json='["read","edit","execute","subagent","todo"]'
    local wanted_commands_json='["git","go","make","npm","npx","gofmt","golangci-lint","python3","cat","grep","head","tail","ls","sort","wc","which","du","df"]'

    # all five summary values come out of one jq pass, NUL-separated, so a merge
    # costs one jq process instead of five (same pattern as parse_bob_event in
    # bob-as-claude.sh). Values are joined lists or booleans and never contain NUL.
    local added_permissions added_commands auto_approval_was_absent
    local auto_approval_disabled forbidden_conflicts
    {
        IFS= read -r -d '' added_permissions &&
            IFS= read -r -d '' added_commands &&
            IFS= read -r -d '' auto_approval_was_absent &&
            IFS= read -r -d '' auto_approval_disabled &&
            IFS= read -r -d '' forbidden_conflicts
    } < <(
        jq -j --argjson wanted_permissions "$wanted_permissions_json" \
              --argjson wanted_commands "$wanted_commands_json" '
            ((.approval.allowed_permissions // []) as $existing
             | [$wanted_permissions[] | select(. as $p | ($existing | index($p)) == null)]
             | join(", ")), "\u0000",
            (((.approval.allowedExecutors // [])
                | map(select(.toolId == "execute_command"))
                | first | .approvedCommands // []) as $existing
             | [$wanted_commands[] | select(. as $c | ($existing | index($c)) == null)]
             | join(", ")), "\u0000",
            ((((.approval // {}) | has("autoApprovalEnabled")) | not) | tostring), "\u0000",
            ((((.approval // {}).autoApprovalEnabled) == false) | tostring), "\u0000",
            ((.approval.forbiddenApprovalGroups // []) as $forbidden
             | [$forbidden[] | select(. as $f | ($wanted_permissions | index($f)) != null)]
             | join(", ")), "\u0000"
        ' <<<"$existing_json"
    )

    local updated_json
    updated_json=$(jq --argjson wanted_permissions "$wanted_permissions_json" \
                       --argjson wanted_commands "$wanted_commands_json" '
        .approval = (.approval // {})
        | .approval.allowed_permissions =
            (((.approval.allowed_permissions // []) + $wanted_permissions) | unique)
        | .approval.autoApprovalEnabled =
            (if (.approval | has("autoApprovalEnabled"))
             then .approval.autoApprovalEnabled
             else true end)
        | .approval.allowedExecutors = (
            (.approval.allowedExecutors // []) as $executors
            | ($executors | map(.toolId) | index("execute_command")) as $idx
            | if $idx == null then
                  $executors + [{
                      toolId: "execute_command",
                      approvedCommands: ($wanted_commands | unique),
                      deniedCommands: []
                  }]
              else
                  $executors
                  | .[$idx] = (.[$idx]
                      | .approvedCommands =
                          (((.approvedCommands // []) + $wanted_commands) | unique)
                      | .deniedCommands = (.deniedCommands // []))
              end
          )
    ' <<<"$existing_json")

    if [[ -n "$forbidden_conflicts" ]]; then
        echo "warning: approval.forbiddenApprovalGroups already contains: $forbidden_conflicts" \
             "— those groups override the corresponding grant even after this change" >&2
    fi
    if [[ "$auto_approval_disabled" == "true" ]]; then
        echo "warning: approval.autoApprovalEnabled is false in $approval_target" \
             "— bob refuses every auto-approval while it stays false, so this grant" \
             "has no effect until you set it to true" >&2
    fi

    # compare canonicalized single-line forms rather than shelling out to diff:
    # only equality matters here, and the merge is union-only so key order is the
    # sole cosmetic difference `jq -S` has to absorb.
    if [[ "$(jq -Sc . <<<"$existing_json")" == "$(jq -Sc . <<<"$updated_json")" ]]; then
        echo "approval settings already granted in $approval_target"
        return
    fi

    mkdir -p "$approval_dir"
    if [[ -e "$approval_target" ]]; then
        if [[ -L "$approval_target.bak" ]]; then
            error "refusing to write backup through symlink: $approval_target.bak"
        fi
        cp -p "$approval_target" "$approval_target.bak"
    fi

    # the document came out of jq, but the file about to replace the user's real
    # settings is what matters: a short write (full disk, interrupted printf) would
    # install a truncated document. Validate the temp file, not the string.
    local approval_tmp
    approval_tmp=$(mktemp "$approval_dir/.settings.json.tmp.XXXXXX")
    approval_tmp_file="$approval_tmp"
    printf '%s\n' "$updated_json" > "$approval_tmp"
    jq -e . "$approval_tmp" >/dev/null 2>&1 ||
        error "generated approval-settings document failed validation: $approval_target"
    mv -f "$approval_tmp" "$approval_target"
    approval_tmp_file=""

    echo "granted approval settings in $approval_target:"
    [[ -n "$added_permissions" ]] && echo "  added permissions: $added_permissions"
    [[ "$auto_approval_was_absent" == "true" ]] && echo "  set autoApprovalEnabled: true (was unset)"
    [[ -n "$added_commands" ]] && echo "  added command prefixes: $added_commands"
    echo "  warning: broadening approvedCommands affects all bob usage on this machine, not just ralphex"
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
    if [[ "$grant_approvals" -eq 1 ]]; then
        grant_approval_settings
    fi
    exit 0
fi

mkdir -p "$target_dir"
tmp_file=$(mktemp "$target_dir/.custom_modes.yaml.tmp.XXXXXX")

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

if [[ "$grant_approvals" -eq 1 ]]; then
    grant_approval_settings
fi
