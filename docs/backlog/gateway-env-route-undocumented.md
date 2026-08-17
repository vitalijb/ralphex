---
worth: yes
where: docs/custom-providers.md
added: 2026-08-10
---
# pointing ralphex at an Anthropic-compatible gateway is supported but documented nowhere

`-E`/`RALPHEX_EXTRA_ENV` already carries `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` into the
container, and `claudeChildEnv` (`pkg/executor/executor.go`) strips only `ANTHROPIC_API_KEY` and
`CLAUDECODE`, so both reach the child claude untouched. Real Claude Code then talks its native protocol to
whatever endpoint is named. This works today, on master, with no code changes.

Nothing says so. `docs/custom-providers.md` is entirely about the `claude_command` wrapper path — swapping
in a *different CLI* that emits compatible stream-json (codex, copilot, gemini, agy, opencode, pi) — which
is the wrong mechanism for a gateway that already speaks the Anthropic API. `README.md:435` documents
`RALPHEX_EXTRA_ENV` generically, with `DEBUG=1,API_KEY` as its example, and never connects it to provider
routing. A user wanting to run through a gateway has no way to discover the supported route and concludes
it needs new code.

Worth a short brand-neutral section in `docs/custom-providers.md`: the two env vars, the `-E VAR` inherit
form for the token so the value stays out of `ps`, and a note that gateways generally require their own
model-id namespacing, overridable per-run via `-E ANTHROPIC_DEFAULT_*_MODEL=`. Named gateways can appear as
unlinked examples. Pairs with `wrapper-blocks-users-without-local-claude-creds.md` — documenting the route
is only half useful while the credential gate still blocks the users who need it.

Surfaced reviewing PR #429, whose entire `docker -e` output turned out to be flag-for-flag identical to six
existing `-E` flags. The discoverability hole is what made a vendor-specific PR look necessary, and it
stands regardless of that PR's outcome.
