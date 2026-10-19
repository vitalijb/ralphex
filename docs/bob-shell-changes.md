# Changelog

Learn about version-specific updates for Bob Shell.

## 2.0.6
October 2026

### New Features

- **Export tasks to Markdown or JSON**: Run `/export <json|markdown> [file-name]` to save the active task to a file in your workspace. You can also press Ctrl+E in the resume dialog to export the highlighted task.
- **Vim key bindings in the input prompt**: Run `/vim` to switch the input prompt to Vim-style modal editing with INSERT and NORMAL modes. You can also turn on Vim Mode in `/settings`, and Bob Shell remembers your choice between sessions.
- **Emacs-style Ctrl key bindings**: The input prompt now supports readline-style shortcuts: Ctrl+A and Ctrl+E move to the start and end of the line, Ctrl+B and Ctrl+F move the cursor left and right, Ctrl+P moves up, Ctrl+D deletes the character at the cursor, and Ctrl+K deletes to the end of the line.
- **Restart MCP servers with Ctrl+R**: Press Ctrl+R on a server in the MCP dialog to restart it without leaving Bob Shell.
- **Open your settings file with Ctrl+O**: Press Ctrl+O in the Settings dialog to open `settings.json` in your configured editor. If you haven't set an editor yet, Bob Shell prompts you to choose one with `/editor`.
- **Option+Enter for multiline input in macOS Terminal**: Run `/terminal-setup` to configure the macOS Terminal app so that Option+Enter inserts a new line instead of submitting your prompt. Restart the Terminal app after you run the command.
- **Choose the starting mode for new ACP sessions**: When you run Bob Shell as an ACP agent, clients can now set the initial mode of a new session by passing `_meta: { "bob/mode": "<mode id>" }` in `session/new`, without a separate `session/set_mode` call.

### Improvements

- **Auto-approve shortcut is now Ctrl+Y**: Press Ctrl+Y to turn auto-approve on or off. The same shortcut now works on macOS, Windows, Linux, and WSL, and replaces Ctrl+F on macOS and Alt+F on other platforms.
- **Finer control over access outside the workspace**: In non-interactive runs, tool calls outside your workspace now run only when both the global setting and the relevant permission group permit them. When a call is blocked, Bob Shell explains why.
- **Prompts accepted after flags in bob run**: You can now put your prompt after flags that don't take a value, such as `--disable-mcp` and `--disable-subagents`. For example, `bob run --disable-mcp "fix the tests"` now runs as expected. Previously, Bob Shell rejected prompt text that came after these flags and exited with an error.

### Bug Fixes

- **Unlimited cost and turns with zero**: Bob Shell now accepts `--max-cost 0` and `--max-turns 0` to remove the cost and turn limits, as documented. Previously, Bob Shell rejected these values.
- **Background processes work on Windows**: Commands started in the background on Windows now keep running, appear in `/processes`, and stop fully when you end them.
- **SSO_PORT environment variable restored**: Bob Shell again respects the `SSO_PORT` environment variable, so you can sign in with SSO from Docker containers and dev containers by forwarding a fixed port.
- **Adding the first MCP server no longer fails**: `bob mcp add` and `bob mcp add-json` now create the `.bob` configuration directory if it doesn't exist, instead of failing with an `ENOENT` error.
- **Symlinked skills list their supporting files**: Skills in symlinked directories now show their supporting files and skill directory, so Bob can run bundled scripts directly.
- **Language settings apply consistently**: Bob Shell now uses a single language setting across the interface, help output, and agent responses. Changing the language in `/settings` updates the interface immediately, and previously untranslated text is now translated.
- **Cleaner exit and command output display**: Bob Shell now exits cleanly if you quit during sign-in, and long command output no longer overlaps other text.

## 2.0.5
September 2026

### New Features

