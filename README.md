![wwe-modify](ui/assets/waywallen-ui.svg)

# wwe-modify

**Waywallen fork with a Steam Workshop-first workflow for Linux**

Lite / Full AppImages · Embedded Workshop or external Steam/browser flow · Localhost-only control plane

---

`wwe-modify` is a fork of [waywallen](https://github.com/waywallen/waywallen).

The base project is a Linux wallpaper manager. This fork keeps that architecture,
but puts extra focus on the **Wallpaper Engine Steam Workshop** use case:

- easier Workshop access
- two distribution variants: **Lite** and **Full**
- better AppImage ergonomics
- safer daemon replacement when relaunching/upgrading AppImages

---

## What this fork adds

Compared to upstream `waywallen`, this fork currently adds or changes:

- a dedicated **Workshop** page in the UI
- **two AppImage variants**:
  - **Lite** — opens Workshop externally through Steam and/or the default browser
  - **Full** — opens Workshop directly inside the app through QtWebEngine
- `--replace` daemon handoff behavior to avoid stale tray/daemon state after upgrades or relaunches
- Workshop-oriented AppImage build helpers
- a **localhost-only** WebSocket control plane for the desktop UI

This is still the same general Waywallen codebase, but with a more Workshop-first product direction.

---

## Lite vs Full

### Lite
Use this if you want the lightest and simplest build.

**Behavior**
- the Workshop page acts as a launcher / entry point
- Workshop opens in **Steam** or the **system browser**
- lower memory usage
- no embedded browser engine in the UI

**Good for**
- lower-memory systems
- users who already prefer using the Steam client directly
- users who want the smallest AppImage

### Full
Use this if you want the most seamless in-app Workshop experience.

**Behavior**
- Workshop opens **inside the app** through QtWebEngine
- browsing feels more integrated
- higher memory usage is expected
- if embedded WebEngine fails to start, the intended fallback is external open actions

**Good for**
- users who want the smoothest Workshop browsing flow
- systems where extra RAM use is acceptable

---

## How the Workshop flow works

This fork does **not** directly replace Steam.

The intended workflow is:

1. open the Wallpaper Engine Workshop
2. subscribe to an item through Steam
3. Steam updates the local Workshop files on disk
4. `wwe-modify` detects the new content and imports it into the wallpaper list

So the important part is not only showing the Workshop page, but also reliably
**detecting new local Workshop content** after Steam syncs it.

---

## Current UI navigation

Main navigation currently includes:

- **Wallpapers**
- **Workshop**
- **Displays**
- **Status**
- **Plugins**
- **Settings**

`Plugins` and `Settings` are meant to be accessed directly from the main navigation.

---

## Security note

The desktop UI talks to the daemon over a local WebSocket control plane bound to:

- `127.0.0.1`

That means the control surface is intended for the local desktop session, not for general network exposure.

---

## Build and packaging

### Build both AppImages
```bash
./make_appimages.sh
```

### Build Lite only
```bash
./make_appimages.sh lite
```

### Build Full only
```bash
./make_appimages.sh full
```

### Direct script usage
```bash
# Lite
WAYWALLEN_APPIMAGE_WEBENGINE=OFF ./scripts/build_appimage.sh

# Full
WAYWALLEN_APPIMAGE_WEBENGINE=ON ./scripts/build_appimage.sh
```

The fork build scripts are designed to be more practical for end users and
contributors. They can bootstrap missing tooling such as Rust and micromamba,
and they bundle QtWebEngine only for the **Full** edition.

For the base build flow inherited from upstream, also see [BUILD.md](BUILD.md).

---

## AppImage runtime behavior

The packaged AppImage uses the daemon with `--replace` so that an already-running
older tray-resident daemon does not keep stale paths or stale plugin state after
an upgrade or relaunch.

That is especially useful for this fork, because Workshop-centric usage is more
likely to involve long-running background daemon sessions.

---

## Desktop support

| Desktop | Integration | Mouse input | Auto pause |
|---------|-------------|:-----------:|:----------:|
| **KDE Plasma** | [waywallen-display](https://github.com/waywallen/waywallen-display/) | ✅ | ✅ |
| **GNOME** | [waywallen-display](https://github.com/waywallen/waywallen-display/) | ✅ | ✅ |
| **Hyprland** | `zwlr_layer_shell_v1` | ✅ | ✅ |
| **Niri** | `zwlr_layer_shell_v1` | ✅ | ❌ |
| **Sway** | `zwlr_layer_shell_v1` | ✅ | ❌ |

---

## Plugins and wallpaper types

Built-in coverage inherited from the main project includes:

- image wallpapers
- video wallpapers

Third-party plugins can extend support further, including Wallpaper Engine-related content through external plugins.

---

## Status of the fork

This fork already has the main Workshop direction in place, but some cleanup is still planned:

- improve Workshop fallback UX
- replace polling-based Workshop detection with filesystem-event-based watching
- continue cleanup of dead or misleading UI/config state
- restore or expand automated checks/CI

The working roadmap lives in [TODO.md](TODO.md).

---

## Screenshots

<p align="center">
  <img src="ui/assets/main_page.webp" alt="wwe-modify main page" width="720" />
</p>

> This screenshot comes from the shared Waywallen UI base. Dedicated Lite/Full Workshop screenshots are still recommended for this fork.

---

## Upstream

Base project:
- [waywallen/waywallen](https://github.com/waywallen/waywallen)

This fork stays close to upstream architecture, but changes the product focus around Steam Workshop usability and packaging.
