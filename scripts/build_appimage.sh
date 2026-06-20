#!/usr/bin/env bash
# Build waywallen end-to-end and produce a single-file AppImage at:
#     <repo>/waywallen-<version>-lite-x86_64.AppImage
# or:
#     <repo>/waywallen-<version>-full-x86_64.AppImage
#
# Audience: users unfamiliar with cmake / cargo / linuxdeploy.
# Prerequisites:
#   - git, curl, tar, and a few host development packages.
#   - If conda is missing, this script downloads portable micromamba into build/_tools.
#   - If cargo is missing, this script installs Rust with rustup.
# Usage (works from anywhere inside the repo):
#   ./scripts/build_appimage.sh   first run takes ~15–30 min (creates conda env, builds qtgrpc, packs AppImage)
#   WAYWALLEN_APPIMAGE_WEBENGINE=ON ./scripts/build_appimage.sh   builds the larger embedded-Workshop edition
#   ./scripts/build_appimage.sh   re-running performs an incremental rebuild + repack
#
# Optional environment variables:
#   WAYWALLEN_CONDA_ENV     conda env name, default "waywallen"
#   WAYWALLEN_APPIMAGE_WEBENGINE  ON for full WebEngine build, OFF for lite build, default OFF
#   OWE_PLUGIN_ZIP          prebuilt OWE plugin zip path or URL
#   WAYWALLEN_DISPLAY_REPO  layer-shell source repo URL
#   WAYWALLEN_DISPLAY_REF   layer-shell source git ref
#   WAYWALLEN_DISPLAY_SRC   layer-shell source cache dir

set -euo pipefail

# Bazzite/Fedora libraries may contain ELF RELR sections (.relr.dyn).
# The strip binary bundled in linuxdeploy is often too old and fails with:
#   unknown type [0x13] section `.relr.dyn'
# Disabling stripping makes AppImage packaging reliable. The AppImage will be
# a bit larger, but it will build.
export NO_STRIP="${NO_STRIP:-true}"

# Script lives in <repo>/scripts/, so PROJECT_DIR is one level up.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${WAYWALLEN_CONDA_ENV:-waywallen}"
TMP_DIR="${TMPDIR:-/tmp}"
OWE_PLUGIN_VER="0.1.7"
OWE_PLUGIN_ZIP="https://github.com/waywallen/open-wallpaper-engine/releases/download/v${OWE_PLUGIN_VER}/org.waywallen.open-wallpaper-engine-${OWE_PLUGIN_VER}-linux-x86_64.zip"
OWE_PLUGIN_ID="org.waywallen.open-wallpaper-engine"
WAYWALLEN_DISPLAY_REPO="${WAYWALLEN_DISPLAY_REPO:-https://github.com/waywallen/waywallen-display.git}"
WAYWALLEN_DISPLAY_REF="${WAYWALLEN_DISPLAY_REF:-6dc8e9ad6cb17452e7affe9390238cfb3e995a9f}"
APPDIR="$PROJECT_DIR/build/AppDir"
INSTALL_DIR="$APPDIR/usr"          # AppDir's /usr is the cmake install prefix
PLUGINS_DIR="$INSTALL_DIR/share/waywallen/plugins"
OWE_PLUGIN_DIR="$PLUGINS_DIR/$OWE_PLUGIN_ID"
TOOLS_DIR="$PROJECT_DIR/build/_tools"
WAYWALLEN_DISPLAY_SRC="${WAYWALLEN_DISPLAY_SRC:-$TMP_DIR/waywallen-display-src}"
WAYWALLEN_APPIMAGE_WEBENGINE="${WAYWALLEN_APPIMAGE_WEBENGINE:-OFF}"
case "${WAYWALLEN_APPIMAGE_WEBENGINE,,}" in
    1|on|true|yes|full|web|webengine)
        WAYWALLEN_APPIMAGE_WEBENGINE=ON
        WAYWALLEN_APPIMAGE_FLAVOR=full
        ;;
    0|off|false|no|lite|minimal)
        WAYWALLEN_APPIMAGE_WEBENGINE=OFF
        WAYWALLEN_APPIMAGE_FLAVOR=lite
        ;;
    *)
        printf '\033[1;31mERROR:\033[0m invalid WAYWALLEN_APPIMAGE_WEBENGINE=%s (use ON or OFF)\n' "$WAYWALLEN_APPIMAGE_WEBENGINE" >&2
        exit 1
        ;;