- **Use Bob Shell in your preferred language**: You can now use Bob Shell in your preferred language. Set the `locale` setting in your Bob Shell configuration to pick your display language independently of your system locale.
- **Control whether Bob fetches external URLs**: You can now control whether Bob is allowed to fetch external URLs directly from Bob Shell settings.
- **Tasks shared between Bob Shell and connected editors**: When you run Bob Shell as an ACP agent, your tasks are now shared with connected editors such as Zed, IntelliJ, and Neovim. You can start a task in Bob Shell and pick it up in your editor, or vice versa, without losing context.
- **Set and remove secrets directly from the command line**: You can now run `/manage-secrets set` and `/manage-secrets rm` with arguments directly, without going through an interactive dialog. This makes it faster to add or remove secrets, and works in scripted or automated workflows.

### Bug Fixes

- **Ctrl+X open-in-editor works with GUI editors**: Pressing Ctrl+X to open a prompt in an external editor now works correctly when `$VISUAL` or `$EDITOR` is set to a GUI editor such as VS Code. Previously, the editor would open but your prompt text was not loaded back into Bob Shell.
- **Tab on slash command autocompletes instead of executing**: Pressing Tab on a slash command suggestion now completes the command in the prompt rather than immediately executing it, giving you a chance to review or append arguments first.
- **File changes in subdirectories now detected**: Bob Shell now correctly picks up file changes inside subdirectories, fixing cases where edits to nested files were missed.
- **Session no longer ends on recoverable errors**: Bob Shell no longer exits when a recoverable error occurs. Your session stays open so you can keep working without restarting.

## 2.0.4
September 2026

### Bug Fixes

- **Auto-update fix for npm 12**: Bob Shell now updates automatically on npm 12. If auto-updates were not working previously, install this release manually to restore automatic update behavior.

## 2.0.3
September 2026

### New Features

- **Background processes**: You can now ask Bob to run commands in the background. For example, ask Bob to run `npm run build` and it will continue running in the background while you keep chatting. Bob also starts longer-running processes in the background automatically.
- **Compaction lifecycle hooks**: You can now run hooks before and after context compaction. Use `PreCompact` to block compaction when conditions are not met, and `PostCompact` to act after compaction completes.
- **MCP OAuth authentication**: You can now authenticate with OAuth-enabled MCP servers in interactive sessions. Open the MCP dialog, press Ctrl+A, and authorize access for your chosen server. Non-interactive session support is planned for a future release.
- **HTTPS hook handlers**: You can now send hook events to HTTPS endpoints. Configure the endpoint URL in your hook settings to route event payloads to any HTTPS target.

### Improvements

- **Improved shell and prompt queuing and navigation**: Shell input queuing and prompt navigation are now more reliable, reducing dropped keystrokes and improving responsiveness under rapid input.
- **Streaming output for shell commands**: You can now view output from your shell commands streaming to the chat view in real time rather than waiting for the command to finish.
- **Shell commands saved to task history**: You can now review or resume a task and see the complete output of previous shell commands, as command inputs and results are saved to task history.
- **Warnings for invalid skill directory names**: Bob now warns you when a skill directory name is invalid, so misconfigured skill directories are easier to identify and fix.
- **Unified /compact slash command**: You can now use `/compact` as the primary slash command to compact context across both Bob IDE and Bob Shell while retaining existing aliases.

### Bug Fixes

- **MCP server list updates when server status changes**: The MCP server list in Bob Shell now refreshes automatically when a server connects or disconnects, keeping the displayed status accurate.
- **Drafts preserved when selecting skills**: Opening the skill picker no longer discards text you have already typed. Your draft prompt is restored when you close the picker.
- **TUI colors stabilized on non-dark terminals**: Terminal UI colors are now consistent across light and non-dark terminal themes, fixing washed-out or invisible text in those environments.
- **--disable-mcp flag behavior corrected**: Passing `--disable-mcp` now correctly disables MCP for the runtime session. Previously, a session with `session.mcp` set to `true` ignored the flag.
- **Console logs no longer leak in debug mode**: Internal console log output is now suppressed correctly when debug mode is inactive, preventing noise in the terminal output.
- **Git fsmonitor disabled in untrusted folders**: Bob Shell now disables git fsmonitor when running git commands in untrusted folders. Git fsmonitor hooks can execute arbitrary code, so this change prevents untrusted repositories from triggering hook execution when you use git mentions such as `@git:commit:` or `@git:branch:`.
- **Various smaller bug fixes**: Various smaller bug fixes that improve the user experience and stabilize Bob.

