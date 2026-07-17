#!/bin/sh
# tests for seed_claude_plugins in init-docker.sh (see #376): keep installed plugin
# runtime code (cache) and small state, skip regenerable plugin-manager state.

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)

# source the script for its functions only; the guard stops it before the main body runs
# shellcheck source=scripts/internal/init-docker.sh
INIT_DOCKER_SOURCE_ONLY=1 . "$script_dir/init-docker.sh"

fail=0
assert() {  # $1 = description; rest = command expected to SUCCEED
    desc="$1"; shift
    if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}
assert_not() {  # $1 = description; rest = command expected to FAIL
    desc="$1"; shift
    if "$@"; then echo "FAIL - $desc"; fail=1; else echo "ok   - $desc"; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/init-docker-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

src="$work/src/plugins"
dest="$work/dest/plugins"
mkdir -p "$src/marketplaces/ralphex/vendor" "$src/cache/ralphex/ralphex/0.20.0" "$src/repos" "$src/data"
printf '{}' > "$src/config.json"
printf '{}' > "$src/installed_plugins.json"
printf '{}' > "$src/known_marketplaces.json"
printf '{}' > "$src/plugin-catalog-cache.json"
printf '{}' > "$src/blocklist.json"
printf 'runtime-code' > "$src/cache/ralphex/ralphex/0.20.0/skill.md"
printf 'vendored-go' > "$src/marketplaces/ralphex/vendor/big.go"

seed_claude_plugins "$src" "$dest"

# kept: installed plugin runtime code plus the small state files
assert     "keeps cache runtime code"        test -f "$dest/cache/ralphex/ralphex/0.20.0/skill.md"
assert     "keeps config.json"               test -f "$dest/config.json"
assert     "keeps installed_plugins.json"    test -f "$dest/installed_plugins.json"
assert     "keeps blocklist.json"            test -f "$dest/blocklist.json"
assert     "keeps data dir"                  test -d "$dest/data"
# dropped: regenerable plugin-manager state
assert_not "drops marketplaces clone"        test -e "$dest/marketplaces"
assert_not "drops repos"                     test -e "$dest/repos"
assert_not "drops plugin-catalog-cache.json" test -e "$dest/plugin-catalog-cache.json"
assert_not "drops known_marketplaces.json"   test -e "$dest/known_marketplaces.json"

# no-op when the source plugins dir is absent (no dest created)
seed_claude_plugins "$work/absent" "$work/dest2"
assert_not "no-op when source absent"        test -e "$work/dest2"

# credential seeding across both wrapper generations. the wrapper rw bind-mounts the credential
# file when it is new enough; an older wrapper (it updates separately from the image) does not, and
# the seeding must fall back to copying or the container ends up with no credentials at all.
# ownership is not asserted: this harness runs unprivileged, so chown app:app cannot succeed here.
assert_content() {  # $1 = description; $2 = file; $3 = expected content
    if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi
}

# old wrapper: no bind mount at the target, so the file must be copied in
csrc="$work/old/src"; cdest="$work/old/dest"
mkdir -p "$csrc"
printf 'host-creds' > "$csrc/.credentials.json"
printf '{}' > "$csrc/settings.json"
seed_claude_home "$csrc" "$cdest"
assert_content "old wrapper: .credentials.json copied in" "$cdest/.credentials.json" "host-creds"
assert_content "old wrapper: settings.json copied in"     "$cdest/settings.json" "{}"
assert     "old wrapper: creds_bound flag is 0"          test "$creds_bound" = 0

# new wrapper: the bind mount already put the file at the target; copying over it would be a
# same-file cp, and the caller must skip the chown
nsrc="$work/new/src"; ndest="$work/new/dest"
mkdir -p "$nsrc" "$ndest"
printf 'host-creds' > "$nsrc/.credentials.json"
printf 'bind-mounted' > "$ndest/.credentials.json"   # stands in for the wrapper's rw bind mount
seed_claude_home "$nsrc" "$ndest"
assert_content "new wrapper: bind-mounted creds not overwritten" "$ndest/.credentials.json" "bind-mounted"
assert     "new wrapper: creds_bound flag is 1"          test "$creds_bound" = 1

# same two generations for codex auth.json
xsrc="$work/codex-old/src"; xdest="$work/codex-old/dest"
mkdir -p "$xsrc"
printf 'host-auth' > "$xsrc/auth.json"
printf '{}' > "$xsrc/config.toml"
seed_codex_home "$xsrc" "$xdest"
assert_content "old wrapper: auth.json copied in"        "$xdest/auth.json" "host-auth"
assert_content "old wrapper: config.toml copied in"      "$xdest/config.toml" "{}"
assert     "old wrapper: auth_bound flag is 0"           test "$auth_bound" = 0

ysrc="$work/codex-new/src"; ydest="$work/codex-new/dest"
mkdir -p "$ysrc" "$ydest"
printf 'host-auth' > "$ysrc/auth.json"
printf 'bind-mounted' > "$ydest/auth.json"
printf '{}' > "$ysrc/config.toml"
seed_codex_home "$ysrc" "$ydest"
assert_content "new wrapper: bind-mounted auth not overwritten" "$ydest/auth.json" "bind-mounted"
assert_content "new wrapper: other codex files still copied"    "$ydest/config.toml" "{}"
assert     "new wrapper: auth_bound flag is 1"           test "$auth_bound" = 1

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILURES"; exit 1; fi
