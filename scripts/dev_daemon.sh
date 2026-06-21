#!/usr/bin/env bash
# Hot-reload dev loop for the waywallen daemon.
#
# Watches src/ for changes, rebuilds with dev-fast profile (no LTO),
# and replaces the running daemon via --replace. The UI stays alive
# and reconnects to the new daemon automatically via D-Bus.
#
# Prerequisites (install once inside your distrobox):
#   cargo install cargo-watch sccache
#   sudo dnf install mold        # Fedora/Bazzite
#   sudo apt-get install mold    # Debian/Ubuntu
#   sudo pacman -S mold          # Arch
#
# Usage:
#   ./scripts/dev_daemon.sh                  # watch + rebuild + replace
#   ./scripts/dev_daemon.sh --no-watch       # build once with dev-fast profile
#   ./scripts/dev_daemon.sh --no-ui          # don't launch UI on first start
#
# The UI must be available as ./build/AppDir/AppRun or a system install.
# Point it at the running daemon explicitly if needed:
#   WAYWALLEN_UI=/path/to/waywallen-ui ./scripts/dev_daemon.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$PROJECT_DIR"

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info()  { printf '\033[0;32m  → %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

NO_WATCH=false
NO_UI=false
for arg in "$@"; do
    case "$arg" in
        --no-watch) NO_WATCH=true ;;
        --no-ui)    NO_UI=true ;;
    esac
done

# ---- Accelerators --------------------------------------------------------
if command -v sccache &>/dev/null; then
    export RUSTC_WRAPPER=sccache
    info "sccache enabled"
fi
if command -v mold &>/dev/null; then
    info "mold linker available (via .cargo/config.toml)"
fi

# ---- Build command -------------------------------------------------------
BUILD_CMD=(cargo build --profile dev-fast --bin waywallen)
BINARY="$PROJECT_DIR/target/dev-fast/waywallen"

LAUNCH_ARGS=(--replace --no-restore)
if [[ "$NO_UI" == "false" ]]; then
    # Try AppDir first (from WAYWALLEN_DEV=1 build), then system path
    if [[ -n "${WAYWALLEN_UI:-}" ]]; then
        LAUNCH_ARGS+=(--ui "$WAYWALLEN_UI")
    elif [[ -x "$PROJECT_DIR/build/AppDir/usr/bin/waywallen-ui" ]]; then
        LAUNCH_ARGS+=(--ui "$PROJECT_DIR/build/AppDir/usr/bin/waywallen-ui")
    else
        warn "waywallen-ui not found; daemon will start headless"
        warn "Set WAYWALLEN_UI=/path/to/waywallen-ui or build with WAYWALLEN_DEV=1 first"
    fi
fi

if [[ -n "${WAYWALLEN_PLUGIN_DIR:-}" ]]; then
    LAUNCH_ARGS+=(--plugin "$WAYWALLEN_PLUGIN_DIR")
elif [[ -d "$PROJECT_DIR/build/AppDir/usr/share/waywallen" ]]; then
    LAUNCH_ARGS+=(--plugin "$PROJECT_DIR/build/AppDir/usr/share/waywallen")
fi

run_daemon() {
    info "launching daemon: $BINARY ${LAUNCH_ARGS[*]}"
    "$BINARY" "${LAUNCH_ARGS[@]}" &
    DAEMON_PID=$!
    info "daemon pid: $DAEMON_PID"
}

# ---- Single build mode ---------------------------------------------------
if [[ "$NO_WATCH" == "true" ]]; then
    step "Building waywallen (dev-fast profile)"
    "${BUILD_CMD[@]}"
    step "Starting daemon"
    run_daemon
    wait "$DAEMON_PID"
    exit 0
fi

# ---- Watch mode ----------------------------------------------------------
if ! command -v cargo-watch &>/dev/null; then
    warn "cargo-watch not found. Install it:"
    warn "  cargo install cargo-watch"
    warn ""
    warn "Falling back to single build + run (no hot reload)."
    step "Building waywallen (dev-fast profile)"
    "${BUILD_CMD[@]}"
    step "Starting daemon"
    run_daemon
    wait "$DAEMON_PID"
    exit 0
fi

step "Dev daemon loop (cargo-watch + --replace)"
info "Watching src/ proto/ protocol/ for changes…"
info "UI reconnects automatically after each rebuild."
info "Ctrl+C to stop."

# cargo-watch rebuilds on change, then runs the daemon with --replace.
# --replace kills the previous daemon instance before the new one starts.
# The UI picks up the new WS port via D-Bus automatically.
exec cargo watch \
    --watch src/ \
    --watch proto/ \
    --watch protocol/ \
    --watch build.rs \
    --shell "
        echo '' &&
        echo -e '\033[1;36m==> source changed — rebuilding...\033[0m' &&
        cargo build --profile dev-fast --bin waywallen &&
        echo -e '\033[1;36m==> restarting daemon (--replace)\033[0m' &&
        $BINARY ${LAUNCH_ARGS[*]} &
    "