## 2.0.2
August 2026

### New Features

- **Read and edit Office files**: You can now read and edit `.docx`, `.xlsx`, and `.pptx` files using two new tools: `office_read` and `office_edit`. Use `office_read` to extract text, view structural outlines, access individual elements, or dump the full file contents. Use `office_edit` to set values, add or remove content, and run find-and-replace operations. The `read_file` tool automatically forwards Office files to `office_read`. This feature is also available in Bob IDE 2.1.0.
- **Agent Client Protocol (ACP)**: Run `bob acp` to expose Bob Shell as an ACP agent. Any ACP-compatible editor, including Zed, IntelliJ, and Neovim, can connect to Bob Shell as a first-class AI assistant. Bob's full runtime is available through the ACP connection, including modes, MCP servers, skills, tool approvals, and session management. When Bob proposes a file change through the ACP connection, the diff is visible in the approval prompt before you accept or reject the edit.
- **Git and MCP mention pickers**: Type `@` in the Bob Shell prompt to open a picker for git commits, branches, working-tree changes, or MCP resources. The selected item is resolved and inserted into your message before it is sent.
- **Edit prompts in an external editor**: Press Ctrl+X or run `/editor` while typing a prompt to open the current input in your preferred terminal editor (`$VISUAL`, `$EDITOR`, or `vi` as a fallback). When you save and close the editor, the text is loaded back into the prompt.
- **Hooks management**: Run `/hooks` to open a dialog that lists all configured global and workspace hooks. The dialog shows each hook's event type, matcher, scope, status, and command. You can toggle individual hooks on or off, and the list refreshes automatically when hook settings change on disk. Bob IDE 2.1.0 also adds hooks management via the Hooks tab in Bob Settings.
- **z/OS and Linux on IBM Z support**: Bob Shell now runs on z/OS UNIX System Services (os390-s390x) and Linux on IBM Z, enabling AI-assisted terminal workflows directly on Z platforms.

### Improvements

- **Full MCP tool output saved to disk when truncated**: When a tool call produces output that exceeds the context limit, the full output is saved to disk and the truncated message includes the file path. You can then use `read_file` with a range to inspect any section of the output rather than working with incomplete information.
- **Oversized images resized automatically**: PNG, JPEG, and GIF images larger than 768 px are resized before they are added to task messages. This prevents payload size errors when a session includes many screenshots or large images.
- **Enforce hooks across all users with a policy**: Administrators can now use the `EnforcedHooks` policy to inject hooks that run before any user-defined hooks. Enforced hooks cannot be overridden or disabled by users, making them suitable for organization-wide requirements such as audit logging.

### Bug Fixes

- **Global skill directories excluded from workspace scope**: Skills in global skill directories are no longer included in workspace-scoped skill discovery, preventing duplicate or unexpected skill entries.
- **Saved tool outputs readable in the same session**: Bob can now read tool output files that were saved to disk in the same session, so large outputs that exceed the context limit remain accessible rather than being lost.
- **Team picker exits with Ctrl+C**: When Bob Shell starts with an invalid `--team` or `--instance` argument, the mandatory team picker now accepts Ctrl+C to exit cleanly. A footer hint confirms the shortcut. Pressing Esc does not dismiss a mandatory dialog.

## 2.0.1
August 2026

### Improvements

