#!/usr/bin/env bash
# bob-as-claude.sh - wraps IBM Bob Shell CLI (v2.0.0+) to produce Claude-compatible stream-json output.
#
# this script translates bob v2's `bob run -f stream-json` event stream into the Claude
# stream-json format that ralphex's ClaudeExecutor can parse. bob 1.0.x is not supported.
#
# environment variables:
#   BOB_CHAT_MODE     - explicit bob --mode slug override (default: automatic)
#   BOB_MODEL         - model to accept for compatibility; bob v2 stable has no model
#                        selection, so the value is reported and ignored
#   BOB_VERBOSE       - set to 1 to include tool_result output, tool markers, and
#                        reasoning message text (default: 0)
#   BOB_EXTRA_ARGS    - extra bob arguments, word-split on whitespace
#   BOB_SETTINGS_FILE - override path to bob's global settings.json (used by tests)

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
BOB_SETTINGS_FILE="${BOB_SETTINGS_FILE:-$HOME/.bob/settings/settings.json}"

# bob v2 stable has no model selection (gated behind an internal dev gateway key), and
# has no --effort flag either. Accept both for compatibility with ralphex's per-phase
# model/effort flags and report that they are ignored rather than failing the run.
model="$model_flag"
[[ -z "$model" ]] && model="$BOB_MODEL"
if [[ -n "$model" ]]; then
    echo "note: bob v2 stable has no model selection; ignoring '$model'" >&2
fi
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

