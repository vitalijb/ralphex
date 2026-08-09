#!/usr/bin/env bash
# bob-as-claude_docs_test.sh — validates bob wrapper documentation and repo integration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

assert_contains() {
    local file="$1"
    local needle="$2"
    local label="$3"

    if grep -Fq -- "$needle" "$file"; then
        pass "$label"
    else
        fail "$label" "missing '$needle' in $file"
    fi
}

assert_not_contains() {
    local file="$1"
    local needle="$2"
    local label="$3"

    if grep -Fq -- "$needle" "$file"; then
        fail "$label" "unexpected '$needle' in $file"
    else
        pass "$label"
    fi
}

# asserts a needle is absent from one section of a file, so a legitimate mention of a
# removed v1 flag elsewhere (e.g. the Copilot `--yolo` guidance) does not fail the check.
assert_section_not_contains() {
    local file="$1"
    local start_regex="$2"
    local end_regex="$3"
    local needle="$4"
    local label="$5"

    local section
    section=$(awk -v start="$start_regex" -v end="$end_regex" '
        !inside && $0 ~ start { inside = 1; print; next }
        inside && $0 ~ end { inside = 0 }
        inside { print }
    ' "$file")

    if [[ -z "$section" ]]; then
        fail "$label" "section matching '$start_regex' not found in $file"
        return
    fi
    if grep -Fq -- "$needle" <<< "$section"; then
        fail "$label" "unexpected '$needle' in the '$start_regex' section of $file"
    else
        pass "$label"
    fi
}

assert_matches() {
    local file="$1"
    local regex="$2"
    local label="$3"

    if grep -Eq -- "$regex" "$file"; then
        pass "$label"
    else
        fail "$label" "no line matching '$regex' in $file"
    fi
}

assert_executable() {
    local file="$1"
    local label="$2"

    if [[ -x "$file" ]]; then
        pass "$label"
    else
        fail "$label" "$file is not executable"
    fi
}

assert_file() {
    local file="$1"
    local label="$2"

    if [[ -f "$file" ]]; then
        pass "$label"
    else
        fail "$label" "$file does not exist"
    fi
}

echo "running bob-as-claude docs tests"
echo ""

assert_executable "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude.sh" "wrapper script is executable"
assert_executable "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" "wrapper shell test is executable"
assert_executable "$REPO_ROOT/scripts/bob-as-claude/install-modes.sh" "custom-mode installer is executable"

# shipped custom modes
for mode in ralphex-task ralphex-review ralphex-plan; do
    assert_file \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "$mode mode file exists"
    assert_contains \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "slug: $mode" \
        "$mode mode declares its slug"
done
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "- read" \
    "task mode allows read"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "- edit" \
    "task mode allows edit"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "- execute" \
    "task mode allows execute"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-review.yaml" \
    "customInstructions" \
    "review mode contains custom instructions"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-review.yaml" \
    "- subagent" \
    "review mode allows native subagents"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-review.yaml" \
    "spawn_subagent" \
    "review mode delegates through native spawn_subagent"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-review.yaml" \
    "single turn so they run in parallel" \
    "review mode issues subagent assignments in parallel"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- read" \
    "plan mode allows read"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- execute" \
    "plan mode allows execute"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- edit" \
    "plan mode allows accepted plan write"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "Return every plan boundary as ordinary assistant text" \
    "plan mode returns boundaries as assistant text"

# v1 tool groups and the removed terminal tool must not survive in any shipped mode
for mode in ralphex-task ralphex-review ralphex-plan; do
    assert_not_contains \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "- command" \
        "$mode mode drops the invalid command group"
    assert_not_contains \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "- browser" \
        "$mode mode drops the invalid browser group"
    assert_not_contains \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "attempt_completion" \
        "$mode mode drops the removed attempt_completion tool"
    assert_not_contains \
        "$REPO_ROOT/scripts/bob-as-claude/modes/$mode.yaml" \
        "allowedSubagents" \
        "$mode mode declares no allowedSubagents key"
done

# the wrapper targets bob v2 only: no v1 flags, no version-detection branch
for needle in "--chat-mode" "--yolo" "--hide-intermediary-output" "--output-format" \
    "attempt_completion" "<thinking>"; do
    assert_not_contains \
        "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude.sh" \
        "$needle" \
        "wrapper drops v1 artifact $needle"
done
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude.sh" \
    "run -f stream-json" \
    "wrapper uses the v2 run subcommand and stream format"

# wrapper README
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "claude_command = /path/to/scripts/bob-as-claude/bob-as-claude.sh" \
    "wrapper README contains config snippet"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_VERBOSE" \
    "wrapper README documents BOB_VERBOSE env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_CHAT_MODE" \
    "wrapper README documents BOB_CHAT_MODE env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_MODEL" \
    "wrapper README documents BOB_MODEL env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_EXTRA_ARGS" \
    "wrapper README documents BOB_EXTRA_ARGS env var"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "bash scripts/bob-as-claude/install-modes.sh" \
    "wrapper README documents custom-mode installation"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "ralphex-task" \
    "wrapper README documents task mode"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "ralphex-review" \
    "wrapper README documents review mode"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_SESSION" \
    "wrapper README documents native nesting protection"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "no guard shims" \
    "wrapper README documents guard-shim removal"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "spawn_subagent" \
    "wrapper README documents native parallel review subagents"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "idle_timeout" \
    "wrapper README documents subagent silence and idle_timeout"
# headless `bob run` never constructs bob's approval handler, so the docs must describe
# mode groups + --trust as the only gate and must not send users to a settings grant.
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "### What governs tool access" \
    "wrapper README documents what governs headless tool access"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "getToolsForGroups" \
    "wrapper README names the mode-group tool resolution"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "is **not** read by \`bob run\`" \
    "wrapper README states approval settings are unread headlessly"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "handleToolApproval" \
    "wrapper README names the interactive-only approval entry point"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "\`--auto-approve\` exists on \`bob chat\` but not on \`bob run\`" \
    "wrapper README cites --auto-approve as evidence"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "--grant-approvals" \
    "wrapper README drops the removed approval grant flag"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_SETTINGS_FILE" \
    "wrapper README drops the removed settings path override"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "allowedExecutors" \
    "wrapper README drops the unreachable allowedExecutors guidance"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "15-entry" \
    "wrapper README drops the unverified default approvedCommands count"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "bob run -f stream-json" \
    "wrapper README documents the v2 invocation"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "bob 2.0.0 or newer" \
    "wrapper README states the minimum bob version"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "~/.claude/skills" \
    "wrapper README documents the auto-loaded Claude skills caveat"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "--chat-mode" \
    "wrapper README drops the v1 --chat-mode flag"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "--hide-intermediary-output" \
    "wrapper README drops the v1 --hide-intermediary-output flag"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "--output-format=stream-json" \
    "wrapper README drops the v1 --output-format flag"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "attempt_completion" \
    "wrapper README drops the removed attempt_completion tool"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "ralphex-plan" \
    "wrapper README documents plan mode"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_CUSTOM_MODES_FILE" \
    "wrapper README documents custom-mode target override"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "~/.bob/settings/custom_modes.yaml" \
    "wrapper README documents bob's active global mode path"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    ".bob/custom_modes.yaml" \
    "wrapper README documents project mode precedence"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "does not silently fall back" \
    "wrapper README documents installation requirement"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "complete plan signal set" \
    "wrapper README documents plan marker mapping"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "exact review headers" \
    "wrapper README documents strict review markers"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "matching delimiter character" \
    "wrapper README documents compatible fence closing"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "task and finalize prompts" \
    "wrapper README documents task and finalize mapping"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "Any non-empty built-in slug" \
    "wrapper README documents unrestricted explicit override"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "Plan creation is untested" \
    "wrapper README removes stale plan limitation"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "### Review adapter" \
    "wrapper README removes stale review adapter section"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "bash scripts/bob-as-claude/bob-as-claude_test.sh" \
    "wrapper README includes wrapper test command"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "## Limitations" \
    "wrapper README includes Limitations section"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "## Security considerations" \
    "wrapper README includes Security considerations section"

# custom providers doc
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "## IBM Bob Shell CLI wrapper (included example)" \
    "custom providers doc includes bob section"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "custom providers doc references bob wrapper path"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "isReasoning" \
    "custom providers doc documents bob event translation"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "error.message" \
    "custom providers doc documents v2 tool_result error field"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "bob run -f stream-json --mode=<slug> --trust" \
    "custom providers doc documents the v2 invocation"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "Minimum supported version: bob 2.0.0" \
    "custom providers doc states the minimum bob version"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "### What governs tool access" \
    "custom providers doc documents what governs headless tool access"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "getToolsForGroups" \
    "custom providers doc names the mode-group tool resolution"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "is **not** consulted by \`bob run\`" \
    "custom providers doc states approval settings are unread headlessly"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "handleToolApproval" \
    "custom providers doc names the interactive-only approval entry point"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "\`--auto-approve\` exists on \`bob chat\` but not on \`bob run\`" \
    "custom providers doc cites --auto-approve as evidence"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "\`ralphex-review\` adds \`subagent\`" \
    "custom providers doc documents the review-mode subagent group"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "--grant-approvals" \
    "custom providers doc drops the removed approval grant flag"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "BOB_SETTINGS_FILE" \
    "custom providers doc drops the removed settings path override"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "allowedExecutors" \
    "custom providers doc drops the unreachable allowedExecutors guidance"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "15-entry" \
    "custom providers doc drops the unverified default approvedCommands count"
# the wrapper fails the run on every error event regardless of severity, so the event
# table must not promise a severity filter that does not exist in the code.
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    '| `error` (any `severity`) |' \
    "custom providers doc event table matches error events at any severity"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "The event's \`severity\` field is **not** inspected" \
    "custom providers doc states severity is not inspected"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "unspecified bob error" \
    "custom providers doc documents the empty-message error placeholder"
# the forced non-zero exit alone cannot fail a run whose stream already carried a
# signal, so the doc must record the TASK_FAILED retraction the wrapper emits.
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    'the wrapper also emits `<<<RALPHEX:TASK_FAILED>>>` after the diagnostic' \
    "custom providers doc documents the post-signal failure retraction"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    'severity == "error"' \
    "custom providers doc drops the stale severity filter claim"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "spawn_subagent" \
    "custom providers doc documents native parallel review subagents"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "BOB_SESSION" \
    "custom providers doc documents native nesting protection"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "idle_timeout" \
    "custom providers doc documents subagent silence and idle_timeout"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "~/.claude/skills" \
    "custom providers doc documents the auto-loaded Claude skills caveat"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "\`read\`, \`edit\`, \`execute\`, \`mcp\`, \`skill\`, \`todo\`, \`subagent\`, \`mode\`" \
    "custom providers doc lists the valid v2 tool groups"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "### Automatic phase mapping" \
    "custom providers doc documents bob chat-mode section"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "Exact review headers" \
    "custom providers doc documents strict review markers"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "matching delimiter character" \
    "custom providers doc documents compatible fence closing"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "bash scripts/bob-as-claude/install-modes.sh" \
    "custom providers doc documents custom-mode installation"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "ralphex-task" \
    "custom providers doc documents task mode"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "ralphex-review" \
    "custom providers doc documents review mode"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "ralphex-plan" \
    "custom providers doc documents plan mode"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "BOB_CHAT_MODE=<slug>" \
    "custom providers doc documents explicit override"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "<<<RALPHEX:ALL_TASKS_DONE>>>" \
    "custom providers doc uses the task completion signal"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "<<<RALPHEX:COMPLETED>>>" \
    "custom providers doc removes the nonexistent completion signal"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "passes review prompts unchanged" \
    "custom providers doc removes prompt adapter mutation"
assert_not_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    'Plan creation mode (`ralphex --plan`) has no bob-specific adapter' \
    "custom providers doc removes stale plan limitation"

# top-level README
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "top-level README mentions bob wrapper"
# anchor on the stable facts (bob + jq on one line), not exact prose
assert_matches \
    "$REPO_ROOT/README.md" \
    "bob wrappers.*\`jq\`" \
    "top-level README documents jq requirement for bob wrapper"
assert_contains \
    "$REPO_ROOT/README.md" \
    "BOB_CHAT_MODE" \
    "top-level README documents bob-specific environment variables"
assert_contains \
    "$REPO_ROOT/README.md" \
    "Bob wrapper also requires" \
    "top-level README documents awk requirement for bob wrapper"
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/" \
    "top-level README requirements list mentions bob wrapper dir"
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "top-level README inventories shipped Bob modes"
assert_contains \
    "$REPO_ROOT/README.md" \
    "scripts/bob-as-claude/install-modes.sh" \
    "top-level README inventories Bob installer"
assert_contains \
    "$REPO_ROOT/README.md" \
    "bob 2.0.0 or newer" \
    "top-level README states the minimum bob version"
assert_contains \
    "$REPO_ROOT/README.md" \
    "does not read the \`approval\` section" \
    "top-level README states approval settings are unread headlessly"
assert_contains \
    "$REPO_ROOT/README.md" \
    "installing the modes is the whole setup step" \
    "top-level README states mode installation is the only setup step"
assert_not_contains \
    "$REPO_ROOT/README.md" \
    "--grant-approvals" \
    "top-level README drops the removed approval grant flag"
assert_not_contains \
    "$REPO_ROOT/README.md" \
    "BOB_SETTINGS_FILE" \
    "top-level README drops the removed settings path override"
# the v1 flags and terminal tool are gone from every live doc. --yolo is excluded here:
# the bob sections mention it in "removed in v2" prose, and Copilot's docs use it for real.
# docs/custom-providers.md is excluded from the loop for the same reason — its migration
# paragraph names the removed flags on purpose, and is pinned by the assertion below.
for doc in README.md llms.txt CLAUDE.md; do
    assert_not_contains \
        "$REPO_ROOT/$doc" \
        "--chat-mode=" \
        "$doc drops the v1 --chat-mode invocation"
    assert_not_contains \
        "$REPO_ROOT/$doc" \
        "--hide-intermediary-output" \
        "$doc drops the v1 --hide-intermediary-output flag"
done
assert_matches \
    "$REPO_ROOT/docs/custom-providers.md" \
    "removed \`--yolo\`, \`--hide-intermediary-output\`, and model selection" \
    "custom providers doc names the removed v1 flags only as removed"
assert_section_not_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "^bob wrapper:" \
    "^### AWS Bedrock Provider" \
    "--output-format=stream-json" \
    "CLAUDE bob paragraph drops the v1 --output-format flag"
assert_section_not_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "^bob wrapper:" \
    "^### AWS Bedrock Provider" \
    "attempt_completion" \
    "CLAUDE bob paragraph drops the removed attempt_completion tool"
assert_section_not_contains \
    "$REPO_ROOT/llms.txt" \
    "^The Bob wrapper requires bob 2\.0\.0" \
    "^\*\*Codex executor mode" \
    "attempt_completion" \
    "llms.txt bob section drops the removed attempt_completion tool"

# llms.txt
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "llms.txt wrapper inventory mentions bob wrapper"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/" \
    "llms.txt requirements list mentions bob wrapper dir"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "llms.txt inventories shipped Bob modes"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "scripts/bob-as-claude/install-modes.sh" \
    "llms.txt inventories Bob installer"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "~/.bob/settings/custom_modes.yaml" \
    "llms.txt documents bob's active global mode path"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "bob 2.0.0 or newer" \
    "llms.txt states the minimum bob version"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "bob run -f stream-json --mode=<slug> --trust" \
    "llms.txt documents the v2 invocation"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "it does not read the \`approval\` section" \
    "llms.txt states approval settings are unread headlessly"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "installing the shipped modes is the whole setup step" \
    "llms.txt states mode installation is the only setup step"
assert_not_contains \
    "$REPO_ROOT/llms.txt" \
    "--grant-approvals" \
    "llms.txt drops the removed approval grant flag"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "spawn_subagent" \
    "llms.txt documents native parallel review subagents"
assert_contains \
    "$REPO_ROOT/llms.txt" \
    "~/.claude/skills" \
    "llms.txt documents the auto-loaded Claude skills caveat"

# CLAUDE.md
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/ # IBM Bob Shell CLI wrapper for Claude-compatible output" \
    "CLAUDE inventory includes bob wrapper directory"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/bob-as-claude.sh" \
    "CLAUDE alternative provider docs mention bob wrapper path"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/modes/" \
    "CLAUDE inventory includes Bob modes directory"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "scripts/bob-as-claude/install-modes.sh" \
    "CLAUDE inventory includes Bob installer"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "~/.bob/settings/custom_modes.yaml" \
    "CLAUDE documents bob's active global mode path"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    'Review start markers select `ralphex-review`' \
    "CLAUDE documents current Bob review trigger"
assert_not_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "Review adapter is prepended" \
    "CLAUDE removes stale Bob review-adapter trigger"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "bob run -f stream-json --mode=<slug> --trust" \
    "CLAUDE documents the v2 invocation"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "isReasoning" \
    "CLAUDE documents the v2 reasoning flag"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "there is no approval preflight and no \`BOB_SETTINGS_FILE\` handling" \
    "CLAUDE states the approval preflight is gone"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "Do not reintroduce an approval preflight" \
    "CLAUDE warns against reintroducing the approval preflight"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "the installer takes no arguments and rejects unknown ones" \
    "CLAUDE documents the argument-free installer"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "\`severity\` is not inspected" \
    "CLAUDE states error severity is not inspected"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "bob_signal_emitted" \
    "CLAUDE documents the post-signal failure retraction"
assert_not_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "\`BOB_VERBOSE\`, \`BOB_EXTRA_ARGS\`, \`BOB_SETTINGS_FILE\`" \
    "CLAUDE drops BOB_SETTINGS_FILE from the bob env-var list"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "spawn_subagent" \
    "CLAUDE documents native parallel review subagents"
assert_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "BOB_SESSION" \
    "CLAUDE documents native nesting protection"

echo ""
echo "summary: $passed passed, $failed failed, $total total"

if [[ $failed -ne 0 ]]; then
    exit 1
fi
