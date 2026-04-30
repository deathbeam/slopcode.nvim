#!/bin/bash
# Generic restrictive bubblewrap sandbox
# Usage: sandbox [command...]
#   Runs command (or $SHELL) in an isolated environment.
#   Current working directory and some common config/state directories are writable,
#   but the rest of the filesystem is read-only.
#   Mo IPC, no new privileges, isolated namespaces.

set -euo pipefail

# Resolve current directory once
HERE="$(realpath .)"

# Build common read-only filesystem bindings
# Using --ro-bind for the entire system, then overlaying specific paths as needed
bwrap_args=(
    # --- Filesystem: read-only root with selective overlays ---
    --ro-bind / /

    # Writable current working directory (the main "working area")
    --bind "$HERE" "$HERE"

    # Allow common stuff
    --bind "$HOME/.local/state/nvim" "$HOME/.local/state/nvim" # needed for neovim
    --bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" # needed for neovim
    --bind /tmp /tmp # without this fzf-lua kinda doesnt rly work

    # /tmp as tmpfs (writable but ephemeral), use if not using fzf-lua or other stuff isnt breaking
    # --tmpfs /tmp

    # --- Pseudo-filesystems ---
    --proc /proc
    --dev /dev

    # --- Namespace isolation ---
    --unshare-all
    --share-net
    --hostname sandbox     # Isolate UTS namespace hostname

    # --- Security hardening ---
    --new-session          # Mitigate TIOCSTI sandbox escape (CVE-2017-5226), can sometimes break in tmux, its fine
    --die-with-parent      # Kill sandboxed process when parent dies

    # --- Environment ---
    --setenv PS1 "sandbox$ "
    --unsetenv XAUTHORITY  # Don't leak X11 auth by default
)

# Execute
exec bwrap "${bwrap_args[@]}" "${@:-sh}"
