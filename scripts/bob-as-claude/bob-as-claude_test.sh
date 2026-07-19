#!/usr/bin/env bash
# bob-as-claude_test.sh — tests for bob-as-claude.sh wrapper.
#
# run from the ralphex directory:
#   bash scripts/bob-as-claude/bob-as-claude_test.sh
#
# requires: jq, bash, awk
# uses a mock bob — NO real API calls are made.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/bob-as-claude.sh"
TMPDIR_TEST=$(mktemp -d)
# exported so the wrapper and the mock bob subprocess inherit it without a
# redundant inline env assignment at every call site (avoids SC2097/SC2098)
export TMPDIR_TEST
trap 'rm -rf "$TMPDIR_TEST"' EXIT

passed=0
failed=0
total=0

pass() {
    passed=$((passed + 1))
    total=$((total + 1))
    echo "  PASS: $1"
}

fail() {
    failed=$((failed + 1))
    total=$((total + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

# create a mock bob script that records its arguments and emits predefined stdout.
# MOCK_STDOUT_FILE: file containing text to emit on stdout
# MOCK_STDERR_FILE: file containing text to emit on stderr
# MOCK_EXIT_CODE:   exit code to return (default 0)
# bob_args:         arguments written to $TMPDIR_TEST/bob_args
# bob_prompt:       stdin captured to $TMPDIR_TEST/bob_prompt (the prompt arrives
#                   via stdin now, not as a positional arg)
create_mock_bob() {
    local mock_script="$TMPDIR_TEST/bob"
    cat > "$mock_script" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" > "$TMPDIR_TEST/bob_args"
# capture stdin (the prompt) separately for assertions
cat > "$TMPDIR_TEST/bob_prompt"

if [[ -n "${MOCK_STDOUT_FILE:-}" && -f "$MOCK_STDOUT_FILE" ]]; then
    cat "$MOCK_STDOUT_FILE"
fi
if [[ -n "${MOCK_STDERR_FILE:-}" && -f "$MOCK_STDERR_FILE" ]]; then
    cat "$MOCK_STDERR_FILE" >&2
fi
exit "${MOCK_EXIT_CODE:-0}"
MOCK_EOF
    chmod +x "$mock_script"
    echo "$mock_script"
}

# A second mock that records each argv element on its own line (via printf) so
# word-splitting can be asserted (echo "$@" would re-join with spaces). This
# mock writes to bob_args_lines, not bob_args.
# IMPORTANT: create_mock_bob writes via `cat > "$TMPDIR_TEST/bob"`, which FOLLOWS
# the bob->bob_lines symlink and overwrites bob_lines itself. So after any call
# to create_mock_bob, bob_lines is corrupted (replaced by the standard mock).
# Any test needing the line-recording mock MUST call this helper to recreate
# bob_lines before re-symlinking bob -> bob_lines.
create_bob_lines_mock() {
    cat > "$TMPDIR_TEST/bob_lines" << 'LINES_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPDIR_TEST/bob_args_lines"
cat > /dev/null  # consume stdin
cat "$MOCK_STDOUT_FILE"
exit 0
LINES_EOF
    chmod +x "$TMPDIR_TEST/bob_lines"
    ln -sf "$TMPDIR_TEST/bob_lines" "$TMPDIR_TEST/bob"
}

create_mock_bob > /dev/null

# minimal valid bob event stream: one attempt_completion produces output.
cat > "$TMPDIR_TEST/minimal_events.txt" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"message","timestamp":"t","role":"user","content":"test\n"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"hello world\n"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"hello world\n"}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

run_wrapper() {
    # helper: run wrapper with mock bob on PATH; args forwarded to wrapper
    MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" "$@"
}

echo "running bob-as-claude.sh tests"
echo ""

# ---------------------------------------------------------------------------
# test: bob launched with --chat-mode code, --output-format stream-json,
# --hide-intermediary-output, --yolo, --trust, and prompt delivered via stdin
# ---------------------------------------------------------------------------
echo "test: bob invocation flags"

rm -f "$TMPDIR_TEST/bob_args" "$TMPDIR_TEST/bob_prompt"
run_wrapper -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
for flag in "--chat-mode code" "--output-format stream-json" "--hide-intermediary-output" "--yolo" "--trust"; do
    if echo "$recorded" | grep -q -- "$flag"; then
        pass "bob invoked with $flag"
    else
        fail "bob not invoked with $flag" "args: $recorded"
    fi
done

if [[ "$(cat "$TMPDIR_TEST/bob_prompt")" == "test prompt" ]]; then
    pass "prompt delivered via stdin"
else
    fail "prompt not delivered via stdin" "got: $(cat "$TMPDIR_TEST/bob_prompt")"
fi

# the prompt must NOT appear on argv (avoids the per-arg length cap)
if echo "$recorded" | grep -q -- "test prompt"; then
    fail "prompt leaked onto argv" "args: $recorded"
else
    pass "prompt absent from argv"
fi

# ---------------------------------------------------------------------------
# test: --model flag forwarded to bob as -m
# ---------------------------------------------------------------------------
echo "test: --model forwarding"

rm -f "$TMPDIR_TEST/bob_args"
run_wrapper --model "anthropic/claude-x" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m anthropic/claude-x"; then
    pass "--model forwarded to bob as -m"
else
    fail "--model not forwarded as -m" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: BOB_MODEL env used as -m when --model flag absent
# ---------------------------------------------------------------------------
echo "test: BOB_MODEL env"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m google/gemini-x"; then
    pass "BOB_MODEL used as -m when flag absent"
else
    fail "BOB_MODEL not used" "args: $recorded"
fi

# --model flag wins over BOB_MODEL
rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_MODEL="google/gemini-x" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" --model "anthropic/claude-x" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "-m anthropic/claude-x" && ! echo "$recorded" | grep -q -- "google/gemini-x"; then
    pass "--model flag overrides BOB_MODEL"
else
    fail "--model did not override BOB_MODEL" "args: $recorded"
fi

# no -m when neither flag nor env set
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
# use word-boundary grep so "-m" does not match "--chat-mode" or "--max-coins"
if echo "$recorded" | grep -qE '(^| )-m( |$)'; then
    fail "-m present when no model configured" "args: $recorded"
else
    pass "-m omitted when no model configured"
fi

# ---------------------------------------------------------------------------
# test: --effort accepted but ignored (bob has no --effort; bob rejects it)
# ---------------------------------------------------------------------------
echo "test: --effort ignored"

rm -f "$TMPDIR_TEST/bob_args"
err_out=$(run_wrapper --effort high -p "test prompt" 2>&1 >/dev/null)
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--effort"; then
    fail "--effort leaked to bob argv" "args: $recorded"
else
    pass "--effort not forwarded to bob"
fi

if echo "$err_out" | grep -qi "bob has no --effort flag"; then
    pass "stderr note emitted for non-empty --effort"
else
    fail "stderr note missing for --effort" "stderr: $err_out"
fi

# empty --effort must NOT emit a note (avoids noise on default empty)
rm -f "$TMPDIR_TEST/bob_args"
err_out=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" --effort "" -p "test prompt" 2>&1 >/dev/null)
if echo "$err_out" | grep -qi "bob has no --effort flag"; then
    fail "stderr note emitted for empty --effort" "stderr: $err_out"
else
    pass "no stderr note for empty --effort"
fi

# ---------------------------------------------------------------------------
# test: BOB_EXTRA_ARGS appended verbatim (word-split); no positional prompt
# ---------------------------------------------------------------------------
echo "test: BOB_EXTRA_ARGS passthrough"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS="--max-coins 100" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--max-coins 100"; then
    pass "BOB_EXTRA_ARGS appended to bob invocation"
else
    fail "BOB_EXTRA_ARGS not appended" "args: $recorded"
fi

# no positional prompt is appended after the extra args (prompt is on stdin)
if echo "$recorded" | grep -q -- "test prompt"; then
    fail "prompt leaked onto argv after BOB_EXTRA_ARGS" "args: $recorded"
else
    pass "no positional prompt appended after BOB_EXTRA_ARGS"
fi

# no stray args when BOB_EXTRA_ARGS unset
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--max-coins"; then
    fail "extra args present when BOB_EXTRA_ARGS unset" "args: $recorded"
else
    pass "no extra args when BOB_EXTRA_ARGS unset"
fi

# whitespace-only BOB_EXTRA_ARGS must not crash under set -u on bash 3.2:
# it yields an empty array after read, and expanding it would be an unbound-var error.
rm -f "$TMPDIR_TEST/bob_args"
if MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS="   " \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1; then
    pass "whitespace-only BOB_EXTRA_ARGS does not crash"
else
    fail "whitespace-only BOB_EXTRA_ARGS crashed the wrapper" "exit: $?"
fi

# BOB_EXTRA_ARGS word-splitting does NOT preserve quotes: a value like
# '--flag "a b"' is split into ['--flag', '"a', 'b"'] (three tokens), not
# ['--flag', 'a b'] (two tokens). This is a documented limitation.
# To verify word-splitting, we record each arg on its own line by using
# printf '%s\n' "$@" in a dedicated mock (echo "$@" would re-join with
# spaces and hide the split).
rm -f "$TMPDIR_TEST/bob_args_lines"
cat > "$TMPDIR_TEST/bob_lines" << 'LINES_EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMPDIR_TEST/bob_args_lines"
cat > /dev/null  # consume stdin
cat "$MOCK_STDOUT_FILE"
exit 0
LINES_EOF
chmod +x "$TMPDIR_TEST/bob_lines"
ln -sf "$TMPDIR_TEST/bob_lines" "$TMPDIR_TEST/bob"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_EXTRA_ARGS='--flag "a b"' \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
# restore the standard mock for subsequent tests.
# NOTE: create_mock_bob writes via `cat > "$TMPDIR_TEST/bob"`, which FOLLOWS the
# symlink and overwrites bob_lines itself. Any later test that re-symlinks bob
# -> bob_lines would inherit the standard mock (writing bob_args, not
# bob_args_lines). Tests below that need the line-recording mock must recreate
# bob_lines before re-symlinking.
create_mock_bob > /dev/null
# The args should be split into 3 lines: --flag, "a, b"
args_line_count=$(wc -l < "$TMPDIR_TEST/bob_args_lines" | tr -d ' ')
if [[ "$args_line_count" -ge 3 ]]; then
    pass "BOB_EXTRA_ARGS word-splits without preserving quotes ($args_line_count tokens)"
else
    fail "BOB_EXTRA_ARGS did not word-split as expected" "expected >=3 lines, got $args_line_count: $(cat "$TMPDIR_TEST/bob_args_lines")"
fi
# verify the three expected tokens are present
if grep -qx -- '--flag' "$TMPDIR_TEST/bob_args_lines" \
    && grep -qx -- '"a' "$TMPDIR_TEST/bob_args_lines" \
    && grep -qx -- 'b"' "$TMPDIR_TEST/bob_args_lines"; then
    pass "BOB_EXTRA_ARGS word-split produces expected tokens"
else
    fail "BOB_EXTRA_ARGS word-split tokens unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
fi

# ---------------------------------------------------------------------------
# test: BOB_CHAT_MODE env forwarded as --chat-mode
# ---------------------------------------------------------------------------
echo "test: BOB_CHAT_MODE env"

rm -f "$TMPDIR_TEST/bob_args"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="ask" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--chat-mode ask"; then
    pass "BOB_CHAT_MODE=ask forwarded as --chat-mode ask"
else
    fail "BOB_CHAT_MODE not forwarded" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: empty BOB_CHAT_MODE exits with error
# ---------------------------------------------------------------------------
echo "test: empty BOB_CHAT_MODE"

set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/chatmode_err" >/dev/null
chatmode_exit=$?
set -e

if [[ $chatmode_exit -ne 0 ]]; then
    pass "empty BOB_CHAT_MODE exits non-zero"
else
    fail "empty BOB_CHAT_MODE should exit non-zero" "got exit 0"
fi

if grep -qi "BOB_CHAT_MODE is empty" "$TMPDIR_TEST/chatmode_err"; then
    pass "empty BOB_CHAT_MODE error message is clear"
else
    fail "empty BOB_CHAT_MODE error message missing" "stderr: $(cat "$TMPDIR_TEST/chatmode_err")"
fi

# whitespace-only BOB_CHAT_MODE also exits non-zero
set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="   " \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/chatmode_err2" >/dev/null
chatmode_ws_exit=$?
set -e

if [[ $chatmode_ws_exit -ne 0 ]]; then
    pass "whitespace-only BOB_CHAT_MODE exits non-zero"
else
    fail "whitespace-only BOB_CHAT_MODE should exit non-zero" "got exit 0"
fi

# ---------------------------------------------------------------------------
# test: custom (non-builtin) BOB_CHAT_MODE slug forwarded to bob
# ---------------------------------------------------------------------------
echo "test: custom BOB_CHAT_MODE slug forwarded"

rm -f "$TMPDIR_TEST/bob_args"
set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    BOB_CHAT_MODE="shell-debug" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/custom_err" >/dev/null
custom_exit=$?
set -e

if [[ $custom_exit -eq 0 ]]; then
    pass "custom BOB_CHAT_MODE slug exits 0"
else
    fail "custom BOB_CHAT_MODE slug should exit 0" "got exit $custom_exit"
fi

recorded=$(cat "$TMPDIR_TEST/bob_args")
if echo "$recorded" | grep -q -- "--chat-mode shell-debug"; then
    pass "custom BOB_CHAT_MODE=shell-debug forwarded as --chat-mode shell-debug"
else
    fail "custom BOB_CHAT_MODE slug not forwarded" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: non-builtin slug emits a warning on stderr but still proceeds
# ---------------------------------------------------------------------------
echo "test: non-builtin slug warning"

if grep -qi "not a built-in mode" "$TMPDIR_TEST/custom_err"; then
    pass "non-builtin slug emits warning on stderr"
else
    fail "non-builtin slug warning missing" "stderr: $(cat "$TMPDIR_TEST/custom_err")"
fi

if echo "$recorded" | grep -q -- "--chat-mode shell-debug" && [[ $custom_exit -eq 0 ]]; then
    pass "non-builtin slug proceeds despite warning"
else
    fail "non-builtin slug did not proceed" "args: $recorded, exit: $custom_exit"
fi

# ---------------------------------------------------------------------------
# test: BOB_VERBOSE validation — invalid value warns and defaults to 0
# ---------------------------------------------------------------------------
echo "test: invalid BOB_VERBOSE falls back to 0"

cat > "$TMPDIR_TEST/tool_events.jsonl" << 'EOF'
{"type":"init","timestamp":"t","session_id":"s","model":"premium"}
{"type":"tool_use","timestamp":"t","tool_name":"read_file","tool_id":"tool-1","parameters":{"path":"foo"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"success","output":"content"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-2","parameters":{"result":"done\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_events.jsonl" \
    BOB_VERBOSE="banana" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/verbose_err" >"$TMPDIR_TEST/verbose_out"
if grep -qi "BOB_VERBOSE must be 0 or 1" "$TMPDIR_TEST/verbose_err"; then
    pass "invalid BOB_VERBOSE prints warning"
else
    fail "no warning for invalid BOB_VERBOSE" "stderr: $(cat "$TMPDIR_TEST/verbose_err")"
fi
if grep -q "\[tool\]" "$TMPDIR_TEST/verbose_out"; then
    fail "tool events leaked with invalid BOB_VERBOSE (should default to 0)" "got: $(cat "$TMPDIR_TEST/verbose_out")"
else
    pass "invalid BOB_VERBOSE defaults to 0 (tool events suppressed)"
fi

# ---------------------------------------------------------------------------
# test: attempt_completion translation — parameters.result emitted as delta
# ---------------------------------------------------------------------------
echo "test: attempt_completion translation"

output=$(run_wrapper -p "test prompt" 2>/dev/null)

# select the first non-empty delta
text_line=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text != "")' | head -1)
if echo "$text_line" | jq -e '.delta.text == "hello world\n"' >/dev/null 2>&1; then
    pass "attempt_completion result emitted as content_block_delta with trailing newline"
else
    fail "attempt_completion result not translated correctly" "got: $output"
fi

# init/session header is skipped (emitted as empty keepalive, not leaked)
if echo "$output" | grep -q "\"session_id\":\"s\"" || echo "$output" | grep -q "\"model\":\"premium\""; then
    fail "init header leaked into output" "got: $output"
else
    pass "init header skipped (no leak)"
fi

# user message echo is skipped
if echo "$output" | grep -q "\"role\":\"user\""; then
    fail "user message echo leaked into output" "got: $output"
else
    pass "user message echo skipped"
fi

# ---------------------------------------------------------------------------
# test: result event translation — bob result -> Claude result (count = 2)
# ---------------------------------------------------------------------------
echo "test: terminal result event"

# the wrapper always emits a fallback result, so a single result event would pass even
# if result translation were broken. assert the COUNT: a stream with a result event yields
# 2 results (translated + fallback), a stream without yields 1.
result_count=$(echo "$output" | grep -c '"result"')
if [[ "$result_count" -eq 2 ]]; then
    pass "bob result event translated (2 total with fallback)"
else
    fail "unexpected result count" "expected 2, got $result_count: $output"
fi

# a stream with no result event yields exactly one (the fallback) result.
cat > "$TMPDIR_TEST/noresult_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"text only\n"}}
EOF
output_noterm=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/noresult_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
noterm_results=$(echo "$output_noterm" | grep -c '"result"')
if [[ "$noterm_results" -eq 1 ]]; then
    pass "no result event yields exactly one (fallback) result"
else
    fail "unexpected result count without result event" "expected 1, got $noterm_results: $output_noterm"
fi

# ---------------------------------------------------------------------------
# test: tool_result(status=error) always emitted even with BOB_VERBOSE=0
# ---------------------------------------------------------------------------
echo "test: tool_result error always emitted"

cat > "$TMPDIR_TEST/tool_error_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"bash","tool_id":"tool-1","parameters":{"cmd":"false"}}
{"type":"tool_result","timestamp":"t","tool_id":"tool-1","status":"error","output":"command failed"}
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-2","parameters":{"result":"done\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "\[tool_error\] command failed"; then
    pass "tool_result error emitted even with BOB_VERBOSE=0"
else
    fail "tool_result error not emitted" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: tool_result(status=success) only with BOB_VERBOSE=1
# ---------------------------------------------------------------------------
echo "test: tool_result success verbose"

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

# With BOB_VERBOSE=1, the bash tool_use emits [tool] bash
if echo "$output" | grep -q "\[tool\] bash"; then
    pass "tool_use emitted as [tool] marker with BOB_VERBOSE=1"
else
    fail "tool_use [tool] marker missing with BOB_VERBOSE=1" "got: $output"
fi

# A success tool_result does not appear in this fixture (only error), but we
# can verify the verbose tool_use marker is present (covered above).

# ---------------------------------------------------------------------------
# test: tool events skipped by default (BOB_VERBOSE=0)
# ---------------------------------------------------------------------------
echo "test: tool events skipped by default"

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/tool_error_events.jsonl" \
    BOB_VERBOSE=0 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "\[tool\]"; then
    fail "tool [tool] markers leaked (BOB_VERBOSE=0)" "got: $output"
else
    pass "tool_use [tool] markers skipped (BOB_VERBOSE=0)"
fi

# suppressed events (init, user message, non-attempt_completion tool_use) emit
# empty keepalive deltas. This fixture has a bash tool_use (suppressed when
# BOB_VERBOSE=0) -> 1 keepalive. The error tool_result and attempt_completion
# emit non-empty text.
keepalives=$(echo "$output" | grep '"content_block_delta"' | jq -c 'select(.delta.text == "")' | wc -l | tr -d ' ')
if [[ "$keepalives" -ge 1 ]]; then
    pass "suppressed events emit empty keepalive deltas (got $keepalives)"
else
    fail "expected >=1 keepalive delta for suppressed tool_use" "got $keepalives: $output"
fi

# ---------------------------------------------------------------------------
# test: invalid JSON lines do not abort translation
# ---------------------------------------------------------------------------
echo "test: invalid JSON tolerated"

cat > "$TMPDIR_TEST/garbage_events.jsonl" << 'EOF'
not json at all
123
"a bare json string"
[1,2,3]
{"type":"tool_use","tool_name":"attempt_completion","parameters":{"result":"after garbage\n"}}
{"type":"result","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/garbage_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "after garbage"; then
    pass "translation continues past invalid JSON lines"
else
    fail "invalid JSON aborted translation" "got: $output"
fi

# bare plaintext line (like bob's final-text echo) is also tolerated
cat > "$TMPDIR_TEST/plaintext_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"hello\n"}}
Hello
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/plaintext_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q "hello"; then
    pass "bare plaintext line between tool_result and result is tolerated"
else
    fail "bare plaintext line broke translation" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: fallback result event — bob exits without result
# ---------------------------------------------------------------------------
echo "test: fallback result event"

cat > "$TMPDIR_TEST/noresult2_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"partial\n"}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/noresult2_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

last_line=$(echo "$output" | tail -1)
if echo "$last_line" | jq -e '.type == "result"' >/dev/null 2>&1; then
    pass "fallback result emitted when no result event"
else
    fail "no fallback result event" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: review-prompt adapter injection (strict trigger on review START markers)
# ---------------------------------------------------------------------------
echo "test: review-prompt adapter injection (strict trigger)"

# "Use the Task tool to launch" marker triggers the adapter (claude executor's
# per-agent {{agent:NAME}} expansion form)
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'Code review of: feature\n\n## Step 2: Launch ALL 5 Review Agents IN PARALLEL\n\nUse the Task tool to launch a general-purpose agent with this prompt:\n"review quality"\nReport findings only - no positive observations.' >/dev/null 2>&1

sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    pass "review adapter text prepended for review prompts (Task tool marker)"
else
    fail "review adapter text not prepended" "got: $sent_prompt"
fi

# the original review prompt content is preserved after the adapter
if echo "$sent_prompt" | grep -q "Use the Task tool to launch a general-purpose agent"; then
    pass "original review prompt preserved in adapted prompt"
else
    fail "original review prompt lost" "got: $sent_prompt"
fi

# non-review prompts are NOT adapted
rm -f "$TMPDIR_TEST/bob_prompt"
run_wrapper -p "just a task prompt" >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter"; then
    fail "adapter wrongly injected for non-review prompt" "got: $sent_prompt"
else
    pass "non-review prompt left unmodified"
fi

# ---------------------------------------------------------------------------
# test: review-adapter trigger on "Launch ALL 5 Review Agents IN PARALLEL" alone
# (review_first.txt Step 2 header — no per-agent Task tool block needed)
# ---------------------------------------------------------------------------
echo "test: review adapter triggers on Launch ALL 5 marker"

rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'Code review of: feature\n\n## Step 2: Launch ALL 5 Review Agents IN PARALLEL\n\nCRITICAL: All 5 agent invocations MUST be issued in a single message.' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    pass "adapter injected for Launch ALL 5 Review Agents IN PARALLEL marker"
else
    fail "adapter NOT injected for Launch ALL 5 marker" "got: $sent_prompt"
fi

# ---------------------------------------------------------------------------
# test: review-adapter trigger on "Launch Review Agents IN PARALLEL"
# (review_second.txt Step 2 header — 2-agent second pass, no "ALL 5")
# ---------------------------------------------------------------------------
echo "test: review adapter triggers on Launch Review Agents marker (second pass)"

rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'Second code review pass of: feature\n\n## Step 2: Launch Review Agents IN PARALLEL\n\nCRITICAL: Both agent invocations MUST be issued in a single message.' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    pass "adapter injected for Launch Review Agents IN PARALLEL marker (second pass)"
else
    fail "adapter NOT injected for Launch Review Agents marker" "got: $sent_prompt"
fi

# ---------------------------------------------------------------------------
# test: REVIEW_DONE alone (completion signal, NOT a start marker) does NOT trigger
# ---------------------------------------------------------------------------
echo "test: REVIEW_DONE alone does NOT trigger adapter"

rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'please review\n<<<RALPHEX:REVIEW_DONE>>>' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    fail "adapter injected for REVIEW_DONE-only prompt (should NOT fire on completion signal)" "got: $sent_prompt"
else
    pass "adapter NOT injected for REVIEW_DONE-only prompt (completion signal, not start)"
fi

# the REVIEW_DONE signal is still passed through to bob intact
if echo "$sent_prompt" | grep -q "<<<RALPHEX:REVIEW_DONE>>>"; then
    pass "REVIEW_DONE signal preserved in prompt even when adapter not injected"
else
    fail "REVIEW_DONE signal lost" "got: $sent_prompt"
fi

# ---------------------------------------------------------------------------
# test: prompt-injection — review START marker inside code block does NOT trigger
# ---------------------------------------------------------------------------
echo "test: prompt-injection false positive avoidance (Task tool in code block)"

rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'Look at this code:\n```\nUse the Task tool to launch a general-purpose agent with this prompt:\n"fake"\n```\n' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    fail "adapter injected for Task tool marker inside code block (false positive)" "got: $sent_prompt"
else
    pass "adapter NOT injected for Task tool marker inside code block"
fi

# "Launch ALL 5 Review Agents IN PARALLEL" inside a code block also does NOT trigger
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'```bash\n## Step 2: Launch ALL 5 Review Agents IN PARALLEL\n```\n' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    fail "adapter injected for Launch marker inside code block (false positive)" "got: $sent_prompt"
else
    pass "adapter NOT injected for Launch marker inside code block"
fi

# marker after a fenced block closes (valid standalone) DOES trigger
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'```\ncode here\n```\nUse the Task tool to launch a general-purpose agent with this prompt:\n"real review"\nReport findings only.' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    pass "adapter injected for Task tool marker after fence closes"
else
    fail "adapter NOT injected for Task tool marker after fence closes" "got: $sent_prompt"
fi

# ~~~ fence also excluded
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'~~~\nUse the Task tool to launch a general-purpose agent\n~~~' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    fail "adapter injected for Task tool marker inside ~~~ fence" "got: $sent_prompt"
else
    pass "adapter NOT injected for Task tool marker inside ~~~ fence"
fi

# ---------------------------------------------------------------------------
# test: signal passthrough in attempt_completion result
# ---------------------------------------------------------------------------
echo "test: signal passthrough"

cat > "$TMPDIR_TEST/signal_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"<<<RALPHEX:ALL_TASKS_DONE>>>\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/signal_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q "<<<RALPHEX:ALL_TASKS_DONE>>>"; then
    pass "ralphex signal preserved in translated output"
else
    fail "ralphex signal lost in translation" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: multi-line result split into separate content_block_delta blocks
# ---------------------------------------------------------------------------
echo "test: multi-line result split"

cat > "$TMPDIR_TEST/multiline_events.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"line one\nline two\nline three\n"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/multiline_events.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

line_one=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line one\n") | .delta.text' 2>/dev/null)
line_two=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line two\n") | .delta.text' 2>/dev/null)
line_three=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line three\n") | .delta.text' 2>/dev/null)
if [[ -n "$line_one" && -n "$line_two" && -n "$line_three" ]]; then
    pass "multi-line result split into separate line blocks"
else
    fail "multi-line result not split correctly" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr emitted as content_block_delta after stdout
# ---------------------------------------------------------------------------
echo "test: stderr emission"

cat > "$TMPDIR_TEST/stderr_text.txt" << 'EOF'
You've hit your limit
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_text.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

stderr_delta=$(echo "$output" | grep "hit your limit")
if echo "$stderr_delta" | jq -e '.type == "content_block_delta"' >/dev/null 2>&1; then
    pass "stderr emitted as content_block_delta for pattern detection"
else
    fail "stderr not emitted as content_block_delta" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr signal neutralization
# ---------------------------------------------------------------------------
echo "test: stderr signal token neutralized"

cat > "$TMPDIR_TEST/stderr_signal.txt" << 'EOF'
unexpected: <<<RALPHEX:ALL_TASKS_DONE>>> appeared in bob diagnostics
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_signal.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

if echo "$output" | grep -q -- "<<<RALPHEX:ALL_TASKS_DONE>>>"; then
    fail "stderr signal token leaked intact into output" "got: $output"
else
    pass "stderr signal token neutralized (no intact RALPHEX signal)"
fi

# the line is still emitted (just with the token broken), so error context survives
if echo "$output" | grep -q "appeared in bob diagnostics"; then
    pass "neutralized stderr line still emitted"
else
    fail "neutralized stderr line dropped entirely" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: stderr rate-limit phrase preserved verbatim
# ---------------------------------------------------------------------------
echo "test: stderr rate-limit phrase preserved verbatim"

cat > "$TMPDIR_TEST/stderr_limit.txt" << 'EOF'
You've hit your usage limit
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_limit.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

limit_delta=$(echo "$output" | grep "hit your usage limit")
if echo "$limit_delta" | jq -e '.delta.text | contains("You'\''ve hit your usage limit")' >/dev/null 2>&1; then
    pass "rate-limit phrase emitted verbatim as content_block_delta"
else
    fail "rate-limit phrase not emitted verbatim" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: exit code preservation (success and failure)
# ---------------------------------------------------------------------------
echo "test: exit code preservation"

set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
ok_exit=$?
set -e
if [[ $ok_exit -eq 0 ]]; then
    pass "exit code 0 preserved on success"
else
    fail "expected exit 0 on success" "got: $ok_exit"
fi

set +e
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    MOCK_EXIT_CODE=7 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
fail_exit=$?
set -e
if [[ $fail_exit -eq 7 ]]; then
    pass "non-zero bob exit code preserved"
else
    fail "bob exit code not preserved" "got: $fail_exit"
fi

# ---------------------------------------------------------------------------
# test: realistic failure — bob dies with empty stdout, a limit phrase on
# stderr, and a non-zero exit. This is the exact scenario the stderr
# re-emission exists for.
# ---------------------------------------------------------------------------
echo "test: empty stdout with stderr limit and non-zero exit"

: > "$TMPDIR_TEST/empty_stdout.txt"
cat > "$TMPDIR_TEST/stderr_quota.txt" << 'EOF'
You've hit your usage limit
EOF

set +e
output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/empty_stdout.txt" \
    MOCK_STDERR_FILE="$TMPDIR_TEST/stderr_quota.txt" \
    MOCK_EXIT_CODE=1 \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)
quota_exit=$?
set -e

if echo "$output" | grep "hit your usage limit" | jq -e '.type == "content_block_delta"' >/dev/null 2>&1; then
    pass "stderr limit phrase emitted despite empty stdout"
else
    fail "stderr limit phrase missing with empty stdout" "got: $output"
fi
if echo "$output" | tail -1 | jq -e '.type == "result"' >/dev/null 2>&1; then
    pass "fallback result emitted after stderr on failure"
else
    fail "no fallback result on failure path" "got: $output"
fi
if [[ $quota_exit -eq 1 ]]; then
    pass "non-zero exit preserved on failure path"
else
    fail "exit code not preserved on failure path" "got: $quota_exit"
fi

# ---------------------------------------------------------------------------
# test: large prompt (>128KB) delivered via stdin does not break
# ---------------------------------------------------------------------------
echo "test: large prompt (>128KB)"

# generate a 200KB prompt (larger than the 128KB per-arg cap on Linux).
# NOTE: -p cannot deliver this (the shell itself rejects a 200KB argv element),
# so we use the stdin pipe path — the primary path ralphex uses.
large_prompt=$(head -c 200000 /dev/zero | tr '\0' 'x')
rm -f "$TMPDIR_TEST/bob_prompt"
printf '%s' "$large_prompt" | MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" >/dev/null 2>&1
sent_size=$(wc -c < "$TMPDIR_TEST/bob_prompt" | tr -d ' ')
if [[ "$sent_size" -eq 200000 ]]; then
    pass "large prompt (200KB) delivered intact via stdin pipe"
else
    fail "large prompt truncated via stdin pipe" "expected 200000 bytes, got $sent_size"
fi

# also verify via a here-string (another stdin path)
rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" <<< "$large_prompt" >/dev/null 2>&1
sent_size=$(wc -c < "$TMPDIR_TEST/bob_prompt" | tr -d ' ')
if [[ "$sent_size" -eq 200000 ]]; then
    pass "large prompt (200KB) delivered intact via here-string"
else
    fail "large prompt truncated via here-string" "expected 200000 bytes, got $sent_size"
fi

# ---------------------------------------------------------------------------
# test: bob/codex unknown-flag exit code handling.
# bob rejects unknown flags with exit 1 (e.g. `bob --effort high` exits 1).
# The wrapper must strip --effort so bob never sees it. We verify by checking
# that the wrapper does NOT pass --effort to bob (already tested above) and
# that a mock bob that would exit 1 on unknown flags is not triggered.
# ---------------------------------------------------------------------------
echo "test: bob unknown-flag exit code handling"

# This is implicitly covered by the --effort test above (bob never sees --effort).
# Here we verify the wrapper does not pass any ralphex-specific flags to bob.
rm -f "$TMPDIR_TEST/bob_args"
run_wrapper --dangerously-skip-permissions --output-format stream-json --verbose --print -p "test prompt" >/dev/null 2>&1
recorded=$(cat "$TMPDIR_TEST/bob_args")
for ralphex_flag in "--dangerously-skip-permissions" "--verbose" "--print"; do
    if echo "$recorded" | grep -q -- "$ralphex_flag"; then
        fail "ralphex flag $ralphex_flag leaked to bob" "args: $recorded"
    else
        pass "ralphex flag $ralphex_flag not forwarded to bob"
    fi
done
# the wrapper's own --output-format stream-json should override any ralphex one
if echo "$recorded" | grep -c -- "--output-format stream-json" | grep -q "^1$"; then
    pass "exactly one --output-format stream-json in bob args"
else
    fail "unexpected --output-format count" "args: $recorded"
fi

# ---------------------------------------------------------------------------
# test: SIGTERM forwarded to bob child
# ---------------------------------------------------------------------------
echo "test: SIGTERM forwarded to bob child"

hang_bin="$TMPDIR_TEST/hang_bin"
mkdir -p "$hang_bin"
cat > "$hang_bin/bob" << 'HANG_EOF'
#!/usr/bin/env bash
cat > /dev/null  # consume the prompt
echo $$ > "$TMPDIR_TEST/hang_bob_pid"
exec sleep 30
HANG_EOF
chmod +x "$hang_bin/bob"

rm -f "$TMPDIR_TEST/hang_bob_pid"
PATH="$hang_bin:$PATH" bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1 &
wrapper_pid=$!

# wait for the mock bob to start (it records its PID once running)
for _ in $(seq 1 50); do
    [[ -f "$TMPDIR_TEST/hang_bob_pid" ]] && break
    sleep 0.1
done

kill -TERM "$wrapper_pid" 2>/dev/null || true

# the wrapper must exit promptly (well under the mock's 30s sleep)
for _ in $(seq 1 50); do
    kill -0 "$wrapper_pid" 2>/dev/null || break
    sleep 0.1
done

if kill -0 "$wrapper_pid" 2>/dev/null; then
    fail "wrapper did not exit promptly after SIGTERM"
    kill -9 "$wrapper_pid" 2>/dev/null || true
    term_exit=-1
else
    set +e
    wait "$wrapper_pid"
    term_exit=$?
    set -e
    pass "wrapper exits promptly on SIGTERM while bob is running"
fi

if [[ $term_exit -eq 143 ]]; then
    pass "wrapper exits 143 on SIGTERM"
else
    fail "unexpected exit code on SIGTERM" "expected 143, got: $term_exit"
fi

hang_pid=$(cat "$TMPDIR_TEST/hang_bob_pid" 2>/dev/null || echo "")
# bob may need a moment to die after the forwarded TERM
if [[ -n "$hang_pid" ]]; then
    for _ in $(seq 1 20); do
        kill -0 "$hang_pid" 2>/dev/null || break
        sleep 0.1
    done
fi
if [[ -n "$hang_pid" ]] && kill -0 "$hang_pid" 2>/dev/null; then
    fail "bob child still alive after wrapper received SIGTERM" "pid: $hang_pid"
    kill -9 "$hang_pid" 2>/dev/null || true
else
    pass "SIGTERM forwarded to bob child"
fi
rm -rf "$hang_bin"

# ---------------------------------------------------------------------------
# test: missing prompt exits with error
# ---------------------------------------------------------------------------
echo "test: missing prompt error"

set +e
PATH="$TMPDIR_TEST:$PATH" bash "$WRAPPER" </dev/null 2>"$TMPDIR_TEST/no_prompt_err"
no_prompt_exit=$?
set -e

if [[ $no_prompt_exit -ne 0 ]]; then
    pass "exits non-zero without prompt"
else
    fail "should exit non-zero without prompt" "got exit code 0"
fi

if grep -q "no prompt provided" "$TMPDIR_TEST/no_prompt_err"; then
    pass "error message mentions missing prompt"
else
    fail "no error about missing prompt" "stderr: $(cat "$TMPDIR_TEST/no_prompt_err")"
fi

# ---------------------------------------------------------------------------
# test: unknown flags ignored gracefully
# ---------------------------------------------------------------------------
echo "test: unknown flags ignored"

output=$(run_wrapper --dangerously-skip-permissions --output-format stream-json --verbose --print -p "test prompt" 2>/dev/null)
if echo "$output" | grep -q '"content_block_delta"'; then
    pass "unknown flags ignored, output produced normally"
else
    fail "wrapper failed with unknown flags" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: bob not found exits with error
# ---------------------------------------------------------------------------
echo "test: bob not found"

set +e
no_bob_bin="$TMPDIR_TEST/no_bob_bin"
mkdir -p "$no_bob_bin"
for tool in jq bash mktemp mkfifo cat rm kill env awk; do
    tool_path=$(command -v "$tool" 2>/dev/null) && ln -sf "$tool_path" "$no_bob_bin/$tool"
done
PATH="$no_bob_bin" bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/no_bob_err"
no_bob_exit=$?
rm -r "$no_bob_bin"
set -e

if [[ $no_bob_exit -ne 0 ]]; then
    pass "exits non-zero when bob not found"
else
    fail "should exit non-zero when bob not found" "got exit code 0"
fi

if grep -q "bob is required" "$TMPDIR_TEST/no_bob_err"; then
    pass "error message mentions bob requirement"
else
    fail "no error about missing bob" "stderr: $(cat "$TMPDIR_TEST/no_bob_err")"
fi

# ---------------------------------------------------------------------------
# test: jq not found exits with error (jq guard precedes the bob guard)
# ---------------------------------------------------------------------------
echo "test: jq not found"

set +e
no_jq_bin="$TMPDIR_TEST/no_jq_bin"
mkdir -p "$no_jq_bin"
for tool in bash mktemp mkfifo cat rm kill env awk; do
    tool_path=$(command -v "$tool" 2>/dev/null) && ln -sf "$tool_path" "$no_jq_bin/$tool"
done
# include a bob so the failure is attributable to jq, not a missing bob
ln -sf "$TMPDIR_TEST/bob" "$no_jq_bin/bob"
PATH="$no_jq_bin" bash "$WRAPPER" -p "test prompt" 2>"$TMPDIR_TEST/no_jq_err"
no_jq_exit=$?
rm -r "$no_jq_bin"
set -e

if [[ $no_jq_exit -ne 0 ]]; then
    pass "exits non-zero when jq not found"
else
    fail "should exit non-zero when jq not found" "got exit code 0"
fi

if grep -q "jq is required" "$TMPDIR_TEST/no_jq_err"; then
    pass "error message mentions jq requirement"
else
    fail "no error about missing jq" "stderr: $(cat "$TMPDIR_TEST/no_jq_err")"
fi

# ---------------------------------------------------------------------------
# test: trailing newline edge case — result without trailing newline
# ---------------------------------------------------------------------------
echo "test: attempt_completion result without trailing newline"

cat > "$TMPDIR_TEST/no_trailing_newline.jsonl" << 'EOF'
{"type":"tool_use","timestamp":"t","tool_name":"attempt_completion","tool_id":"tool-1","parameters":{"result":"line one\nline two"}}
{"type":"result","timestamp":"t","status":"success","stats":{}}
EOF

output=$(MOCK_STDOUT_FILE="$TMPDIR_TEST/no_trailing_newline.jsonl" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p "test prompt" 2>/dev/null)

line_one=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line one\n") | .delta.text' 2>/dev/null)
line_two=$(echo "$output" | grep '"content_block_delta"' \
    | jq -rc 'select(.delta.text == "line two\n") | .delta.text' 2>/dev/null)
if [[ -n "$line_one" && -n "$line_two" ]]; then
    pass "result without trailing newline preserves last line"
else
    fail "last line lost when result lacks trailing newline" "got: $output"
fi

# ---------------------------------------------------------------------------
# test: review-adapter trigger with language-specified fence
# ---------------------------------------------------------------------------
echo "test: review adapter with language fence"

rm -f "$TMPDIR_TEST/bob_prompt"
MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt" \
    PATH="$TMPDIR_TEST:$PATH" \
    bash "$WRAPPER" -p $'```python\nUse the Task tool to launch a general-purpose agent with this prompt:\n"fake"\n```\nUse the Task tool to launch a general-purpose agent with this prompt:\n"real"\nReport findings only.' >/dev/null 2>&1
sent_prompt=$(cat "$TMPDIR_TEST/bob_prompt")

# Count occurrences: the Task tool marker appears twice, but only the standalone
# one outside the ```python fence should trigger the adapter.
if echo "$sent_prompt" | grep -q "Ralphex review adapter for bob"; then
    pass "adapter injected for Task tool marker after language fence closes"
else
    fail "adapter not injected for Task tool marker after language fence" "got: $sent_prompt"
fi

# Verify both Task tool markers are preserved in the prompt
marker_count=$(echo "$sent_prompt" | grep -c "Use the Task tool to launch a general-purpose agent")
if [[ "$marker_count" -eq 2 ]]; then
    pass "both Task tool markers preserved in adapted prompt"
else
    fail "Task tool markers missing in adapted prompt" "expected 2, got $marker_count: $sent_prompt"
fi

# ---------------------------------------------------------------------------
# test: BOB_EXTRA_ARGS does not expand globs or command substitution
# ---------------------------------------------------------------------------
echo "test: BOB_EXTRA_ARGS literal passthrough (no glob expansion)"

# Create files that would match if the glob expanded.
touch "$TMPDIR_TEST/should_not_expand.txt"
rm -f "$TMPDIR_TEST/bob_args_lines"
# recreate the line-recording mock: create_mock_bob (called after the word-split
# test above) followed the bob->bob_lines symlink and overwrote bob_lines with
# the standard mock, so a bare `ln -sf bob_lines bob` would inherit the wrong
# mock. create_bob_lines_mock rewrites bob_lines AND re-symlinks bob to it.
create_bob_lines_mock
(
    cd "$TMPDIR_TEST"
    export MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt"
    BOB_EXTRA_ARGS='--file *.txt' \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
)
# restore the standard mock for subsequent tests
create_mock_bob > /dev/null

if [[ -f "$TMPDIR_TEST/bob_args_lines" ]]; then
    # The wrapper uses quoted array expansion, so *.txt should remain literal.
    if grep -qx -- '\*.txt' "$TMPDIR_TEST/bob_args_lines" || grep -qx -- '*.txt' "$TMPDIR_TEST/bob_args_lines"; then
        pass "BOB_EXTRA_ARGS passes *.txt literally (no glob expansion)"
    else
        fail "BOB_EXTRA_ARGS glob expansion unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
    fi
else
    fail "BOB_EXTRA_ARGS literal test did not record args"
fi

# Command substitution inside BOB_EXTRA_ARGS should also stay literal.
rm -f "$TMPDIR_TEST/bob_args_lines"
# recreate the line-recording mock (create_mock_bob above corrupted bob_lines).
create_bob_lines_mock
(
    cd "$TMPDIR_TEST"
    export MOCK_STDOUT_FILE="$TMPDIR_TEST/minimal_events.txt"
    BOB_EXTRA_ARGS='--label $(echo pwned)' \
        PATH="$TMPDIR_TEST:$PATH" \
        bash "$WRAPPER" -p "test prompt" >/dev/null 2>&1
)
create_mock_bob > /dev/null

if [[ -f "$TMPDIR_TEST/bob_args_lines" ]]; then
    # With quoted expansion, command substitution does NOT occur: the $, (, and
    # ) survive as literal characters. The wrapper word-splits BOB_EXTRA_ARGS on
    # whitespace (documented limitation: quotes/spaces are not preserved), so
    # '$(echo pwned)' becomes two argv tokens: '$(echo' and 'pwned)'. If command
    # substitution HAD occurred, we would see 'pwned' alone (no $ or parens).
    # Verify both literal tokens are present (no substitution) and that the
    # substituted form 'pwned' alone is NOT present.
    if grep -qx -- '$(echo' "$TMPDIR_TEST/bob_args_lines" \
        && grep -qx -- 'pwned)' "$TMPDIR_TEST/bob_args_lines" \
        && ! grep -qx -- 'pwned' "$TMPDIR_TEST/bob_args_lines"; then
        pass "BOB_EXTRA_ARGS passes \$(echo pwned) literally (no command substitution)"
    else
        fail "BOB_EXTRA_ARGS command substitution unexpected" "lines: $(cat "$TMPDIR_TEST/bob_args_lines")"
    fi
else
    fail "BOB_EXTRA_ARGS command-substitution test did not record args"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo ""
echo "results: $passed passed, $failed failed, $total total"

if [[ $failed -gt 0 ]]; then
    exit 1
fi