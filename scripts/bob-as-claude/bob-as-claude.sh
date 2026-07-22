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

# Bob only exposes attempt_completion when intermediary output is hidden. In plan
# mode that is not sufficient: Bob may print a valid QUESTION / PLAN_DRAFT as an
# assistant message, then replace it with a prose summary in attempt_completion.
# Tell it which channel is authoritative, and keep intermediary deltas available
# as a recovery path if it still fails to follow the terminal-tool contract.
if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
    plan_adapter=$'BOB/RALPHEX PLAN PROTOCOL (strict):\n- Never emit QUESTION, PLAN_DRAFT, PLAN_READY, or TASK_FAILED as ordinary assistant prose.\n- When a plan boundary is ready, call attempt_completion exactly once and put the complete boundary in its result argument.\n- QUESTION result must be exactly <<<RALPHEX:QUESTION>>> followed by one valid JSON object and <<<RALPHEX:END>>>; include no summary or surrounding prose.\n- PLAN_DRAFT result must be exactly the complete <<<RALPHEX:PLAN_DRAFT>>> body through <<<RALPHEX:END>>>; include no trailing prose.\n- PLAN_READY result must be exactly <<<RALPHEX:PLAN_READY>>>. TASK_FAILED result must be exactly <<<RALPHEX:TASK_FAILED>>>.\n- Do not append questions, answers, drafts, markers, or status text to the ralphex progress file; ralphex alone owns that log.\n- Once you call attempt_completion, stop.'
    prompt="$plan_adapter"$'\n\n'"$prompt"
fi

# build bob arguments. the prompt is delivered through stdin, not argv. Task and
# review runs retain the clean terminal-only stream. Plan runs expose assistant
# deltas so the wrapper can stop on a valid boundary before Bob's forced
# "you must use a tool" continuation discards it.
bob_args=("--chat-mode=$selected_chat_mode" --output-format=stream-json)
[[ "$selected_chat_mode" != "ralphex-plan" ]] && bob_args+=(--hide-intermediary-output)
bob_args+=(--yolo --trust)
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
# before placing review-only guard shims on PATH, so only nested launches are
# rejected. Absolute paths can bypass PATH, so the custom mode also forbids all
# shell-based agent orchestration explicitly.
if [[ "$selected_chat_mode" == "ralphex-review" ]]; then
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
    export PATH="$review_guard_dir:$PATH"
fi

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

emit_text_delta() {
    jq -cn --arg text "$1" \
        '{type: "content_block_delta", delta: {type: "text_delta", text: $text}}'
}

emit_keepalive() {
    printf '%s\n' '{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}'
}

