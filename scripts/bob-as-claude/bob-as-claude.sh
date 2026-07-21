#!/usr/bin/env bash
# bob-as-claude.sh - wraps IBM Bob Shell CLI to produce Claude-compatible stream-json output.
#
# this script translates bob's stream-json event stream into the Claude stream-json format
# that ralphex's ClaudeExecutor can parse.
#
# environment variables:
#   BOB_CHAT_MODE  - explicit bob chat-mode slug override (default: automatic)
#   BOB_MODEL      - model to use when --model is absent
#   BOB_VERBOSE    - set to 1 to include tool_result output and tool markers (default: 0)
#   BOB_EXTRA_ARGS - extra bob arguments, word-split on whitespace
#   BOB_REVIEW_GUARD - how to block nested agent CLI invocations in review mode
#                    values: "path" (default), "bwrap" (if available), "none"

set -euo pipefail

# verify required commands before doing any prompt work.
command -v jq >/dev/null 2>&1 || { echo "error: jq is required but not found" >&2; exit 1; }
if ! bob_executable=$(command -v bob); then
    echo "error: bob is required but not found" >&2
    exit 1
fi

# accept prompts through stdin, with -p retained for direct invocations.
prompt=""
model_flag=""
effort_flag=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)       prompt="${2:-}"; shift; shift 2>/dev/null || true ;;
        --model)  model_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        --model=*) model_flag="${1#*=}"; shift ;;
        --effort) effort_flag="${2:-}"; shift; shift 2>/dev/null || true ;;
        --effort=*) effort_flag="${1#*=}"; shift ;;
        *)        shift ;;
    esac
done

if [[ -z "$prompt" && ! -t 0 ]]; then
    prompt=$(cat)
fi
if [[ -z "$prompt" ]]; then
    echo "error: no prompt provided (expected -p flag or stdin)" >&2
    exit 1
fi

# load environment configuration.
BOB_CHAT_MODE="${BOB_CHAT_MODE:-}"
BOB_MODEL="${BOB_MODEL:-}"
BOB_VERBOSE="${BOB_VERBOSE:-0}"
BOB_REVIEW_GUARD="${BOB_REVIEW_GUARD:-path}"
if [[ "$BOB_VERBOSE" != "0" && "$BOB_VERBOSE" != "1" ]]; then
    echo "warning: BOB_VERBOSE must be 0 or 1, got '$BOB_VERBOSE', defaulting to 0" >&2
    BOB_VERBOSE=0
fi
BOB_EXTRA_ARGS="${BOB_EXTRA_ARGS:-}"

# resolve the model and retain the existing effort compatibility note.
model="$model_flag"
[[ -z "$model" ]] && model="$BOB_MODEL"
if [[ -n "$effort_flag" ]]; then
    echo "note: bob has no --effort flag; ignoring '$effort_flag'" >&2
fi