- **alwaysAllow MCP tools respected in Bob Shell**: MCP tools listed in `alwaysAllow` inside `.bob/mcp.json` are now automatically approved on the first tool call of a task in Bob Shell. Previously, this setting was honored only in the IDE extension.
- **Increased task history retention**: The default task retention period is now 30 days. Setting `tasks.retentionDays` to `0` disables automatic cleanup so that all task history is kept indefinitely.
- **Platform-aware auto-approve keyboard shortcut**: The keyboard shortcut to toggle auto-approve is now `Alt+F` on Windows, Linux, and WSL. On macOS, the shortcut remains `Ctrl+F`.
- **New slash command aliases**: Four slash commands now accept shorter aliases: `/history` for `/resume`, `/compact` for `/condense`, `/trust` for `/permissions`, and `/info` for `/status`.

### Bug Fixes

- **Settings changes always require explicit approval**: Writes to `.bob/settings.json` and `~/.bob/*/settings.json` now always require one-time explicit user approval, even when auto-approve is enabled. Auto-approve cannot be used to bypass approval for changes to Bob settings files.
- **Auto-approve blocked for Bob home directory writes**: Tool calls that write to Bob's home directory (for example, `~/.bob/`) are no longer automatically approved when auto-approve mode is on. These calls always prompt for explicit approval.
- **Workspace root resolved correctly from subdirectories**: Bob Shell now prioritizes `.git` over `.bob` when walking up the directory tree to find the workspace root. Starting Bob Shell from inside a package subdirectory that contains its own `.bob/` folder no longer causes workspace-scoped skills, rules, and modes to be silently missed.
- **MCP tool approval respects group-level permission**: An MCP tool listed in the per-task allowlist is no longer auto-approved unless the `mcp` permission group has also been granted for the task. Previously, the per-tool allowlist could bypass the broader group approval gate.
- **Bob Shell no longer hangs on exit**: Fixed an issue where Bob Shell did not exit cleanly after pressing `Ctrl+C`. The policy-watcher process is now disposed correctly on shutdown.
- **Deprecated --list-sessions and --limit flags restored**: The `--list-sessions` and `--limit <number>` flags that were removed in 2.0.0 are restored as silent aliases for `--list-tasks`. Existing scripts that use these flags continue to work without modification.
- **Increased MCP tool payload limit**: The MCP tool payload limit is increased to 300 KB. This fixes an issue where MCP servers that expose large tool definitions caused Bob Shell to fail.

## 2.0.0
August 2026

### New Features

- **Message queue**: Queue follow-up messages while Bob is still responding. Press Tab to add a message to the queue; queued messages are sent automatically in order as each turn completes. Reorder or remove items from the queue at any time.
- **MCP management commands**: Manage Model Context Protocol servers directly from the CLI with `bob mcp add`, `bob mcp add-json`, `bob mcp remove`, and `bob mcp list`. Supports both global and workspace scopes, and stdio, SSE, and HTTP transports.
- **Skills**: Create reusable instruction sets that teach Bob new workflows and specialized tasks. Define custom workflows, add supporting files, and share skills across your team through version control. Skills were not available in Bob Shell 1.0.x.

### Improvements

- **Redesigned settings schema**: Settings are now stored at `~/.bob/settings/settings.json`. The schema adds a `telemetry` section, an `edit` tool group, and clearer per-setting documentation. CLI flags and the `/settings` slash command override file values for the current session.
- **Agent mode replaces Code and Advanced modes**: The previous Code mode and Advanced mode have been consolidated into a single Agent mode. Agent mode takes autonomous action to complete tasks.
- **Expanded non-interactive output schema**: The JSON output from `bob run` now includes a `stats` object with per-session token counts, cache ratios, cost, duration, and tool call totals. Structured event types (`message`, `tool_use`, `tool_result`, `error`) make it easier to parse results in CI/CD pipelines.
