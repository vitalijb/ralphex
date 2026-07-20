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
command -v bob >/dev/null 2>&1 || { echo "error: bob is required but not found" >&2; exit 1; }

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
RALPHEX_EXPECT_SIGNAL="${RALPHEX_EXPECT_SIGNAL:-}"

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

if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
    if [[ -z "$RALPHEX_EXPECT_SIGNAL" ]]; then
        if [[ "$prompt" == *"<<<RALPHEX:PLAN_READY>>>"* ]]; then
            RALPHEX_EXPECT_SIGNAL="PLAN_READY"
        elif [[ "$prompt" == *"<<<RALPHEX:PLAN_DRAFT>>>"* ]]; then
            RALPHEX_EXPECT_SIGNAL="PLAN_DRAFT"
        elif [[ "$prompt" == *"<<<RALPHEX:QUESTION>>>"* ]]; then
            RALPHEX_EXPECT_SIGNAL="QUESTION"
        fi
    fi
    plan_adapter=$'Ralphex plan adapter for Bob:\n- Follow the prompt workflow exactly.\n- Your response is invalid unless it contains the exact required ralphex signal marker for this turn.\n- If planning work is requested, emit <<<RALPHEX:PLAN_DRAFT>>> before any plan body text and emit <<<RALPHEX:END>>> after the draft body.\n- If the user is answering an uncertainty, emit <<<RALPHEX:QUESTION>>> only when the workflow requires it.\n- If the plan file has already been accepted and written, emit <<<RALPHEX:PLAN_READY>>>.\n- Do not replace, rename, or omit any <<<RALPHEX:...>>> marker.'
    if [[ -n "$RALPHEX_EXPECT_SIGNAL" ]]; then
        plan_adapter+=$'\n- Required signal for this turn: <<<RALPHEX:'"$RALPHEX_EXPECT_SIGNAL"$'>>>.'
    fi
    prompt="$plan_adapter"$'\n\n'"$prompt"
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

stderr_file="$tmp_dir/stderr"
stdout_pipe="$tmp_dir/stdout.fifo"
completion_file="$tmp_dir/completion"
: > "$completion_file"
mkfifo "$stdout_pipe"
prompt_file="$tmp_dir/prompt"
printf '%s' "$prompt" > "$prompt_file"

# forward termination to bob while jq drains the named pipe in the background.
bob_pid=""
forward_signal() {
    if [[ -n "$bob_pid" ]]; then
        kill -TERM "$bob_pid" 2>/dev/null || true
    fi
    exit 143
}
trap forward_signal TERM

bob "${bob_args[@]}" < "$prompt_file" 2>"$stderr_file" > "$stdout_pipe" &
bob_pid=$!

# translate bob events into claude-compatible text deltas and terminal results.
jq -Rcn --unbuffered --argjson verbose "$BOB_VERBOSE" --arg completion_file "$completion_file" '
    def emit($t): {type: "content_block_delta", delta: {type: "text_delta", text: $t}};
    def append_completion($text):
        ($text + "\u0000")
        | @sh
        | "printf %s " + . + " >> " + ($completion_file | @sh)
        | system;
    inputs | fromjson? | objects |
        if .type == "tool_use" and (.tool_name // "") == "attempt_completion" then
            ((.parameters.result // "") | tostring) as $completion
            | append_completion($completion)
            | (($completion | split("\n")) as $parts
            | if ($parts[-1] // "") == "" then
                $parts[0:-1][] | emit(. + "\n")
              else
                $parts[] | emit(. + "\n")
              end)
        elif .type == "result" then
            {type: "result", result: ""}
        elif $verbose == 1 and .type == "tool_result" and (.status // "") == "success" then
            emit(("[tool_result] " + ((.output // "") | tostring) + "\n"))
        elif .type == "tool_result" and (.status // "") == "error" then
            emit(("[tool_error] " + ((.output // "") | tostring) + "\n"))
        elif $verbose == 1 and .type == "tool_use" then
            emit(("[tool] " + ((.tool_name // "") | tostring) + "\n"))
        else
            emit("")
        end
' < "$stdout_pipe" 2>/dev/null &
jq_pid=$!
wait "$jq_pid" || true

# preserve bob's exit status after the translation process has drained.
bob_exit=0
wait "$bob_pid" || bob_exit=$?
trap - TERM
bob_pid=""

# forward stderr for executor error detection, but neutralize signal-looking text.
if [[ -s "$stderr_file" ]]; then
    while IFS= read -r err_line || [[ -n "$err_line" ]]; do
        [[ -z "$err_line" ]] && continue
        err_line="${err_line//<<<RALPHEX:/<<< RALPHEX:}"
        printf '%s\n' "$err_line" \
            | jq -Rc '{type: "content_block_delta", delta: {type: "text_delta", text: (. + "\n")}}'
    done < "$stderr_file"
fi

if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
    completion_text=$(tr '\0' '\n' < "$completion_file")
    case "$RALPHEX_EXPECT_SIGNAL" in
        PLAN_DRAFT)
            [[ "$completion_text" == *"<<<RALPHEX:PLAN_DRAFT>>>"* ]] || {
                echo "error: ralphex-plan response missing required signal <<<RALPHEX:PLAN_DRAFT>>>" >&2
                exit 1
            }
            [[ "$completion_text" == *"<<<RALPHEX:END>>>"* ]] || {
                echo "error: ralphex-plan response missing required signal <<<RALPHEX:END>>>" >&2
                exit 1
            }
            ;;
        PLAN_READY)
            [[ "$completion_text" == *"<<<RALPHEX:PLAN_READY>>>"* ]] || {
                echo "error: ralphex-plan response missing required signal <<<RALPHEX:PLAN_READY>>>" >&2
                exit 1
            }
            ;;
        QUESTION)
            [[ "$completion_text" == *"<<<RALPHEX:QUESTION>>>"* ]] || {
                echo "error: ralphex-plan response missing required signal <<<RALPHEX:QUESTION>>>" >&2
                exit 1
            }
            ;;
        "")
            if [[ "$completion_text" != *"<<<RALPHEX:QUESTION>>>"* &&
                  "$completion_text" != *"<<<RALPHEX:PLAN_DRAFT>>>"* &&
                  "$completion_text" != *"<<<RALPHEX:PLAN_READY>>>"* ]]; then
                echo "error: ralphex-plan response missing required ralphex plan signal" >&2
                exit 1
            fi
            ;;
        *)
            echo "error: unsupported RALPHEX_EXPECT_SIGNAL value: $RALPHEX_EXPECT_SIGNAL" >&2
            exit 1
            ;;
    esac
fi

echo '{"type":"result","result":""}'
exit "$bob_exit"
