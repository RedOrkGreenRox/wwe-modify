#!/usr/bin/env bash
# Convenience wrapper for building Lite / Full AppImages.
#
# Usage:
#   ./make_appimages.sh        # build both Lite and Full
#   ./make_appimages.sh lite   # no embedded browser
#   ./make_appimages.sh full   # embedded QtWebEngine Workshop
#   ./make_appimages.sh both

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

MODE="${1:-both}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

step "Making repository shell scripts executable"
find "$PROJECT_DIR" -type f -name '*.sh' -exec chmod +x {} +

build_lite() {
    step "Building Lite AppImage (external Steam/browser Workshop)"
    WAYWALLEN_APPIMAGE_WEBENGINE=OFF ./scripts/build_appimage.sh
}

build_full() {
    step "Building Full AppImage (embedded QtWebEngine Workshop)"
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