esac

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
append_unique_path() {
    local -n paths_ref="$1"
    local path="$2"
    local existing
    for existing in "${paths_ref[@]}"; do
        [[ "$existing" == "$path" ]] && return
    done
    paths_ref+=("$path")
}
find_first_file() {
    local file="$1"
    shift
    local dir candidate
    for dir in "$@"; do
        [[ -n "$dir" && -e "$dir" ]] || continue
        candidate="$(find "$dir" -type f -name "$file" -print -quit 2>/dev/null || true)"
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}


need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif need_cmd sudo; then
        sudo "$@"
    else
        return 1
    fi
}

bootstrap_micromamba() {
    MICROMAMBA="$TOOLS_DIR/micromamba"
    if [[ ! -x "$MICROMAMBA" ]]; then
        step "conda not found; downloading portable micromamba into build/_tools"
        need_cmd curl || fail "curl not found; install curl first, then re-run"
        need_cmd tar  || fail "tar not found; install tar first, then re-run"
        mkdir -p "$TOOLS_DIR"
        local archive="$TOOLS_DIR/micromamba-linux-64.tar.bz2"
        local extract_dir="$TOOLS_DIR/micromamba-extract"
        curl -fsSL --retry 3 -o "$archive.tmp" \
            "https://micro.mamba.pm/api/micromamba/linux-64/latest"
        mv "$archive.tmp" "$archive"
        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"
        tar -xjf "$archive" -C "$extract_dir" bin/micromamba
        install -Dm755 "$extract_dir/bin/micromamba" "$MICROMAMBA"
        rm -rf "$extract_dir"
    fi

    export MAMBA_ROOT_PREFIX="$PROJECT_DIR/build/_micromamba-root"
    eval "$("$MICROMAMBA" shell hook -s bash)"
}

ensure_rust() {
    if need_cmd cargo; then
        return 0
    fi
    step "cargo not found; installing Rust toolchain with rustup"
    need_cmd curl || fail "curl not found; install curl first, then re-run"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable
    source "$HOME/.cargo/env"
    need_cmd cargo || fail "cargo still not found after rustup installation"
}

ensure_host_build_deps() {
    local missing=()
    if [[ ! -x /usr/bin/pkg-config ]]; then
        missing+=(pkg-config)
    else
        env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR /usr/bin/pkg-config --exists libpipewire-0.3 || missing+=(libpipewire-0.3)
        env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR /usr/bin/pkg-config --exists libspa-0.2      || missing+=(libspa-0.2)
        env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR /usr/bin/pkg-config --exists fontconfig      || missing+=(fontconfig)
        env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR /usr/bin/pkg-config --exists 'libpulse >= 14.0' || missing+=(libpulse)
    fi

    [[ "${#missing[@]}" -eq 0 ]] && return 0

    step "Missing host development packages: ${missing[*]}"
    if need_cmd dnf; then
        step "Trying to install host build dependencies with dnf"
        if run_as_root dnf install -y \
            git curl tar pkgconf-pkg-config pipewire-devel fontconfig-devel pulseaudio-libs-devel libarchive; then
            return 0
        fi
    fi

    cat >&2 <<'EOF'

Could not auto-install required host development packages.
On Bazzite/immutable systems, the recommended way is to build inside a Fedora distrobox/toolbox:

  distrobox create -n waywallen-dev -i fedora:latest
  distrobox enter waywallen-dev
  sudo dnf install -y git curl tar pkgconf-pkg-config pipewire-devel fontconfig-devel pulseaudio-libs-devel libarchive

Then run this script again from the repository:

  ./make_appimages.sh lite
  ./make_appimages.sh full

EOF
    fail "missing host development packages: ${missing[*]}"
}

conda_env_exists() {
    if [[ "$CONDA_FRONTEND" == "conda" ]]; then
        conda env list | awk 'NF && $1 !~ /^#/ {print $1}' | grep -qx "$ENV_NAME"
    else
        micromamba env list | awk 'NF && $1 !~ /^#/ {print $1}' | grep -qx "$ENV_NAME"
    fi
}

install_conda_package() {
    local pkg="$1"
    if [[ "$CONDA_FRONTEND" == "conda" ]]; then
        conda install -n "$ENV_NAME" -c conda-forge -y "$pkg"
    else
        micromamba install -n "$ENV_NAME" -c conda-forge -y "$pkg"
    fi
}

