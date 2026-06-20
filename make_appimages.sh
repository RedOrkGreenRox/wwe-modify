#!/usr/bin/env bash
# One-command AppImage release builder.
#
# Usage:
#   ./make_appimages.sh        # build both Lite and Full AppImages
#   ./make_appimages.sh lite   # build only the small AppImage without embedded Workshop browser
#   ./make_appimages.sh full   # build only the larger AppImage with embedded QtWebEngine Workshop
#   ./make_appimages.sh both   # same as no arguments

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

MODE="${1:-both}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

build_lite() {
    step "Building Lite AppImage (small, no embedded web browser)"
    WAYWALLEN_APPIMAGE_WEBENGINE=OFF ./scripts/build_appimage.sh
}

build_full() {
    step "Building Full AppImage (embedded Steam Workshop browser / QtWebEngine)"
    WAYWALLEN_APPIMAGE_WEBENGINE=ON ./scripts/build_appimage.sh
}

case "$MODE" in
    lite|Lite|LITE)
        build_lite
        ;;
    full|Full|FULL|web|Web|WEB)
        build_full
        ;;
    both|Both|BOTH|all|All|ALL)
        build_lite
        build_full
        ;;
    *)
        fail "unknown mode '$MODE'. Use: ./make_appimages.sh [lite|full|both]"
        ;;
esac

step "Done. Generated AppImages:"
find "$PROJECT_DIR" -maxdepth 1 -type f -name 'waywallen-*-x86_64.AppImage' -printf '  %f  %k KiB\n' | sort || true
