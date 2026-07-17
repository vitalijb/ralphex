#!/bin/sh
# init script for ralphex docker container
# baseimage runs /srv/init.sh if it exists before the main command

# seed_claude_plugins copies installed plugin state from $1 into $2 while skipping
# regenerable plugin-manager state (marketplace git clones, repos, catalog caches). the
# ephemeral container never runs /plugin install, so that state is dead weight, and copying
# the marketplaces' thousands of vendored files over a macos bind mount costs
# seconds-to-a-minute per run (see #376). cache is kept: it holds installed plugins' runtime
# code (installed_plugins.json installPaths point into it), so dropping it would break
# plugin skills/agents in the container.
seed_claude_plugins() {
    src="$1"
    dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    for entry in "$src"/*; do
        [ -e "$entry" ] || continue
        case "$(basename "$entry")" in
            marketplaces|repos|plugin-catalog-cache.json|known_marketplaces.json) continue ;;
        esac
        cp -rL "$entry" "$dest"/ 2>/dev/null || true
    done
}

# seed_claude_home copies essential claude files from $1 into $2 (not the entire 2GB directory).
# sets creds_bound=1 when .credentials.json is already rw bind-mounted at the destination, so the
# caller can skip the chown that would mutate the host file's metadata.
#
# the wrapper rw bind-mounts .credentials.json straight to the host so token refreshes persist.
# it updates through a separate channel from this image (--update-script fetches the wrapper from
# github, --update pulls the image), so an older wrapper emitting no bind mount is a supported
# combination — copy the file ourselves there or the container has no credentials at all.
seed_claude_home() {
    src="$1"
    dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    # probe before copying: docker establishes mounts before the entrypoint, so a bind-mounted
    # target already exists by now. the fallback copy below creates it too, so this cannot be
    # deferred until after the copy — both generations would then look identical.
    creds_bound=0
    [ -e "$dest/.credentials.json" ] && creds_bound=1
    # config files only (not cache, history, debug, todos, etc.)
    for f in settings.json settings.local.json CLAUDE.md format.sh; do
        [ -e "$src/$f" ] && cp -L "$src/$f" "$dest/$f" 2>/dev/null || true
    done
    if [ "$creds_bound" = 0 ] && [ -e "$src/.credentials.json" ]; then
        cp -L "$src/.credentials.json" "$dest/.credentials.json" 2>/dev/null || true
    fi
    # essential directories (symlinked in dotfiles setups)
    for d in commands skills hooks agents; do
        [ -d "$src/$d" ] && cp -rL "$src/$d" "$dest/" 2>/dev/null || true
    done
    seed_claude_plugins "$src/plugins" "$dest/plugins"
}

# seed_codex_home copies codex config from $1 into $2, skipping auth.json when it is already rw
# bind-mounted. sets auth_bound=1 in that case. same wrapper/image skew rationale as above.
seed_codex_home() {
    src="$1"
    dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    # probe before the loop, which copies auth.json itself in the no-bind-mount case
    auth_bound=0
    [ -e "$dest/auth.json" ] && auth_bound=1
    for entry in "$src"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        if [ "$name" = "auth.json" ] && [ "$auth_bound" = 1 ]; then
            continue
        fi
        cp -rL "$entry" "$dest/$name" 2>/dev/null || true
    done
}

# when sourced by the test harness (INIT_DOCKER_SOURCE_ONLY set) expose the functions only
[ -n "${INIT_DOCKER_SOURCE_ONLY:-}" ] && return 0

if [ -d /mnt/claude ]; then
    seed_claude_home /mnt/claude /home/app/.claude
    if [ "$creds_bound" = 1 ]; then
        # exclude .credentials.json: it is rw bind-mounted to the host, so chown would mutate
        # the host file's group metadata on Linux Docker hosts with real bind mounts.
        # -path anchors on the mount target so a nested file of the same name is still chowned.
        find /home/app/.claude ! -path /home/app/.claude/.credentials.json -exec chown app:app {} +
    else
        chown -R app:app /home/app/.claude
    fi
fi

# copy credentials extracted from macOS keychain (mounted separately)
if [ -f /mnt/claude-credentials.json ]; then
    mkdir -p /home/app/.claude
    cp /mnt/claude-credentials.json /home/app/.claude/.credentials.json
    chown -R app:app /home/app/.claude
    chmod 600 /home/app/.claude/.credentials.json
fi

# copy codex credentials if mounted
if [ -d /mnt/codex ]; then
    seed_codex_home /mnt/codex /home/app/.codex
    if [ "$auth_bound" = 1 ]; then
        # exclude auth.json: it is rw bind-mounted to the host, so chown would mutate
        # the host file's group metadata on Linux Docker hosts with real bind mounts.
        # -path anchors on the mount target so a nested file of the same name is still chowned.
        find /home/app/.codex ! -path /home/app/.codex/auth.json -exec chown app:app {} +
    else
        chown -R app:app /home/app/.codex
    fi
fi
