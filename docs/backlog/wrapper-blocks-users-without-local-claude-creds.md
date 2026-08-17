---
worth: yes
where: scripts/ralphex-dk.sh:1121
added: 2026-08-10
---
# docker wrapper is unusable without local Claude credentials, even when auth comes from a gateway

`scripts/ralphex-dk.sh:1121` refuses to start unless `~/.claude` exists as a directory, and `:1133-1141`
additionally fails fast on macOS unless `~/.claude/.credentials.json` exists or keychain extraction
succeeds. Both gates are skipped only for `provider == "bedrock"`.

That blocks the whole class of users who authenticate through an Anthropic-compatible gateway rather than
Anthropic directly — any `ANTHROPIC_BASE_URL` endpoint, a corporate proxy, LiteLLM, or a self-hosted
relay. They have no Anthropic account and no reason to have run `claude` locally, so `~/.claude` does not
exist. The generic `-E`/`RALPHEX_EXTRA_ENV` route that would otherwise carry `ANTHROPIC_BASE_URL` and
`ANTHROPIC_AUTH_TOKEN` into the container is unreachable, because these gates run first. On Linux the
workaround is `mkdir -p ~/.claude`; on macOS it additionally needs a placeholder credentials file.

The gap is provider-neutral. Anything that closes it should stay that way — a mode meaning "this run does
not use local Claude credentials", not a per-vendor branch. Adding one vendor name to the gate condition
solves it for that vendor and leaves the same hole for the next.

Surfaced reviewing PR #429, which hit this gate and closed it by hardcoding a specific commercial
gateway's name into all five `provider != "bedrock"` sites. The gate itself predates that branch point and
is a defect independent of whether any version of #429 merges.
