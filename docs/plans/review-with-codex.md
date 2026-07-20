Review and enhance bob-as-claude wrapper with bob custom modes

Context

The ralphex repo (/home/fg-klo/ralphex) includes a scripts/bob-as-claude/ wrapper that makes IBM Bob Shell CLI (bob) act as a drop-in replacement for Claude Code in ralphex's task and review phases. The wrapper was modelled on scripts/pi-as-claude/pi-as-claude.sh.

The wrapper currently uses a single BOB_CHAT_MODE env var (default code) for all ralphex phases (plan, task, review, finalize). This is suboptimal: review benefits from read-only or read+edit modes, task execution needs full write/command access, and plan creation is untested.

Bob supports custom modes via YAML config (~/.bob/custom_modes.yaml or .bob/custom_modes.yaml), each with a slug, roleDefinition, groups (toolset allow-list: read, edit, browser, command, mcp), whenToUse, and customInstructions. Modes are selected via bob --chat-mode=<slug>. See:
- Custom modes: https://bob.ibm.com/docs/shell/configuration/custom-modes-bobshell
- Slash commands: https://bob.ibm.com/docs/shell/features/slash-commands
- Tools: https://bob.ibm.com/docs/shell/core-concepts/tools

Task

1. Review the existing wrapper

Carefully review scripts/bob-as-claude/bob-as-claude.sh, bob-as-claude_test.sh, bob-as-claude_docs_test.sh, and README.md. Read scripts/pi-as-claude/pi-as-claude.sh as the reference implementation. Read docs/custom-providers.md for how the wrapper is documented. Read CLAUDE.md for the project conventions the wrapper must follow.

Identify any bugs, deviations from the pi-as-claude pattern, or violations of umputun's conventions (see CLAUDE.md: lowercase comments, --flag=value form in docs, test coverage, etc.).

2. Add per-phase bob custom mode support

Ship custom mode YAML files under scripts/bob-as-claude/modes/ that define ralphex-specific bob modes:

- ralphex-task — full read/write/command access for task execution. groups: [read, edit, command, browser]. roleDefinition: a coding agent executing plan tasks one at a time, committing after each.
- ralphex-review — read + command (for git) + edit (for fixes). groups: [read, edit, command, browser]. roleDefinition: a sequential code review agent that collects findings, verifies, fixes confirmed issues, and commits fixes. customInstructions: sequential review guidance (the current adapter text, refactored into mode instructions).
- ralphex-plan — read + command for plan creation. groups: [read, command, browser]. roleDefinition: a planning agent that explores the codebase and produces a structured plan. No edit access (plan creation should not modify source files).

Each mode file should include whenToUse guidance so bob can auto-select when interactive.

The wrapper should map ralphex phases to bob modes automatically:
- If BOB_CHAT_MODE is set explicitly, honour it (user override — backward compat).
- Otherwise, detect the ralphex phase from the prompt content (review markers, plan-creation signals) and select the appropriate custom mode.
- Install the mode files: if ~/.bob/custom_modes.yaml exists, merge; if not, create. Provide an install-modes.sh helper script. Document this in README.md.

3. Move review adapter logic into the ralphex-review mode

The current review adapter (prepended text in the wrapper) should be refactored into the ralphex-review mode's customInstructions. The wrapper should still detect review prompts and select ralphex-review mode, but no longer prepend adapter text — the mode's customInstructions handles the sequential-review guidance. The strict trigger detection (review START markers outside fenced code blocks) stays in the wrapper for mode selection; the mode instructions provide the behavioral guidance.

4. Update documentation

Following umputun's conventions (see CLAUDE.md, existing wrapper READMEs):
- scripts/bob-as-claude/README.md — document custom modes, the phase→mode mapping, install script, and updated env vars.
- docs/custom-providers.md — update the bob section with custom mode info.
- README.md (top-level) — update if requirements change.
- llms.txt — update wrapper inventory if needed.
- CLAUDE.md — update if project structure changes.

5. Update/add tests

- bob-as-claude_test.sh — add tests for phase→mode detection, custom mode YAML validity, install script behaviour.
- bob-as-claude_docs_test.sh — add assertions for new docs (custom modes section, install script mention).
- All tests must pass with 0 failures. No real API calls (use mock bob).
- Follow the existing test patterns (mock bob, pass/fail helpers, assert_contains/assert_matches).

6. Commit

Commit with conventional-commit messages:
- feat(bob-as-claude): add per-phase custom bob modes
- docs(bob-as-claude): document custom modes and phase mapping
- test(bob-as-claude): add custom mode tests

Do not push.

Constraints

- Single bash wrapper script (bob-as-claude.sh) — no Go changes.
- Custom mode YAML files under scripts/bob-as-claude/modes/.
- Follow CLAUDE.md conventions: lowercase comments, --flag=value in docs, test coverage.
- Mirror pi-as-claude.sh structure where applicable.
- Backward compat: BOB_CHAT_MODE override still works.
- No real API calls in tests.
- All existing tests must still pass.