ensure_webengine_package_if_needed() {
    [[ "$WAYWALLEN_APPIMAGE_WEBENGINE" == "ON" ]] || return 0
    if [[ -f "$CONDA_PREFIX/lib/cmake/Qt6WebEngineQuick/Qt6WebEngineQuickConfig.cmake" ]] \
        || find "$CONDA_PREFIX" -path '*/Qt6WebEngineQuickConfig.cmake' -print -quit | grep -q .; then
        return 0
    fi

    step "QtWebEngineQuick not found in the build environment; trying to install it"
    local pkg
    for pkg in qt6-webengine qtwebengine qt-webengine; do
        if install_conda_package "$pkg"; then
            break
        fi
    done

    if [[ ! -f "$CONDA_PREFIX/lib/cmake/Qt6WebEngineQuick/Qt6WebEngineQuickConfig.cmake" ]] \
        && ! find "$CONDA_PREFIX" -path '*/Qt6WebEngineQuickConfig.cmake' -print -quit | grep -q .; then
        fail "Qt6WebEngineQuickConfig.cmake was not found after trying known conda-forge package names. Build the lite AppImage or install a Qt6 WebEngine package manually."
    fi
}

# ---- Compute the version string baked into the AppImage filename ----
# Pull the canonical version from Cargo.toml; refine with git metadata so
# successive dev builds at the same version don't all overwrite each other.
# Override the entire tag with WAYWALLEN_BUILD_VERSION=foo for one-off names.
WAYWALLEN_VERSION="$(awk -F'"' '/^version *= *"/ { print $2; exit }' "$PROJECT_DIR/Cargo.toml")"
[[ -n "$WAYWALLEN_VERSION" ]] || fail "could not parse version from Cargo.toml"

if [[ -n "${WAYWALLEN_BUILD_VERSION:-}" ]]; then
    BUILD_TAG="$WAYWALLEN_BUILD_VERSION"
elif git -C "$PROJECT_DIR" rev-parse --short=7 HEAD >/dev/null 2>&1; then
    SHA="$(git -C "$PROJECT_DIR" rev-parse --short=7 HEAD)"
    DIRTY=""
    git -C "$PROJECT_DIR" diff --quiet --ignore-submodules HEAD 2>/dev/null || DIRTY="-dirty"
    if [[ -z "$DIRTY" ]] \
        && git -C "$PROJECT_DIR" describe --tags --exact-match --match "v$WAYWALLEN_VERSION" \
                >/dev/null 2>&1; then
        BUILD_TAG="$WAYWALLEN_VERSION"
    else
        BUILD_TAG="$WAYWALLEN_VERSION-g$SHA$DIRTY"
    fi
else
    BUILD_TAG="$WAYWALLEN_VERSION"
fi

# Clean APPDIR
rm -rf "$APPDIR"

APPIMAGE_OUT="$PROJECT_DIR/waywallen-$BUILD_TAG-$WAYWALLEN_APPIMAGE_FLAVOR-x86_64.AppImage"
step "Building $WAYWALLEN_APPIMAGE_FLAVOR AppImage tagged as $BUILD_TAG (WebEngine=$WAYWALLEN_APPIMAGE_WEBENGINE)"

# ---- Check/bootstrap required tools ----
need_cmd curl || fail "curl not found; install curl first, then re-run"
need_cmd git  || fail "git not found; install git first, then re-run"
ensure_rust
ensure_host_build_deps

