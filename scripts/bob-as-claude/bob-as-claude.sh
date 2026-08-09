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

# Tool access in headless `bob run` is governed by the mode's `groups` list plus
# `--trust` (and bob's own outside-workspace block). The `approval.*` settings in
# ~/.bob/settings/settings.json are read only by the interactive approval handler,
# which `bob run` never constructs, so there is nothing to preflight here.

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

# selection rule shared by the opening- and terminal-marker loops below: a marker
# that starts its own line is the real boundary and a mid-sentence one is narration,
# so any line-leading candidate outranks any non-leading one; within the same class
# the earliest occurrence wins (ralphex itself extracts leftmost-marker-to-nearest-END).
# Written as plain ifs rather than `[[ ]] && return 0` so it is safe under `set -e`
# regardless of call context. Args: pos leading best_pos best_leading.
plan_boundary_outranks() {
    local pos=$1 leading=$2 best_pos=$3 best_leading=$4
    if [[ $best_pos -lt 0 ]]; then
        return 0
    fi
    if [[ $best_leading -eq 0 && $leading -eq 1 ]]; then
        return 0
    fi
    if [[ $best_leading -eq $leading && $pos -lt $best_pos ]]; then
        return 0
    fi
    return 1
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
    local candidate_leading=0
    local open_pos=-1
    local open_inline_pos=-1
    local pos=-1
    local current=""
    local prefix=""
    local scan=""
    local consumed=0
    local leading=0
    local chosen_pos=-1
    local chosen_rest=""
    local chosen_leading=0
    local pending_error=""

    plan_boundary_text=""
    plan_boundary_error=""

    for marker in '<<<RALPHEX:QUESTION>>>' '<<<RALPHEX:PLAN_DRAFT>>>'; do
        [[ "$text" == *"$marker"* ]] || continue
        # Walk EVERY occurrence rather than binding to the first one. The plan
        # prompt teaches the model these exact tokens, so it may name a marker in
        # prose before emitting the real boundary; taking the first occurrence
        # would then start the body at the narration and swallow the real opening
        # marker into it. ralphex extracts leftmost-marker-to-nearest-END
        # (planDraftSignalRe in pkg/processor/phase/signals.go), so that
        # narration and a stray protocol token would reach the user as the draft.
        scan="$text"
        consumed=0
        chosen_pos=-1
        chosen_rest=""
        chosen_leading=0
        pending_error=""
        while [[ "$scan" == *"$marker"* ]]; do
            prefix=${scan%%"$marker"*}
            pos=$((consumed + ${#prefix}))
            rest=${scan#*"$marker"}
            consumed=$((pos + ${#marker}))
            scan="$rest"
            # markers are documented as standing on their own line, so a
            # line-leading occurrence is the real boundary and a mid-sentence one
            # is narration. Non-leading occurrences still qualify as a fallback,
            # keeping tolerance for a model that inlines the marker.
            if [[ $pos -eq 0 || "${text:pos-1:1}" == $'\n' ]]; then
                leading=1
            else
                leading=0
            fi
            if [[ "$rest" != *'<<<RALPHEX:END>>>'* ]]; then
                # this boundary may still be streaming. Remember where it opened
                # so a bare marker quoted inside its unterminated body cannot be
                # mistaken for a real terminal boundary below and discard the
                # whole draft. Tracked in two classes because an unterminated
                # marker never clears: a line-leading opening is certainly a real
                # boundary, so it suppresses any later terminal marker, while a
                # mid-sentence mention ("I considered asking via
                # <<<RALPHEX:QUESTION>>> but ...") may be pure narration and so
                # only suppresses an equally mid-sentence terminal marker. That
                # keeps benign narration from sinking every later PLAN_READY while
                # still protecting a draft the model opened inline.
                if [[ $leading -eq 1 ]] && [[ $open_pos -lt 0 || $pos -lt $open_pos ]]; then
                    open_pos=$pos
                fi
                if [[ $open_inline_pos -lt 0 || $pos -lt $open_inline_pos ]]; then
                    open_inline_pos=$pos
                fi
                continue
            fi
            body=${rest%%'<<<RALPHEX:END>>>'*}
            # validate here, inside the walk, rather than on the ranking winner
            # below: a malformed occurrence must only lose candidacy, not abandon
            # the whole marker type. plan_stream_buffer only grows, so the same bad
            # occurrence would keep winning the ranking on every later call and a
            # self-correcting model that re-emits a well-formed payload could never
            # recover. Remember the cause and keep walking; it is only reported if
            # no valid occurrence of this marker exists.
            if [[ "$marker" == '<<<RALPHEX:QUESTION>>>' ]]; then
                if ! printf '%s' "$body" | jq -e '
                    type == "object" and
                    (.question | type == "string" and length > 0) and
                    (.options | type == "array" and length > 0) and
                    all(.options[]; type == "string" and length > 0)
                ' >/dev/null 2>&1; then
                    pending_error="invalid QUESTION payload from Bob"
                    continue
                fi
            elif [[ -z "${body//[[:space:]]/}" ]]; then
                pending_error="empty PLAN_DRAFT payload from Bob"
                continue
            fi
            # same rule as the cross-marker choice below. The walk runs left to
            # right, so the earliest-within-class half never fires here; sharing the
            # helper keeps the two selections from drifting apart.
            if plan_boundary_outranks "$pos" "$leading" "$chosen_pos" "$chosen_leading"; then
                chosen_pos=$pos
                chosen_rest="$rest"
                chosen_leading=$leading
            fi
        done
        if [[ $chosen_pos -lt 0 ]]; then
            [[ -z "$pending_error" ]] || plan_boundary_error="$pending_error"
            continue
        fi
        pos=$chosen_pos
        rest="$chosen_rest"
        leading=$chosen_leading
        body=${rest%%'<<<RALPHEX:END>>>'*}
        current="$marker$body<<<RALPHEX:END>>>"

        if plan_boundary_outranks "$pos" "$leading" "$candidate_pos" "$candidate_leading"; then
            candidate="$current"
            candidate_pos=$pos
            candidate_leading=$leading
        fi
    done

    for marker in '<<<RALPHEX:PLAN_READY>>>' '<<<RALPHEX:TASK_FAILED>>>'; do
        [[ "$text" == *"$marker"* ]] || continue
        # walk EVERY occurrence and classify each, for the same reason the opening
        # markers do: the plan prompt teaches the model these exact tokens, so it
        # may name one in prose before emitting the real boundary. Binding to the
        # first occurrence let that narration outrank a real, complete PLAN_DRAFT,
        # ending the run with a PLAN_READY signal and no plan for the user to
        # review (or aborting it outright on a narrated TASK_FAILED).
        scan="$text"
        consumed=0
        while [[ "$scan" == *"$marker"* ]]; do
            prefix=${scan%%"$marker"*}
            pos=$((consumed + ${#prefix}))
            rest=${scan#*"$marker"}
            consumed=$((pos + ${#marker}))
            scan="$rest"
            if [[ $pos -eq 0 || "${text:pos-1:1}" == $'\n' ]]; then
                leading=1
            else
                leading=0
            fi
            # a terminal marker inside a still-open QUESTION/PLAN_DRAFT body is the
            # model narrating its own protocol, not a boundary. Keep buffering.
            if [[ $open_pos -ge 0 && $pos -gt $open_pos ]]; then
                continue
            fi
            if [[ $leading -eq 0 && $open_inline_pos -ge 0 && $pos -gt $open_inline_pos ]]; then
                continue
            fi
            if plan_boundary_outranks "$pos" "$leading" "$candidate_pos" "$candidate_leading"; then
                candidate="$marker"
                candidate_pos=$pos
                candidate_leading=$leading
            fi
        done
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
# Set once the model's own answer text has carried a terminal ralphex signal
# downstream. ClaudeExecutor ignores a non-zero provider exit as soon as any
# signal was detected (pkg/executor/executor.go), so the forced non-zero exit
# below cannot fail a run whose stream already contained one — see the error
# branch, which retracts the signal instead.
bob_signal_emitted=0

# Text that did not come from the model's own answer is neutralized before it is
# forwarded, so a tool error or diagnostic that quotes a ralphex signal token cannot
# forge a real signal (ralphex matches signals as a plain substring). This is done
# with inline ${var//...} expansion rather than a helper, because routing buffered
# text through $(...) would strip the trailing newlines line buffering depends on.

# Line-buffers assistant message text so a signal token split across several
# streaming deltas is re-assembled and emitted intact in one content_block_delta.
# Answer and reasoning text get INDEPENDENT buffers: with one shared buffer, a
# reasoning message landing between two halves of an answer line had to flush the
# answer remainder to keep reasoning text out of it, which split the very signal
# token the buffering exists to re-assemble (BOB_VERBOSE=1 only, but that made the
# phase loop on a finished task). Separate buffers cannot splice across kinds, so
# no cross-kind flush is needed.
task_answer_buffer=""
task_reasoning_buffer=""
# Emits one buffered chunk, neutralizing signal tokens when the buffered text is
# reasoning rather than the model's own answer. Neutralization belongs here, on
# flush, and not on the incoming chunk: bob splits message text mid-token, so a
# token straddling two reasoning chunks matches neither per-chunk substitution and
# the buffer would re-assemble it into a live signal.
emit_task_chunk() {
    if [[ "$1" == "reasoning" ]]; then
        emit_text_delta "${2//<<<RALPHEX:/<<< RALPHEX:}"
        return
    fi
    emit_text_delta "$2"
    # Remember that a terminal signal reached ralphex. Reasoning and diagnostics
    # are neutralized above, so only answer text can carry a live one, and only
    # the signals detectSignal recognizes matter. TASK_FAILED is not tracked: it
    # already fails the run, so there is nothing left to retract.
    case "$2" in
        *'<<<RALPHEX:ALL_TASKS_DONE>>>'*|*'<<<RALPHEX:REVIEW_DONE>>>'*|*'<<<RALPHEX:CODEX_REVIEW_DONE>>>'*|*'<<<RALPHEX:PLAN_READY>>>'*)
            bob_signal_emitted=1
            ;;
    esac
}
# True when the buffered answer text may still be receiving a signal token: an
# opened `<<<RALPHEX:` with no closing `>>>` yet, or a tail that is a proper
# prefix of the opening marker. ralphex matches signals per content_block_delta
# (detectSignal in pkg/executor/executor.go scans each block's text with a plain
# substring), so emitting such a buffer would split the token across two deltas
# and make it undetectable — the finished iteration would then be re-run.
signal_token_in_flight() {
    local buffer="$1"
    local marker='<<<RALPHEX:'
    local tail=""
    local i=0
    if [[ "$buffer" == *"$marker"* ]]; then
        tail=${buffer##*"$marker"}
        [[ "$tail" != *'>>>'* ]] && return 0
    fi
    for ((i = ${#marker} - 1; i > 0; i--)); do
        [[ "$buffer" == *"${marker:0:i}" ]] && return 0
    done
    return 1
}
# Emits whatever is left in the buffers, used by the non-answer branches so a
# diagnostic is not logged ahead of assistant text buffered before it. An answer
# remainder that may hold half a signal token is kept instead: log interleaving
# for one partial line is worth less than the signal, and the token is emitted
# whole as soon as its line completes. Pass "force" at stream end, where holding
# text would lose it outright; reasoning is never held because it is neutralized
# on flush and so can never carry a live signal.
flush_task_buffer_remainder() {
    local force="${1:-}"
    if [[ -n "$task_answer_buffer" ]] &&
        { [[ "$force" == "force" ]] || ! signal_token_in_flight "$task_answer_buffer"; }; then
        emit_task_chunk text "$task_answer_buffer"
        task_answer_buffer=""
    fi
    if [[ -n "$task_reasoning_buffer" ]]; then
        emit_task_chunk reasoning "$task_reasoning_buffer"
        task_reasoning_buffer=""
    fi
}
flush_task_buffer_lines() {
    local kind="$1"
    local buffer=""
    local line=""
    local emitted=0
    if [[ "$kind" == "reasoning" ]]; then
        buffer="$task_reasoning_buffer$2"
    else
        buffer="$task_answer_buffer$2"
    fi
    while [[ "$buffer" == *$'\n'* ]]; do
        line="${buffer%%$'\n'*}"
        buffer="${buffer#*$'\n'}"
        emit_task_chunk "$kind" "$line"$'\n'
        emitted=1
    done
    if [[ "$kind" == "reasoning" ]]; then
        task_reasoning_buffer="$buffer"
    else
        task_answer_buffer="$buffer"
    fi
    # a chunk with no newline yet emits nothing, so ralphex's idle_timeout would
    # see silence while a long line accumulates. Keep the keepalive contract every
    # other suppressed path honors.
    [[ "$emitted" -eq 1 ]] || emit_keepalive
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
        # flush first, like every other non-answer branch, so a diagnostic cannot
        # be logged ahead of assistant text that was buffered before it.
        flush_task_buffer_remainder
        emit_text_delta "${line//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
        case "${line,,}" in
            *error*|*failed*|*failure*|*limit*|*auth*|*required*|*timeout*|*exception*)
                bob_failure_detail_emitted=1
                ;;
        esac
        continue
    fi

    # {type:"error"} is bob v2's only failure channel (result.status is always
    # "success"), so every mode must surface it — a swallowed rate-limit or auth
    # message would otherwise be reported as a missing plan boundary, or as a
    # silently successful task run, with no diagnostic. Handled before the mode
    # dispatch so both paths cannot drift apart. The remainder flush is a no-op in
    # plan mode, which never fills the task buffer.
    if [[ "$event_type" == "error" ]]; then
        flush_task_buffer_remainder
        # v2 puts the text in the top-level message, but fall back to a nested
        # error.message rather than discarding a cause that was already parsed:
        # losing it would also keep ralphex's limit/error patterns from matching.
        error_detail="${event_message:-$event_error_message}"
        error_detail="${error_detail//<<<RALPHEX:/<<< RALPHEX:}"
        # bob may report an error with no message at all; an empty "error: bob:"
        # line names no cause, so give the user something to search for.
        [[ -n "${error_detail//[[:space:]]/}" ]] || error_detail="unspecified bob error"
        emit_text_delta "error: bob: $error_detail"$'\n'
        bob_failure_detail_emitted=1
        bob_result_failed=1
        # bob emits max-turns/max-cost aborts AFTER assistant text, so the stream
        # can hold a terminal signal followed by this failure. ClaudeExecutor then
        # ignores the non-zero exit ("if there IS a signal, work was done") and the
        # diagnostic only lands in the log unless it happens to match a configured
        # error pattern — a failed run reported as a success. detectSignal keeps the
        # LAST signal it sees, so a TASK_FAILED emitted here supersedes the earlier
        # one and restores the fail-closed contract.
        # Only when a signal actually went out: with an empty signal the non-zero
        # exit already fails the run, and synthesizing TASK_FAILED there would
        # suppress claude_retry_patterns (retry detection is skipped once a signal
        # is present), turning a transient bob error into a hard failure.
        if [[ "$bob_signal_emitted" == "1" ]]; then
            emit_text_delta '<<<RALPHEX:TASK_FAILED>>>'$'\n'
            # a later genuine signal may still supersede this one, so re-arm.
            bob_signal_emitted=0
        fi
        continue
    fi

    if [[ "$selected_chat_mode" == "ralphex-plan" ]]; then
        if [[ "$event_type" == "message" && "$event_role" == "assistant" && "$event_is_reasoning" != "true" ]]; then
            plan_stream_buffer+="$event_content"
            if extract_plan_boundary "$plan_stream_buffer"; then
                emit_text_delta "$plan_boundary_text"
                plan_boundary_emitted=1
                intentional_stop=1
                break
            fi
        fi
        emit_keepalive
        continue
    fi

    # Task/review translation forwards assistant message text line-by-line and
    # otherwise stays terminal-only.
    if [[ "$event_type" == "message" && "$event_role" == "assistant" ]]; then
        if [[ "$event_is_reasoning" == "true" ]]; then
            if [[ "$BOB_VERBOSE" == "1" ]]; then
                # not neutralized here — emit_task_chunk does it on flush, after
                # the buffer has re-assembled tokens split across chunks.
                flush_task_buffer_lines reasoning "$event_content"
            else
                emit_keepalive
            fi
        else
            flush_task_buffer_lines text "$event_content"
        fi
    elif [[ "$event_type" == "tool_result" && "$event_status" == "error" ]]; then
        flush_task_buffer_remainder
        # same reasoning as the `error` event above: this line marks the failure
        # detail as emitted, so a message-less tool error must still name a cause
        # instead of leaving a bare "[tool_error]" behind.
        tool_error_detail="${event_error_message//<<<RALPHEX:/<<< RALPHEX:}"
        [[ -n "${tool_error_detail//[[:space:]]/}" ]] || tool_error_detail="unspecified bob tool error"
        emit_text_delta "[tool_error] $tool_error_detail"$'\n'
        bob_failure_detail_emitted=1
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_result" && "$event_status" == "success" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "[tool_result] ${event_output//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
    elif [[ "$BOB_VERBOSE" == "1" && "$event_type" == "tool_use" ]]; then
        flush_task_buffer_remainder
        emit_text_delta "[tool] ${event_tool//<<<RALPHEX:/<<< RALPHEX:}"$'\n'
    else
        emit_keepalive
    fi
done < "$stream_pipe"

# flush any partial trailing line left in the task/review buffer. this runs before
# the single terminating result event below, so no buffered text lands after it.
# forced: no further text can complete the line, so holding it back would lose it.
flush_task_buffer_remainder force

# Stop bob on a deadline once a plan boundary has been emitted. bob v2's handler
# (`e&&process.exit(1),e=!0,t.abort(...)`) only ABORTS the in-flight task on the
# first TERM and needs a second one to exit, and the abort does not necessarily
# interrupt a spawned command, so a single TERM can leave bob alive and the
# unbounded `wait` below would hang after the plan boundary was already delivered.
stop_bob_bounded() {
    local signal=""
    local waited=0
    for signal in TERM TERM KILL; do
        kill -0 "$bob_pid" 2>/dev/null || return 0
        kill -"$signal" "$bob_pid" 2>/dev/null || true
        # bash reaps background children asynchronously, so a `kill -0` failure
        # here means bob is gone rather than an unreaped zombie.
        for ((waited = 0; waited < 20; waited++)); do
            kill -0 "$bob_pid" 2>/dev/null || return 0
            # `set -e` is active: a sleep interrupted by a signal, or a sleep that
            # rejects the fractional argument, must not abort the whole wrapper
            # before the result event is emitted.
            sleep 0.1 || true
        done
    done
}
if [[ "$intentional_stop" == "1" ]]; then
    stop_bob_bounded
fi

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
    # this line IS the diagnostic, and the status is synthesized here rather than
    # returned by bob, so the silent-failure fallback below must not also claim the
    # run ended "without diagnostic output" at a status bob never reported.
    bob_failure_detail_emitted=1
fi

# Bob occasionally exits non-zero after going silent without emitting any diagnostic.
# Preserve the exit code and add enough context for ralphex progress logs to be useful.
if [[ "$bob_exit" -ne 0 && "$bob_failure_detail_emitted" == "0" ]]; then
    bob_elapsed_seconds=$((SECONDS - bob_start_seconds))
    emit_text_delta "error: bob exited with status $bob_exit after ${bob_elapsed_seconds}s without diagnostic output"$'\n'
fi

echo '{"type":"result","result":""}'
exit "$bob_exit"