# Headless `bob run` registers no interactive approval handler; its only input is
# ~/.bob/settings/settings.json. Warn (never abort) when the settings bob v2 requires
# for edit/execute work are missing, so a hang or silent no-op has an explained cause.
approval_preflight() {
    # review mode drives native subagents, so it needs the subagent permission on
    # top of edit/execute. warning about it in task mode would be a false alarm.
    local needed_json='["edit","execute"]'
    if [[ "$selected_chat_mode" == "ralphex-review" ]]; then
        needed_json='["edit","execute","subagent"]'
    fi

    if [[ ! -f "$BOB_SETTINGS_FILE" ]]; then
        echo "warning: bob v2 approval settings not found at $BOB_SETTINGS_FILE; 'edit' and 'execute' actions require approvals bob does not grant by default. Run scripts/bob-as-claude/install-modes.sh --grant-approvals to grant them." >&2
        return 0
    fi

    local reason=""
    if ! reason=$(jq -r --argjson needed "$needed_json" '
        (.approval.allowed_permissions // []) as $perms |
        (.approval.forbiddenApprovalGroups // []) as $forbidden |
        (.approval.autoApprovalEnabled) as $auto |
        [$needed[] | select(. as $n | ($perms | index($n)) == null)] as $missing |
        [$needed[] | select(. as $n | ($forbidden | index($n)) != null)] as $blocked |
        if ($missing | length) > 0 then
            "allowed_permissions is missing " + ($missing | join(", "))
        elif ($auto == false) then
            "autoApprovalEnabled is false"
        elif ($blocked | length) > 0 then
            "forbiddenApprovalGroups blocks " + ($blocked | join(", "))
        else
            ""
        end
    ' "$BOB_SETTINGS_FILE" 2>/dev/null); then
        echo "warning: cannot read bob v2 approval settings at $BOB_SETTINGS_FILE; bob will fall back to its read-only defaults, which cannot approve 'edit' or 'execute'. Fix the file, or run scripts/bob-as-claude/install-modes.sh --grant-approvals" >&2
        return 0
    fi

    [[ -n "$reason" ]] && echo "warning: bob v2 approval settings may block task/review work ($reason); run scripts/bob-as-claude/install-modes.sh --grant-approvals to grant the needed approvals" >&2
    return 0
}
approval_preflight

# build bob arguments. the prompt is delivered through stdin, not argv. Never pass
# --disable-subagents: review mode relies on native subagent orchestration.
bob_args=(run -f stream-json "--mode=$selected_chat_mode" --trust)
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
    event_is_reasoning=""
    event_tool=""
    event_status=""
    event_output=""
    event_error_message=""
    event_message=""

    {
        IFS= read -r -d '' event_type &&
            IFS= read -r -d '' event_role &&
            IFS= read -r -d '' event_content &&
            IFS= read -r -d '' event_is_reasoning &&
            IFS= read -r -d '' event_tool &&
            IFS= read -r -d '' event_status &&
            IFS= read -r -d '' event_output &&
            IFS= read -r -d '' event_error_message &&
            IFS= read -r -d '' event_message
    } < <(
        printf '%s\n' "$line" | jq -j '
            (.type // ""), "\u0000",
            (.role // ""), "\u0000",
            ((.content // "") | tostring), "\u0000",
            ((.isReasoning // false) | tostring), "\u0000",
            (.tool_name // ""), "\u0000",
            ((.status // "") | tostring), "\u0000",
            ((.output // "") | tostring), "\u0000",
            ((.error.message? // .error? // "") | tostring), "\u0000",
            ((.message // "") | tostring), "\u0000"
        ' 2>/dev/null
    )
}

intentional_stop=0
plan_boundary_emitted=0
bob_failure_detail_emitted=0
bob_result_failed=0

# Text that did not come from the model's own answer is neutralized before it is
# forwarded, so a tool error or diagnostic that quotes a ralphex signal token cannot
# forge a real signal (ralphex matches signals as a plain substring). This is done
# with inline ${var//...} expansion rather than a helper, because routing buffered
# text through $(...) would strip the trailing newlines line buffering depends on.

# Line-buffers assistant message text so a signal token split across several
# streaming deltas is re-assembled and emitted intact in one content_block_delta.
# Answer and reasoning text share one buffer but are tracked by kind: switching
# kinds flushes the partial remainder so a newline-less reasoning chunk cannot
# splice itself into the next real answer line.
task_stream_buffer=""
task_stream_kind=""
flush_task_buffer_remainder() {
    if [[ -n "$task_stream_buffer" ]]; then
        emit_text_delta "$task_stream_buffer"
        task_stream_buffer=""
    fi
}
flush_task_buffer_lines() {
    local kind="$1"
    [[ "$task_stream_kind" == "$kind" ]] || flush_task_buffer_remainder
    task_stream_kind="$kind"
    task_stream_buffer+="$2"
    while [[ "$task_stream_buffer" == *$'\n'* ]]; do
        local line="${task_stream_buffer%%$'\n'*}"
        task_stream_buffer="${task_stream_buffer#*$'\n'}"
        emit_text_delta "$line"$'\n'
    done
}

bob_start_seconds=$SECONDS
# Merge Bob's descriptors before translation so one reader preserves live ordering
# without concurrent JSON writers. Non-JSON lines are treated as diagnostics.
"$bob_executable" "${bob_args[@]}" < "$prompt_file" > "$stream_pipe" 2>&1 &
bob_pid=$!

plan_stream_buffer=""
while IFS= read -r line || [[ -n "$line" ]]; do
    # a blank stream line still proves bob is alive; emit a keepalive so a long
    # quiet stretch does not look like an idle session to ralphex.
    if [[ -z "$line" ]]; then
        emit_keepalive
        continue
    fi

    if ! parse_bob_event "$line" || [[ -z "$event_type" ]]; then
        emit_text_delta "${line//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
        case "${line,,}" in
            *error*|*failed*|*failure*|*limit*|*auth*|*required*|*timeout*|*exception*)
                bob_failure_detail_emitted=1
                ;;
        esac
        continue
    fi

    if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
        if [[ "$event_type" == "message" && "$event_role" == "assistant" && "$event_is_reasoning" != "true" ]]; then
            plan_stream_buffer+="$event_content"
            if extract_plan_boundary "$plan_stream_buffer"; then
                emit_text_delta "$plan_boundary_text"
                plan_boundary_emitted=1
                intentional_stop=1
                kill -TERM "$bob_pid" 2>/dev/null || true
                break
            fi
        elif [[ "$event_type" == "error" ]]; then
            # {type:"error"} is bob v2's only failure channel (result.status is
            # always "success"), so plan runs must surface it too — a swallowed
            # rate-limit or auth message would otherwise be reported as a
            # missing plan boundary with no diagnostic.
            emit_text_delta "error: bob: ${event_message//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
            bob_failure_detail_emitted=1
            bob_result_failed=1
            continue
        fi
        emit_keepalive
        continue
    fi

    # Task/review translation forwards assistant message text line-by-line and
    # otherwise stays terminal-only.
    if [[ "$event_type" == "message" && "$event_role" == "assistant" ]]; then
        if [[ "$event_is_reasoning" == "true" ]]; then
            if [[ "$BOB_VERBOSE" == "1" ]]; then
                flush_task_buffer_lines reasoning "${event_content//<<<RALPHEX:/<<< RALPHEX:}"
            else
                emit_keepalive
            fi
        else
            flush_task_buffer_lines text "$event_content"
        fi
    elif [[ "$event_type" == "tool_result" && "$event_status" == "error" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "[tool_error] ${event_error_message//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
        bob_failure_detail_emitted=1
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_result" && "$event_status" == "success" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "[tool_result] ${event_output//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_use" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "[tool] ${event_tool//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
    elif [[ "$event_type" == "error" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "error: bob: ${event_message//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
        bob_failure_detail_emitted=1
        bob_result_failed=1
    else
        emit_keepalive
    fi
done < "$stream_pipe"

# flush any partial trailing line left in the task/review buffer. this runs before
# the single terminating result event below, so no buffered text lands after it.
flush_task_buffer_remainder

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
