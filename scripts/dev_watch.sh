#!/usr/bin/env bash
# Universal hot-reload watcher for waywallen development.
#
# Watches source files and automatically rebuilds + restarts the right
# component depending on what changed:
#
#   src/ proto/ protocol/ build.rs  → rebuild Rust daemon, restart via --replace
#   ui/qml/                         → restart UI only (no rebuild needed)
#   ui/src/                         → rebuild C++ UI, restart UI
#
# Prerequisites (one-time, inside distrobox):
#   cargo install sccache cargo-watch
#   sudo dnf install mold inotify-tools   # Fedora/Bazzite
#   sudo apt-get install mold inotify-tools  # Debian/Ubuntu
#   sudo zypper install mold inotify-tools   # openSUSE
#   sudo pacman -S mold inotify-tools        # Arch
#
# Usage:
#   ./scripts/dev_watch.sh              # watch everything
#   ./scripts/dev_watch.sh --rust-only  # watch only Rust daemon
#   ./scripts/dev_watch.sh --ui-only    # watch only QML/C++ UI
#
# Expects a prior WAYWALLEN_DEV=1 build:
#   WAYWALLEN_DEV=1 ./make_appimages.sh lite

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$PROJECT_DIR"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '\033[0;32m  → %s\033[0m\n'  "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n'  "$*"; }
ok()   { printf '\033[0;32m  ✓ %s\033[0m\n'  "$*"; }
err()  { printf '\033[1;31m  ✗ %s\033[0m\n'  "$*"; }

# ---- Args ----------------------------------------------------------------
RUST_ONLY=false
UI_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --rust-only) RUST_ONLY=true ;;
        --ui-only)   UI_ONLY=true ;;
    esac
done

# ---- Accelerators --------------------------------------------------------
if command -v sccache &>/dev/null; then
    export RUSTC_WRAPPER=sccache
    info "sccache enabled"
fi

# ---- Paths ---------------------------------------------------------------
DAEMON_BIN="$PROJECT_DIR/target/dev-fast/waywallen"
APPDIR="$PROJECT_DIR/build/AppDir"
UI_BIN="${WAYWALLEN_UI:-$APPDIR/usr/bin/waywallen-ui}"
PLUGIN_DIR="${WAYWALLEN_PLUGIN_DIR:-$APPDIR/usr/share/waywallen}"
# Build directory depends on the cmake preset used.
# WAYWALLEN_DEV=1 uses clang-dev; otherwise clang-release.
CMAKE_PRESET="${CMAKE_PRESET:-clang-release}"
BUILD_DIR="$PROJECT_DIR/build/$CMAKE_PRESET"

# Build DAEMON_ARGS as a plain string (safe for subshells and cargo watch --shell)
DAEMON_ARGS="--replace --no-restore"
[[ -x "$UI_BIN" ]]     && DAEMON_ARGS="$DAEMON_ARGS --ui '$UI_BIN'"
[[ -d "$PLUGIN_DIR" ]] && DAEMON_ARGS="$DAEMON_ARGS --plugin '$PLUGIN_DIR'"

if ! [[ -d "$APPDIR" ]]; then
    warn "build/AppDir not found — run a full build first:"
    warn "  WAYWALLEN_DEV=1 ./make_appimages.sh lite"
    exit 1
fi

# ---- Helpers -------------------------------------------------------------

build_daemon() {
    cargo build --profile dev-fast --bin waywallen
}

start_daemon() {
    # Use eval so quoted paths in DAEMON_ARGS expand correctly
    eval "'$DAEMON_BIN' $DAEMON_ARGS" &
    ok "daemon started (pid $!)"
}

restart_daemon() {
    step "Rust change — rebuilding daemon (dev-fast)…"
    if build_daemon; then
        ok "daemon built"
        step "Restarting daemon (--replace)…"
        start_daemon
    else
        err "daemon build failed — old instance still running"
    fi
}

restart_ui() {
    # Kill by exact binary name to avoid killing unrelated processes
    pkill -x waywallen-ui 2>/dev/null || pkill -f "$UI_BIN" 2>/dev/null || true
    sleep 0.3
    if [[ -x "$UI_BIN" ]]; then
        "$UI_BIN" &
        ok "UI restarted (pid $!)"
    else
        warn "waywallen-ui not found at: $UI_BIN"
        warn "Set WAYWALLEN_UI=/path/to/waywallen-ui to override"
    fi
}

# QML_MODULES_DIR: where cmake copies QML files in WAYWALLEN_QML_FILESYSTEM=ON builds.
# When this directory exists, QML changes are applied by copying the file there —
# no UI restart needed. The running UI reloads the QML on next component creation
# (navigation away and back, or a daemon reconnect).
QML_MODULES_DIR="$BUILD_DIR/qml_modules/waywallen/ui"