# classify unconfigured prompts outside fenced code blocks. explicit overrides are
# intentionally unrestricted so users can select built-in or installed custom slugs.
selected_chat_mode="$BOB_CHAT_MODE"
if [[ -z "$selected_chat_mode" ]]; then
    selected_chat_mode=$(printf '%s\n' "$prompt" | awk '
        function fence_run(line, char, i, leading) {
            leading = 0
            while (substr(line, leading + 1, 1) == " ") leading++
            if (leading > 3 || substr(line, leading + 1, 1) == "\t") return 0
            line = substr(line, leading + 1)
            char = substr(line, 1, 1)
            if (char != "`" && char != "~") return 0
            for (i = 1; substr(line, i, 1) == char; i++) { }
            candidate_char = char
            candidate_rest = substr(line, i)
            return i - 1
        }
        {
            run = fence_run($0)
            if (run >= 3) {
                if (!in_fence) {
                    if (candidate_char != "`" || candidate_rest !~ /`/) {
                        in_fence = 1
                        fence_char = candidate_char
                        fence_length = run
                        next
                    }
                } else if (candidate_char == fence_char &&
                           run >= fence_length &&
                           candidate_rest ~ /^[[:space:]]*$/) {
                    in_fence = 0
                    fence_char = ""
                    fence_length = 0
                }
                if (in_fence || candidate_rest ~ /^[[:space:]]*$/) next
            }
        }
        !in_fence && /^[[:space:]]*## Step 2: Launch (ALL 5 )?Review Agents IN PARALLEL[[:space:]]*$/ { review = 1 }
        !in_fence && /^[[:space:]]*Use the Task tool( with model=[^[:space:]]+)? to launch a [^[:space:]]+ agent with this prompt:[[:space:]]*$/ { review = 1 }
        !in_fence && /<<<RALPHEX:QUESTION>>>/ { question = 1 }
        !in_fence && /<<<RALPHEX:PLAN_DRAFT>>>/ { draft = 1 }
        !in_fence && /<<<RALPHEX:PLAN_READY>>>/ { ready = 1 }
        END {
            if (review) print "ralphex-review"
            else if (question && draft && ready) print "ralphex-plan"
            else print "ralphex-task"
        }
    ')
fi

# build bob arguments. the prompt is delivered through stdin, not argv.
bob_args=("--chat-mode=$selected_chat_mode" --output-format=stream-json --hide-intermediary-output --yolo --trust)
[[ -n "$model" ]] && bob_args+=(-m "$model")
if [[ -n "$BOB_EXTRA_ARGS" ]]; then
    read -ra bob_extra_args <<< "$BOB_EXTRA_ARGS"
    for arg in "${bob_extra_args[@]}"; do
        [[ -n "$arg" ]] && bob_args+=("$arg")
    done
fi

# keep temporary files together so cleanup is one private directory operation.
tmp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

# Review prompts ask Claude-compatible providers to launch multiple sub-agents.
# Bob has no native sub-agent orchestration, and may try to emulate it by
# spawning bob/claude/codex through its command tool. Those nested CLIs inherit
# credentials and can outlive a timed-out tool call, exhaust provider limits,
# or deadlock the parent session. Resolve the real top-level Bob executable
# before placing any guard, so only nested launches are rejected.
#
# Two guard strategies:
#   "path"  - prepend a directory with guard shims for bob/claude/codex to PATH.
#             Cheap and effective for PATH lookups, but can be bypassed with absolute paths.
#   "bwrap" - run bob inside a bwrap sandbox with PATH-shims only.
#             Prevents PATH-based nested launches from reaching real binaries.
#             Requires bwrap; if unavailable falls back to "path".
#   "none"  - disable guard entirely (use only if you trust the model and provider).
if [[ "$selected_chat_mode" == "ralphex-review" && "$BOB_REVIEW_GUARD" != "none" ]]; then
    review_guard_dir="$tmp_dir/review-agent-guard"
    mkdir -p "$review_guard_dir"
    for guarded_cli in bob claude codex; do
        guard_path="$review_guard_dir/$guarded_cli"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'tool_name=${0##*/}' \
            'printf '\''error: nested %s invocation blocked by bob-as-claude review guard; perform review assignments sequentially in the current Bob session\n'\'' "$tool_name" >&2' \
            'exit 64' > "$guard_path"
        chmod +x "$guard_path"
    done
    if [[ "$BOB_REVIEW_GUARD" == "bwrap" ]] && command -v bwrap >/dev/null 2>&1; then
        # bwrap will be applied around bob below.
        use_bwrap_guard=1
    else
        if [[ "$BOB_REVIEW_GUARD" == "bwrap" ]]; then
            echo "warning: bwrap not found, falling back to PATH guard" >&2
        fi
        export PATH="$review_guard_dir:$PATH"
        use_bwrap_guard=0
    fi
fi

# named pipe carrying bob's combined stdout+stderr so one reader preserves live ordering.
stream_pipe="$tmp_dir/stream.fifo"
mkfifo "$stream_pipe"
prompt_file="$tmp_dir/prompt"
printf '%s' "$prompt" > "$prompt_file"

# forward termination to bob while the translated stream drains.
bob_pid=""
forward_signal() {
    if [[ -n "$bob_pid" ]]; then
        kill -TERM "$bob_pid" 2>/dev/null || true
    fi
    exit 143
}
trap forward_signal TERM

# emit helpers that write claude-compatible JSONL to stdout.
emit_text_delta() {
    jq -cn --arg text "$1" \
        '{type: "content_block_delta", delta: {type: "text_delta", text: $text}}'
}

emit_keepalive() {
    jq -cn '{type: "content_block_delta", delta: {type: "text_delta", text: ""}}'
}

emit_result() {
    echo '{"type":"result","result":""}'
}

# strip <thinking> ... </thinking> blocks so internal reasoning does not leak into
# plan boundary detection.
strip_thinking_blocks() {
    local text="$1"
    while [[ "$text" == *"<thinking"*"<"* ]]; do
        local before="${text%%<thinking*}"
        local rest="${text#*<thinking}"
        # find the matching closing tag; simple approach handles one level.
        if [[ "$rest" == *"</thinking"*"<"* ]]; then
            local after="${rest#*</thinking}"
            text="$before${after#*>}"
        else
            break
        fi
    done
    printf '%s' "$text"
}

# parse a single line of JSON into bash variables. returns 1 on malformed input.
# extracted fields:
#   event_type, event_role, event_content, event_tool, event_completion,
#   event_status, event_output, event_error, event_has_error
parse_bob_event() {
    local line="$1"
    event_type=""
    event_role=""
    event_content=""
    event_tool=""
    event_completion=""
    event_status=""
    event_output=""
    event_error=""
    event_has_error="false"

    # fast path: skip jq if the line is obviously not a JSON object.
    case "$line" in
        {*}) ;;
        *) return 1 ;;
    esac

    {
        IFS= read -r -d '' event_type &&
            IFS= read -r -d '' event_role &&
            IFS= read -r -d '' event_content &&
            IFS= read -r -d '' event_tool &&
            IFS= read -r -d '' event_completion &&
            IFS= read -r -d '' event_status &&
            IFS= read -r -d '' event_output &&
            IFS= read -r -d '' event_error &&
            IFS= read -r -d '' event_has_error
    } < <(
        printf '%s\n' "$line" | jq -j '
            (.type // ""), "\u0000",
            (.role // ""), "\u0000",
            ((.content // "") | tostring), "\u0000",
            (.tool_name // ""), "\u0000",
            ((.parameters.result // "") | tostring), "\u0000",
            ((.status // "") | tostring), "\u0000",
            ((.output // "") | tostring), "\u0000",
            ((.error.message // .error // .message // "") | tostring), "\u0000",
            ((.error != null) | tostring), "\u0000"
        ' 2>/dev/null
    )
}

# neutralize literal ralphex signal markers in diagnostic text so ralphex cannot
# mistake stderr/stream noise for a real completion signal.
neutralize_signal_text() {
    printf '%s' "${1//<<<RALPHEX:/<<< RALPHEX:}"
}

# emit the result field of attempt_completion, splitting on newlines and
# preserving them as separate content_block_delta events.
emit_completion_lines() {
    local completion="$1"
    local completion_line=""

    while IFS= read -r completion_line || [[ -n "$completion_line" ]]; do
        emit_text_delta "$completion_line"$'\n'
    done < <(printf '%s' "$completion")
}

# plan mode state
intentional_stop=0
plan_boundary_emitted=0
plan_stream_buffer=""
bob_failure_detail_emitted=0
bob_result_failed=0

bob_start_seconds=$SECONDS

# plan helper: emit the buffered plan text and stop reading.
emit_plan_and_stop() {
    local plan_text="$1"
    emit_completion_lines "$plan_text"
    plan_boundary_emitted=1
    intentional_stop=1
}

# Merge Bob's descriptors before translation so one reader preserves live ordering
# without concurrent JSON writers. Non-JSON lines are treated as diagnostics.
if [[ "${use_bwrap_guard:-0}" == "1" ]]; then
    # Construct PATH that puts /guard first and excludes the system directories
    # that contain real bob/claude/codex binaries. This prevents a nested command
    # from reaching the real executables while preserving the rest of the PATH.
    guarded_path="/guard:$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -vxE '^/usr/bin$|^/bin$|^/usr/local/bin$' | paste -sd:)"
    bwrap \
        --ro-bind "$review_guard_dir" /guard \
        --bind "$tmp_dir" /tmp-ralphex \
        --ro-bind /usr /usr \
        --ro-bind /bin /bin \
        --ro-bind /lib /lib \
        --ro-bind /lib64 /lib64 \
        --ro-bind /etc /etc \
        --proc /proc \
        --dev /dev \
        --unshare-pid \
        --new-session \
        --setenv PATH "$guarded_path" \
        "$bob_executable" "${bob_args[@]}" < "$prompt_file" > "$stream_pipe" 2>&1 &
else
    "$bob_executable" "${bob_args[@]}" < "$prompt_file" > "$stream_pipe" 2>&1 &
fi
bob_pid=$!

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    if ! parse_bob_event "$line" || [[ -z "$event_type" ]]; then
        sanitized_line=$(neutralize_signal_text "$line")
        emit_text_delta "$sanitized_line"$'\n'
        case "${line,,}" in
            *error*|*failed*|*failure*|*limit*|*auth*|*required*|*timeout*|*exception*)
                bob_failure_detail_emitted=1
                ;;
        esac
        continue
    fi

    if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
        if [[ "$event_type" == "message" && "$event_role" == "assistant" ]]; then
            plan_stream_buffer+="$event_content"
            visible_plan_text=$(strip_thinking_blocks "$plan_stream_buffer")
            if [[ "$visible_plan_text" == *"<<<RALPHEX:"*"END>>>"* ]]; then
                emit_plan_and_stop "$plan_stream_buffer"
                break
            fi
        elif [[ "$event_type" == "tool_use" && "$event_tool" == "attempt_completion" ]]; then
            # attempt_completion in plan mode can carry the full plan boundary.
            # Use it directly (not the stream buffer) so we emit exactly what bob produced.
            plan_completion_text="$event_completion"
            visible_plan_text=$(strip_thinking_blocks "$plan_completion_text")
            if [[ "$visible_plan_text" == *"<<<RALPHEX:"*"END>>>"* ]]; then
                emit_plan_and_stop "$plan_completion_text"
                break
            fi
            # A QUESTION-only completion is a legitimate intermediate step; emit it
            # and keep reading so the next completion can carry the full boundary.
            emit_completion_lines "$plan_completion_text"
        fi
        emit_keepalive
        continue
    fi

    # Task/review translation stays terminal-only and line-oriented.
    if [[ "$event_type" == "tool_use" && "$event_tool" == "attempt_completion" ]]; then
        emit_completion_lines "$event_completion"
    elif [[ "$event_type" == "result" ]]; then
        if [[ "$event_has_error" == "true" || ( -n "$event_status" && "$event_status" != "success" ) ]]; then
            result_detail="$event_error"
            [[ -n "$result_detail" ]] || result_detail="status $event_status"
            result_detail=$(neutralize_signal_text "$result_detail")
            emit_text_delta "error: bob result failed: $result_detail"$'\n'
            bob_failure_detail_emitted=1
            bob_result_failed=1
        fi
        emit_result
    elif [[ "$event_type" == "tool_result" && "$event_status" == "error" ]]; then
        emit_text_delta "[tool_error] $event_output"$'\n'
        bob_failure_detail_emitted=1
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_result" && "$event_status" == "success" ]]; then
        emit_text_delta "[tool_result] $event_output"$'\n'
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_use" ]]; then
        emit_text_delta "[tool] $event_tool"$'\n'
    else
        emit_keepalive
    fi
done < "$stream_pipe"

# preserve bob's exit status after the translation process has drained.
bob_exit=0
wait "$bob_pid" || bob_exit=$?
trap - TERM
bob_pid=""

if [[ "$intentional_stop" == "1" ]]; then
    bob_exit=0
elif [[ "$bob_result_failed" == "1" && "$bob_exit" -eq 0 ]]; then
    bob_exit=1
fi

if [[ "$selected_chat_mode" == "ralphex-plan" && "$plan_boundary_emitted" == "0" ]]; then
    emit_text_delta "error: bob plan phase finished without emitting a complete ralphex plan boundary"$'\n'
    bob_exit=1
fi

# Bob occasionally exits non-zero after going silent without emitting any diagnostic.
if [[ "$bob_exit" -ne 0 && "$bob_failure_detail_emitted" == "0" ]]; then
    bob_elapsed_seconds=$((SECONDS - bob_start_seconds))
    emit_text_delta "error: bob exited with status $bob_exit after ${bob_elapsed_seconds}s without diagnostic output"$'\n'
fi

emit_result
exit "$bob_exit"