# ---- Set up the conda-compatible environment ----
ENV_FILE="$PROJECT_DIR/environment.yml"
[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE"

if need_cmd conda; then
    CONDA_FRONTEND=conda
    set +u
    source "$(conda info --base)/etc/profile.d/conda.sh"
    set -u
else
    CONDA_FRONTEND=micromamba
    bootstrap_micromamba
fi

if conda_env_exists; then
    step "Updating build env: $ENV_NAME (sync to environment.yml)"
    if [[ "$CONDA_FRONTEND" == "conda" ]]; then
        conda env update -n "$ENV_NAME" -f "$ENV_FILE" --prune
    else
        micromamba env update -n "$ENV_NAME" -f "$ENV_FILE" -y
    fi
else
    step "Creating build env: $ENV_NAME (install per environment.yml)"
    if [[ "$CONDA_FRONTEND" == "conda" ]]; then
        conda env create -n "$ENV_NAME" -f "$ENV_FILE"
    else
        micromamba env create -n "$ENV_NAME" -f "$ENV_FILE" -y
    fi
fi

step "Activating env: $ENV_NAME"
set +u
if [[ "$CONDA_FRONTEND" == "conda" ]]; then
    conda activate "$ENV_NAME"
else
    micromamba activate "$ENV_NAME"
fi
set -u
ensure_webengine_package_if_needed

# ---- Build a minimal FFmpeg into the conda env (replaces conda-forge's ffmpeg) ----
bash "$PROJECT_DIR/scripts/build_ffmpeg.sh"

# ---- Copy host syslibs (pipewire, fontconfig) into the conda env ----
bash "$PROJECT_DIR/scripts/copy_syslibs.sh"

QT_VER="$("$CONDA_PREFIX/bin/qmake6" -query QT_VERSION)"
if [[ ! -f "$CONDA_PREFIX/lib/cmake/Qt6Protobuf/Qt6ProtobufConfig.cmake" ]]; then
    step "Building qtgrpc v$QT_VER from source (one-shot; installs into $CONDA_PREFIX)"
    QTGRPC_SRC="$PROJECT_DIR/build/_qtgrpc-src"
    QTGRPC_BUILD="$PROJECT_DIR/build/_qtgrpc-build"
    rm -rf "$QTGRPC_SRC" "$QTGRPC_BUILD"
    git clone --depth 1 --branch "v$QT_VER" \
        https://code.qt.io/qt/qtgrpc.git "$QTGRPC_SRC"
    cmake -S "$QTGRPC_SRC" -B "$QTGRPC_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_SYSROOT="$CONDA_BUILD_SYSROOT" \
        -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
        -DCMAKE_INSTALL_PREFIX="$CONDA_PREFIX" \
        -DQT_FEATURE_grpc=OFF \
        -DBUILD_TESTING=OFF \
        -DQT_BUILD_EXAMPLES=OFF \
        -DQT_BUILD_TESTS=OFF
    cmake --build   "$QTGRPC_BUILD" --parallel
    cmake --install "$QTGRPC_BUILD"
fi

step "CMake configure (daemon + UI + image/video renderer plugins)"
pushd "$PROJECT_DIR"
cmake -S "$PROJECT_DIR" --preset clang-release \
    -DCMAKE_SYSROOT="$CONDA_BUILD_SYSROOT" \
    `# Under sysroot 2.28 pthread lives in libpthread, not libc — pthread must
     # be enabled globally, otherwise C++20 PCMs produced by rstd / qextra etc.
     # disagree on pthread state and clang reports module-file-config-mismatch
     # when one imports the other.` \
    -DCMAKE_C_FLAGS_INIT="-pthread" \
    -DCMAKE_CXX_FLAGS_INIT="-pthread" \
    -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="ON" \
    -DCMAKE_CXX_COMPILER_AR="llvm-ar" \
    -DQML_MATERIAL_BUILD_TYPE="STATIC" \
    -DWAYWALLEN_BUILD_DAEMON=ON \
    -DWAYWALLEN_BUILD_UI=ON \
    -DWAYWALLEN_BUILD_PLUGINS=ON \
    -DWAYWALLEN_BUILD_IMAGE_PLUGIN=ON \
    -DWAYWALLEN_BUILD_VIDEO_PLUGIN=ON \
    -DWAYWALLEN_ENABLE_WEBENGINE="$WAYWALLEN_APPIMAGE_WEBENGINE" \
    -DWAYWALLEN_REQUIRE_WEBENGINE="$WAYWALLEN_APPIMAGE_WEBENGINE"

step "Compiling)"
cmake --build build/clang-release --parallel

step "Installing into AppDir: $APPDIR"
cmake --install build/clang-release

step "Building and installing waywallen-layer-shell"
if [[ -d "$WAYWALLEN_DISPLAY_SRC/.git" ]]; then
    git -C "$WAYWALLEN_DISPLAY_SRC" remote set-url origin "$WAYWALLEN_DISPLAY_REPO"
else
    rm -rf "$WAYWALLEN_DISPLAY_SRC"
    git clone "$WAYWALLEN_DISPLAY_REPO" "$WAYWALLEN_DISPLAY_SRC"
fi
git -C "$WAYWALLEN_DISPLAY_SRC" fetch --tags origin "$WAYWALLEN_DISPLAY_REF" \
    || git -C "$WAYWALLEN_DISPLAY_SRC" fetch --tags origin
git -C "$WAYWALLEN_DISPLAY_SRC" checkout --detach "$WAYWALLEN_DISPLAY_REF"
cargo build \
    --manifest-path "$WAYWALLEN_DISPLAY_SRC/Cargo.toml" \
    --bin waywallen-layer-shell \
    --release \
    --locked
install -Dm755 \
    "$WAYWALLEN_DISPLAY_SRC/target/release/waywallen-layer-shell" \
    "$INSTALL_DIR/bin/waywallen-layer-shell"

popd

# ---- Install open-wallpaper-engine prebuilt plugin into AppDir ----
OWE_PLUGIN_ZIP_PATH="$OWE_PLUGIN_ZIP"
if [[ "$OWE_PLUGIN_ZIP" == http://* || "$OWE_PLUGIN_ZIP" == https://* ]]; then
    mkdir -p "$TOOLS_DIR"
    OWE_PLUGIN_ZIP_PATH="$TOOLS_DIR/${OWE_PLUGIN_ZIP##*/}"
    if [[ ! -f "$OWE_PLUGIN_ZIP_PATH" ]]; then
        step "Downloading open-wallpaper-engine plugin"
        curl -fsSL --retry 3 -o "$OWE_PLUGIN_ZIP_PATH.tmp" "$OWE_PLUGIN_ZIP"
        mv "$OWE_PLUGIN_ZIP_PATH.tmp" "$OWE_PLUGIN_ZIP_PATH"
    fi
fi
step "Installing open-wallpaper-engine plugin from $OWE_PLUGIN_ZIP_PATH"
[[ -f "$OWE_PLUGIN_ZIP_PATH" ]] || fail "missing OWE plugin zip: $OWE_PLUGIN_ZIP_PATH"
rm -rf "$OWE_PLUGIN_DIR"
mkdir -p "$OWE_PLUGIN_DIR"
bsdtar -xf "$OWE_PLUGIN_ZIP_PATH" -C "$OWE_PLUGIN_DIR"
[[ -f "$OWE_PLUGIN_DIR/plugin.toml" ]] \
    || fail "OWE plugin zip did not contain plugin.toml at top level"
OWE_RENDERER_BINS=()
OWE_RENDERER_DIRS=()
while IFS= read -r renderer_bin; do
    [[ -n "$renderer_bin" ]] || continue
    renderer_path="$OWE_PLUGIN_DIR/$renderer_bin"
    [[ -f "$renderer_path" ]] \
        || fail "OWE plugin renderer bin missing: $renderer_bin"
    [[ -x "$renderer_path" ]] || chmod +x "$renderer_path"
    # Do not hand the bundled CEF web renderer to linuxdeploy.  Its GTK/ATK
    # dependency chain is intentionally not part of the minimal build container
    # and linuxdeploy aborts on missing host libs (libatk-1.0.so.0, etc.).
    # The OWE zip already ships the CEF payload next to this binary; AppRun adds
    # bin/weweb to LD_LIBRARY_PATH.  The important fix for wallpaper_engine
    # discovery is the explicit --plugin path below, not linuxdeploying weweb.
    [[ "$renderer_bin" == bin/weweb/* ]] && continue
    OWE_RENDERER_BINS+=("$renderer_path")
    append_unique_path OWE_RENDERER_DIRS "$(dirname "$renderer_path")"
done < <(awk -F'"' '/^[[:space:]]*bin[[:space:]]*=/ { print $2 }' "$OWE_PLUGIN_DIR/plugin.toml")
[[ "${#OWE_RENDERER_BINS[@]}" -gt 0 ]] \
    || fail "OWE plugin manifest did not declare renderer bins"
if compgen -G "$OWE_PLUGIN_DIR/bin/weweb/*.so" >/dev/null; then
    strip "$OWE_PLUGIN_DIR/bin/weweb"/*.so || true
fi

if [[ "$WAYWALLEN_APPIMAGE_WEBENGINE" == "ON" ]]; then
# ---- Bundle QtWebEngine for the embedded Steam Workshop page ----
step "Bundling QtWebEngine runtime"
QT_INSTALL_LIBEXECS="$("$CONDA_PREFIX/bin/qmake6" -query QT_INSTALL_LIBEXECS 2>/dev/null || true)"
QT_INSTALL_DATA="$("$CONDA_PREFIX/bin/qmake6" -query QT_INSTALL_DATA 2>/dev/null || true)"
QT_INSTALL_TRANSLATIONS="$("$CONDA_PREFIX/bin/qmake6" -query QT_INSTALL_TRANSLATIONS 2>/dev/null || true)"
QT_INSTALL_QML="$("$CONDA_PREFIX/bin/qmake6" -query QT_INSTALL_QML 2>/dev/null || true)"

WEBENGINE_PROCESS="$(find_first_file QtWebEngineProcess \
    "$QT_INSTALL_LIBEXECS" \
    "$CONDA_PREFIX/libexec" \
    "$CONDA_PREFIX/lib/qt6/libexec" \
    "$CONDA_PREFIX" || true)"
[[ -n "$WEBENGINE_PROCESS" ]] || fail "QtWebEngineProcess not found. Install the Qt6 WebEngine package in the conda env."
install -Dm755 "$WEBENGINE_PROCESS" "$INSTALL_DIR/libexec/QtWebEngineProcess"
cat > "$INSTALL_DIR/libexec/qt.conf" <<'QTC_EOF'
[Paths]
Prefix=..
Libraries=lib
Plugins=plugins
Qml2Imports=qml
Data=.
Translations=translations
QTC_EOF

mkdir -p "$INSTALL_DIR/resources" "$INSTALL_DIR/translations/qtwebengine_locales"
for resource_file in \
    qtwebengine_resources.pak \
    qtwebengine_devtools_resources.pak \
    qtwebengine_resources_100p.pak \
    qtwebengine_resources_200p.pak \
    icudtl.dat
do
    resource_path="$(find_first_file "$resource_file" \
        "$QT_INSTALL_DATA/resources" \
        "$CONDA_PREFIX/resources" \
        "$CONDA_PREFIX/share/qt6/resources" \
        "$CONDA_PREFIX" || true)"
    [[ -n "$resource_path" ]] || fail "QtWebEngine resource not found: $resource_file"
    cp -v "$resource_path" "$INSTALL_DIR/resources/"
done

WEBENGINE_LOCALES_DIR=""
for candidate in \
    "$QT_INSTALL_TRANSLATIONS/qtwebengine_locales" \
    "$CONDA_PREFIX/translations/qtwebengine_locales" \
    "$CONDA_PREFIX/share/qt6/translations/qtwebengine_locales" \
    "$CONDA_PREFIX/lib/qt6/translations/qtwebengine_locales"
do
    if [[ -d "$candidate" ]]; then
        WEBENGINE_LOCALES_DIR="$candidate"
        break
    fi
done
[[ -n "$WEBENGINE_LOCALES_DIR" ]] || fail "qtwebengine_locales directory not found"
cp -rv "$WEBENGINE_LOCALES_DIR"/*.pak "$INSTALL_DIR/translations/qtwebengine_locales/"

# linuxdeploy-plugin-qt usually detects QML imports, but QtWebEngine is easy to
# miss because WorkshopPage loads the WebEngine component lazily.  Copy its QML
# module explicitly as a fallback.
if [[ -n "$QT_INSTALL_QML" && -d "$QT_INSTALL_QML/QtWebEngine" ]]; then
    mkdir -p "$INSTALL_DIR/qml"
    cp -rv "$QT_INSTALL_QML/QtWebEngine" "$INSTALL_DIR/qml/"
fi

else
    step "Skipping QtWebEngine runtime bundle (lite AppImage)"
fi

# # ---- Fetch linuxdeploy / appimagetool (cached on first run under build/_tools) ----
mkdir -p "$TOOLS_DIR"
LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-x86_64.AppImage"
LINUXDEPLOY_QT="$TOOLS_DIR/linuxdeploy_plugin_qt"
APPIMAGETOOL="$TOOLS_DIR/appimagetool-x86_64.AppImage"
download_if_missing() {
    local url="$1" dest="$2"
    if [[ ! -x "$dest" ]]; then
        step "Downloading $(basename "$dest")"
        curl -fsSL --retry 3 -o "$dest" "$url"
        chmod +x "$dest"
    fi
}
download_if_missing \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
    "$LINUXDEPLOY"
download_if_missing \
    "https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage" \
    "$LINUXDEPLOY_QT"
download_if_missing \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
    "$APPIMAGETOOL"

# ---- Custom AppRun (launches the daemon and points it at the bundled UI / display backend) ----
APPRUN_TMP="$(mktemp -t waywallen-AppRun.XXXXXX)"
trap 'rm -f "$APPRUN_TMP"' EXIT
cat > "$APPRUN_TMP" <<'APPEOF'
#!/usr/bin/env bash
# AppImage entry point: launch the daemon, which spawns the bundled UI and
# display backend.
# Layout follows the qt.conf generated by linuxdeploy-plugin-qt:
#   usr/lib/      -> Qt shared libs + our libqml_material.so
#   usr/plugins/  -> Qt platform plugins / wayland-* / imageformats / etc.
#   usr/qml/      -> all QML modules (Qt's own + Qcm/Material + waywallen/ui)
HERE="$(dirname "$(readlink -f "$0")")"
OWE_PLUGIN_DIR="$HERE/usr/share/waywallen/plugins/org.waywallen.open-wallpaper-engine"
# Renderer plugins may ship private shared libraries next to their binaries
# (notably open-wallpaper-engine / wescene / weweb).  Keep those directories in
# the runtime loader path, otherwise the daemon reports the renderer as "not
# found" even though the plugin files are present in the AppImage.
export LD_LIBRARY_PATH="$OWE_PLUGIN_DIR/bin:$OWE_PLUGIN_DIR/bin/weweb:$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
export QT_PLUGIN_PATH="$HERE/usr/plugins:${QT_PLUGIN_PATH:-}"
export QML2_IMPORT_PATH="$HERE/usr/qml:${QML2_IMPORT_PATH:-}"
export QML_IMPORT_PATH="$QML2_IMPORT_PATH"

# Persistent Steam Workshop login for the embedded QtWebEngine browser.
WAYWALLEN_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/waywallen"
mkdir -p "$WAYWALLEN_DATA_HOME/steam-workshop-webengine/cache"

# Turn on useful daemon diagnostics unless the user explicitly chose another log level.
export RUST_LOG="${RUST_LOG:-waywallen=info}"

# QtWebEngine is a Chromium runtime: it needs an external helper process and
# resource/locale files.  AppImage mount paths are dynamic, so point WebEngine
# at the bundled files explicitly on every launch.  Force dark rendering to
# avoid the white flash and Steam's bright pages in the embedded Workshop.
export QTWEBENGINEPROCESS_PATH="$HERE/usr/libexec/QtWebEngineProcess"
export QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:-} --force-dark-mode --enable-features=WebContentsForceDark"
export QTWEBENGINE_RESOURCES_PATH="$HERE/usr/resources"
export QTWEBENGINE_LOCALES_PATH="$HERE/usr/translations/qtwebengine_locales"

# On some distributions unprivileged user namespaces are disabled; in that case
# Chromium's sandbox prevents the embedded Workshop browser from starting.  Keep
# the sandbox when possible, otherwise fall back to no-sandbox for the AppImage.
if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]] \
    && [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "1" ]]; then
    unset QTWEBENGINE_DISABLE_SANDBOX
else
    export QTWEBENGINE_DISABLE_SANDBOX=1
fi

exec "$HERE/usr/bin/waywallen" \
    --ui "$HERE/usr/bin/waywallen-ui" \
    --plugin "$HERE/usr/share/waywallen" \
    "$@"
APPEOF
chmod +x "$APPRUN_TMP"

# ---- linuxdeploy stages dependencies into AppDir (no packaging yet, so we can prune in between) ----
step "linuxdeploy: staging dependencies into AppDir"
DESKTOP_FILE="$INSTALL_DIR/share/applications/org.waywallen.waywallen.desktop"
ICON_FILE="$INSTALL_DIR/share/icons/hicolor/scalable/apps/org.waywallen.waywallen.svg"
[[ -f "$DESKTOP_FILE" ]] || fail "missing .desktop file: $DESKTOP_FILE"
[[ -f "$ICON_FILE"   ]] || fail "missing icon: $ICON_FILE"

pushd $TOOLS_DIR
$LINUXDEPLOY_QT --appimage-extract
$LINUXDEPLOY --appimage-extract
LINUXDEPLOY=$TOOLS_DIR/squashfs-root/AppRun
popd

cd "$PROJECT_DIR/build"
LINUXDEPLOY_EXECUTABLE_ARGS=(
    --executable "$INSTALL_DIR/bin/waywallen-ui"
    --executable "$INSTALL_DIR/bin/waywallen-video-renderer"
)
if [[ "$WAYWALLEN_APPIMAGE_WEBENGINE" == "ON" ]]; then
    LINUXDEPLOY_EXECUTABLE_ARGS+=(--executable "$INSTALL_DIR/libexec/QtWebEngineProcess")
fi
for renderer_path in "${OWE_RENDERER_BINS[@]}"; do
    LINUXDEPLOY_EXECUTABLE_ARGS+=(--executable "$renderer_path")
done
OWE_RENDERER_LD_PATH="$(IFS=:; printf '%s' "${OWE_RENDERER_DIRS[*]}")"
PATH="$TOOLS_DIR:$PATH" \
LD_LIBRARY_PATH="$OWE_RENDERER_LD_PATH:$INSTALL_DIR/lib:$CONDA_PREFIX/lib" \
QMAKE="$CONDA_PREFIX/bin/qmake6" \
EXTRA_PLATFORM_PLUGINS="libqwayland.so" \
EXTRA_QT_PLUGINS="wayland-decoration-client;wayland-shell-integration" \
QML_SOURCES_PATHS="$PROJECT_DIR/ui/qml" \
"$LINUXDEPLOY" \
    --appdir "$APPDIR" \
    --plugin qt \
    "${LINUXDEPLOY_EXECUTABLE_ARGS[@]}" \
    --desktop-file "$DESKTOP_FILE" \
    --icon-file "$ICON_FILE" \
    --custom-apprun "$APPRUN_TMP"

cp -rv "$CONDA_PREFIX/lib/qt6/plugins/wayland-graphics-integration-client" "$APPDIR/usr/plugins/"
cp -v "$CONDA_PREFIX/lib/libstdc++.so.6" "$APPDIR/usr/lib/"
cp -v "$CONDA_PREFIX/lib/libgcc_s.so.1" "$APPDIR/usr/lib/"

pushd "$APPDIR"
rm -rf ./usr/lib/qt6
rm -rf ./usr/lib/libQt6QuickDialogs*
rm -rf ./usr/lib/libQt6QuickParticles.so.?
rm -rf ./usr/lib/libQt6QuickShapesDesignHelpers.so.?
rm -rf ./usr/lib/libvulkan.so.1 ./lib/libva*
rm -rf ./usr/lib/libgcc_s.so.1
rm -rf ./usr/lib/libdbus-1.so.3
rm -rf ./usr/lib/libcom_err.so.3
rm -rf ./usr/lib/libkrb5*
rm -rf ./usr/lib/libk5crypto.so.3
rm -rf ./usr/lib/libgssapi_krb5*
rm -rf ./usr/lib/libxkbcommon*
rm -rf ./usr/lib/*.a
popd

# ---- Drop unused QuickControls2 styles (native libs + QML modules) ----
step "Pruning unused QuickControls2 styles"
# Each name targets BOTH:
#   usr/lib/libQt6QuickControls2<Style>*.so*    (style + StyleImpl shared libs)
#   usr/qml/QtQuick/Controls/<Style>/           (QML module dir for the style)
QUICKCONTROLS2_PRUNE=(Basic Fusion FluentWinUI3 Imagine Material Universal designer)
for style in "${QUICKCONTROLS2_PRUNE[@]}"; do
    for libdir in "$APPDIR/usr/lib" "$APPDIR/usr/lib64"; do
        [[ -d "$libdir" ]] || continue
        find "$libdir" -maxdepth 1 -type f \
            -name "libQt6QuickControls2${style}*.so*" -print -delete 2>/dev/null || true
    done
    rm -rfv "$APPDIR/usr/qml/QtQuick/Controls/${style}" 2>/dev/null || true
done

# ---- Pack the AppImage ----
step "Packing AppImage"
rm -f "$APPIMAGE_OUT"
PATH="$TOOLS_DIR:$PATH" \
ARCH=x86_64 \
"$APPIMAGETOOL" --appimage-extract-and-run \
    --no-appstream \
    "$APPDIR" "$APPIMAGE_OUT"
[[ -f "$APPIMAGE_OUT" ]] || fail "AppImage build failed"

cat <<EOF

Build complete: $APPIMAGE_OUT

Run it:
    chmod +x "$APPIMAGE_OUT"   # if not already executable
    "$APPIMAGE_OUT"

Rebuild: re-run ./scripts/build_appimage.sh (incremental rebuild + repack).
EOF