# Remove complete Bob thinking sections before looking for protocol markers.
# An unfinished thinking section is hidden as well, so marker examples in model
# reasoning can never become plan boundaries.
strip_thinking_blocks() {
    local text="$1"
    local before=""
    local rest=""
    local after=""

    while [[ "$text" == *"<thinking>"* ]]; do
        before=${text%%"<thinking>"*}
        rest=${text#*"<thinking>"}
        if [[ "$rest" != *"</thinking>"* ]]; then
            text="$before"
            break
        fi
        after=${rest#*"</thinking>"}
        text="$before$after"
    done
    printf '%s' "$text"
}

plan_boundary_text=""
plan_boundary_error=""
extract_plan_boundary() {
    local text="$1"
    local marker=""
    local rest=""
    local body=""
    local candidate=""
    local candidate_pos=-1
    local pos=-1
    local current=""
    local prefix=""

    plan_boundary_text=""
    plan_boundary_error=""

    for marker in '<<<RALPHEX:QUESTION>>>' '<<<RALPHEX:PLAN_DRAFT>>>'; do
        [[ "$text" == *"$marker"* ]] || continue
        rest=${text#*"$marker"}
        [[ "$rest" == *'<<<RALPHEX:END>>>'* ]] || continue
        body=${rest%%'<<<RALPHEX:END>>>'*}
        current="$marker$body<<<RALPHEX:END>>>"
        prefix=${text%%"$marker"*}
        pos=${#prefix}

        if [[ "$marker" == '<<<RALPHEX:QUESTION>>>' ]]; then
            if ! printf '%s' "$body" | jq -e '
                type == "object" and
                (.question | type == "string" and length > 0) and
                (.options | type == "array" and length > 0) and
                all(.options[]; type == "string" and length > 0)
            ' >/dev/null 2>&1; then
                plan_boundary_error="invalid QUESTION payload from Bob"
                continue
            fi
        elif [[ -z "${body//[[:space:]]/}" ]]; then
            plan_boundary_error="empty PLAN_DRAFT payload from Bob"
            continue
        fi

        if [[ $candidate_pos -lt 0 || $pos -lt $candidate_pos ]]; then
            candidate="$current"
            candidate_pos=$pos
        fi
    done

    for marker in '<<<RALPHEX:PLAN_READY>>>' '<<<RALPHEX:TASK_FAILED>>>'; do
        [[ "$text" == *"$marker"* ]] || continue
        prefix=${text%%"$marker"*}
        pos=${#prefix}
        if [[ $candidate_pos -lt 0 || $pos -lt $candidate_pos ]]; then
            candidate="$marker"
            candidate_pos=$pos
        fi
    done

    [[ $candidate_pos -ge 0 ]] || return 1
    plan_boundary_text="$candidate"
    return 0
}

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

intentional_stop=0
plan_boundary_emitted=0
bob_failure_detail_emitted=0
bob_result_failed=0

neutralize_signal_text() {
    printf '%s' "${1//<<<RALPHEX:/<<< RALPHEX:}"
}

emit_completion_lines() {
    local completion="$1"
    local completion_line=""

    while IFS= read -r completion_line || [[ -n "$completion_line" ]]; do
        emit_text_delta "$completion_line"$'\n'
    done < <(printf '%s' "$completion")
}

bob_start_seconds=$SECONDS
# Merge Bob's descriptors before translation so one reader preserves live ordering
# without concurrent JSON writers. Non-JSON lines are treated as diagnostics.
"$bob_executable" "${bob_args[@]}" < "$prompt_file" > "$stream_pipe" 2>&1 &
bob_pid=$!

plan_stream_buffer=""
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
            if extract_plan_boundary "$visible_plan_text"; then
                emit_text_delta "$plan_boundary_text"
                plan_boundary_emitted=1
                intentional_stop=1
                kill -TERM "$bob_pid" 2>/dev/null || true
                break
            fi
        elif [[ "$event_type" == "tool_use" && "$event_tool" == "attempt_completion" ]]; then
            if extract_plan_boundary "$event_completion"; then
                emit_text_delta "$plan_boundary_text"
                plan_boundary_emitted=1
                intentional_stop=1
                kill -TERM "$bob_pid" 2>/dev/null || true
                break
            fi
            [[ -n "$plan_boundary_error" ]] || \
                plan_boundary_error="attempt_completion did not contain a complete valid ralphex plan boundary"
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
        printf '%s\n' '{"type":"result","result":""}'
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
    [[ -n "$plan_boundary_error" ]] || plan_boundary_error="Bob exited without a complete ralphex plan boundary"
    emit_text_delta "error: $plan_boundary_error"$'\n'
    bob_exit=1
fi

# Bob occasionally exits non-zero after going silent without emitting any diagnostic.
# Preserve the exit code and add enough context for ralphex progress logs to be useful.
if [[ "$bob_exit" -ne 0 && "$bob_failure_detail_emitted" == "0" ]]; then
    bob_elapsed_seconds=$((SECONDS - bob_start_seconds))
    emit_text_delta "error: bob exited with status $bob_exit after ${bob_elapsed_seconds}s without diagnostic output"$'\n'
fi

echo '{"type":"result","result":""}'
exit "$bob_exit"