hot_copy_qml() {
    local changed_file="$1"
    local rel="${changed_file#$PROJECT_DIR/ui/qml/}"
    local dest="$QML_MODULES_DIR/$rel"
    if [[ -d "$QML_MODULES_DIR" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp "$changed_file" "$dest"
        ok "QML hot-copied: $rel → qml_modules/"
        info "Switch tabs and back in the UI to reload without restart"
    else
        # Fallback: embedded QML (STATIC build) — must restart UI
        info "qml_modules/ not found (embedded build) — restarting UI"
        restart_ui
    fi
}

rebuild_ui() {
    step "C++ UI change — rebuilding…"
    if cmake --build "$BUILD_DIR" --parallel 2>&1; then
        ok "UI built"
        # Install just the UI binary into AppDir
        cmake --install "$BUILD_DIR" 2>&1 | grep -E "waywallen-ui|Installing" || true
        step "Restarting UI…"
        restart_ui
    else
        err "UI build failed"
    fi
}

# ---- inotifywait wrapper -------------------------------------------------
# inotifywait --include uses ERE; older versions may not support alternation
# groups like (cpp|cppm). We use a simpler per-extension approach instead:
# watch the whole directory and filter in bash.

watch_dir_for_ext() {
    # $1 = directory, $2+ = extensions (without dot)
    local dir="$1"; shift
    local exts=("$@")
    if ! command -v inotifywait &>/dev/null; then
        return 1
    fi
    # inotifywait outputs: DIR EVENT FILENAME — filter by extension in a loop
    inotifywait -r -q -m -e close_write,moved_to,create "$dir" \
        --format '%w%f' 2>/dev/null | while IFS= read -r file; do
        local ext="${file##*.}"
        local match=false
        for e in "${exts[@]}"; do
            [[ "$ext" == "$e" ]] && match=true && break
        done
        $match && printf '%s\n' "$file"
    done
}

# ---- Watcher functions ---------------------------------------------------

watch_rust() {
    if ! command -v cargo-watch &>/dev/null; then
        warn "cargo-watch not found — Rust hot-reload disabled"
        warn "  cargo install cargo-watch"
        return
    fi
    info "Watching src/ proto/ protocol/ build.rs for Rust changes…"

    # cargo watch --shell receives a plain sh string — use a helper script
    # rather than embedding complex logic with quotes inside --shell "..."
    local restart_script
    restart_script="$(mktemp /tmp/ww-restart-daemon.XXXXXX.sh)"
    cat > "$restart_script" << SHEOF
#!/bin/sh
set -e
printf '\n\033[1;36m==> Rust change — rebuilding daemon...\033[0m\n'
cd '$PROJECT_DIR'
cargo build --profile dev-fast --bin waywallen
printf '\033[0;32m  ✓ built\033[0m\n'
printf '\033[1;36m==> Restarting daemon (--replace)...\033[0m\n'
eval "'$DAEMON_BIN' $DAEMON_ARGS" &
printf '\033[0;32m  ✓ daemon restarted\033[0m\n'
SHEOF
    chmod +x "$restart_script"
    # Remove temp file when this subshell exits
    trap "rm -f '$restart_script'" EXIT INT TERM

    cargo watch \
        --watch src/ \
        --watch proto/ \
        --watch protocol/ \
        --watch build.rs \
        --shell "sh '$restart_script'" &
}

watch_qml() {
    if ! command -v inotifywait &>/dev/null; then
        warn "inotifywait not found — QML hot-reload disabled"
        warn "  sudo dnf install inotify-tools      # Fedora/Bazzite"
        warn "  sudo apt-get install inotify-tools  # Debian/Ubuntu"
        warn "  sudo pacman -S inotify-tools        # Arch"
        return
    fi
    info "Watching ui/qml/ for QML changes (UI restart, no rebuild)…"
    (
        watch_dir_for_ext "$PROJECT_DIR/ui/qml/" qml | while IFS= read -r file; do
            info "QML changed: ${file#$PROJECT_DIR/}"
            hot_copy_qml "$file"
            # Debounce: drain any rapid successive changes
            sleep 0.5
            while IFS= read -r -t 0.3 _; do :; done
        done
    ) &
}

watch_ui_cpp() {
    if ! command -v inotifywait &>/dev/null; then
        return
    fi
    if ! [[ -d "$BUILD_DIR" ]]; then
        warn "build/clang-release not found — C++ UI hot-reload disabled"
        warn "Run a full build first to enable incremental C++ rebuilds"
        return
    fi
    info "Watching ui/src/ for C++ changes (rebuild + UI restart)…"
    (
        watch_dir_for_ext "$PROJECT_DIR/ui/src/" cpp cppm h hpp | \
        while IFS= read -r file; do
            info "C++ changed: ${file#$PROJECT_DIR/}"
            rebuild_ui
            # Debounce
            sleep 2
            while IFS= read -r -t 1 _; do :; done
        done
    ) &
}

# ---- Initial daemon start ------------------------------------------------

step "Starting daemon"
if ! [[ -x "$DAEMON_BIN" ]]; then
    warn "daemon binary not found: $DAEMON_BIN"
    warn "Building now with dev-fast profile…"
    build_daemon
fi
start_daemon

# ---- Start watchers ------------------------------------------------------

if [[ "$RUST_ONLY" == true ]]; then
    watch_rust
elif [[ "$UI_ONLY" == true ]]; then
    watch_qml
    watch_ui_cpp
else
    watch_rust
    watch_qml
    watch_ui_cpp
fi

step "Watchers running. Press Ctrl+C to stop."
printf '\n'
info "Rust src/     → daemon rebuild + --replace (~5-15s)"
info "ui/qml/       → hot-copy to qml_modules/ (instant, switch tab to reload)"
info "               (falls back to UI restart for embedded/STATIC builds)"
info "ui/src/ C++   → cmake rebuild + UI restart"
printf '\n'

# ---- Wait and clean up ---------------------------------------------------
trap '
    printf "\n"
    step "Stopping watchers…"
    # Kill all background jobs spawned by this script
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
    exit 0
' INT TERM

wait
