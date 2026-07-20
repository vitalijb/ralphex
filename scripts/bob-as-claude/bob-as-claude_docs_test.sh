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
    "- command" \
    "task mode allows command"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-task.yaml" \
    "- browser" \
    "task mode allows browser"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-review.yaml" \
    "customInstructions" \
    "review mode contains custom instructions"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- read" \
    "plan mode allows read"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- command" \
    "plan mode allows command"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- browser" \
    "plan mode allows browser"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/modes/ralphex-plan.yaml" \
    "- edit" \
    "plan mode excludes edit"

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
    "ralphex-plan" \
    "wrapper README documents plan mode"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/README.md" \
    "BOB_CUSTOM_MODES_FILE" \
    "wrapper README documents custom-mode target override"
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
    "attempt_completion" \
    "custom providers doc documents bob event translation"
assert_contains \
    "$REPO_ROOT/docs/custom-providers.md" \
    "### Automatic phase mapping" \
    "custom providers doc documents bob chat-mode section"
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
    'Review start markers select `ralphex-review`' \
    "CLAUDE documents current Bob review trigger"
assert_not_contains \
    "$REPO_ROOT/CLAUDE.md" \
    "Review adapter is prepended" \
    "CLAUDE removes stale Bob review-adapter trigger"

# regression-test hardening
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "GOFLAGS=-mod=vendor" \
    "wrapper tests validate YAML with vendored yaml.v3"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "ralphexGroups" \
    "wrapper tests assert exact shipped tool groups"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "verify every finding" \
    "wrapper tests assert review finding verification instructions"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "<<<RALPHEX:REVIEW_DONE>>>" \
    "wrapper tests assert review signal instructions"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "<<<RALPHEX:QUESTION>>>" \
    "wrapper tests cover individual plan markers"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "BOB_CHAT_MODE=\"code\"" \
    "wrapper tests cover built-in overrides"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "partial_target" \
    "wrapper tests cover partially installed modes"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "env -u BOB_CUSTOM_MODES_FILE" \
    "wrapper tests isolate the installer's HOME"
assert_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "create_mock_bob" \
    "wrapper tests define a mock Bob"
assert_not_contains \
    "$REPO_ROOT/scripts/bob-as-claude/bob-as-claude_test.sh" \
    "curl " \
    "wrapper tests do not invoke a network client"

echo ""
echo "summary: $passed passed, $failed failed, $total total"

if [[ $failed -ne 0 ]]; then
    exit 1
fi
