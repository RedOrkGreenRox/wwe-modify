# TODO for `wwe-modify`

This file tracks the fork-specific roadmap.

Priority legend:
- **P0** — do first, affects correctness/safety/core UX
- **P1** — important, should be done after P0
- **P2** — useful backlog / polish / future work

---

## 1. Product logic: Lite / Full

### P0
- [ ] **Remove the runtime embedded-browser toggle from Settings**
  - Lite and Full are different builds, not one build with a user switch.
  - Delete dead UI/settings state around `useEmbeddedWorkshopBrowser` if it is not actually used.

- [ ] **Formalize Workshop behavior by build type**
  - **Lite**: Workshop page opens Steam and/or the system browser.
  - **Full**: Workshop page opens the embedded QtWebEngine view.
  - **Full fallback**: if WebEngine cannot start, offer external open actions.

- [ ] **Make Workshop fallback explicit and predictable**
  - Show a clear message when embedded mode is unavailable.
  - Provide buttons for:
    - `Open in Steam`
    - `Open in browser`
    - `Retry`

- [ ] **Keep Workshop UI separate from subscription detection/import**
  - `WorkshopPage` should only open/show Workshop.
  - Steam/workshop filesystem detection should stay in a separate watcher/import pipeline.

### P1
- [ ] **Handle the case where Steam deep-link open fails**
  - Try Steam first if supported.
  - If it fails, fall back to the browser.

- [ ] **Represent Workshop page mode as a small state machine**
  - Suggested states:
    - `externalOnly`
    - `embeddedLoading`
    - `embeddedReady`
    - `embeddedFailed`

---

## 2. Security

### P0
- [ ] **Bind the WebSocket control plane to localhost instead of `0.0.0.0`**
  - Prefer `127.0.0.1` at minimum.
  - Revisit UDS/local-auth later if needed.

- [ ] **Define embedded navigation policy for Full builds**
  - Decide which domains are allowed in the embedded view.
  - Decide what should always open externally.
  - Handle login redirects and third-party pages explicitly.

- [ ] **Verify and document Workshop cookie/cache storage paths**
  - Ensure storage is stable and intentional.
  - Ensure it survives restarts as expected.
  - Ensure it can be cleared safely.

### P1
- [ ] **Add `Clear Workshop session/cache` action**
  - Useful for broken login state and support/debugging.

- [ ] **Improve fallback/error logging around Workshop launch**
  - Log reasons such as:
    - WebEngine unavailable
    - page load failure
    - Steam deep-link failure
    - external fallback used

### P2
- [ ] **Plan optional local authentication for WS control plane**
  - Backlog item after localhost bind is done.

---

## 3. Navigation and UX

### P0
- [ ] **Move `Plugins` and `Settings` into the sidebar**
  - Current placement inside the Status page actions is too hidden.
  - Recommended sidebar order:
    - Wallpapers
    - Workshop
    - Displays
    - Status
    - Plugins
    - Settings

- [ ] **Add a visible build badge: `Lite` / `Full`**
  - Place it near the logo/title or another always-visible corner.
  - Keep it clean and unobtrusive.

### P1
- [ ] **Make the Lite Workshop page a proper launcher page**
  - Instead of feeling like a missing feature, it should intentionally present:
    - explanation
    - `Open in Steam`
    - `Open in browser`
    - short note that subscribed items are imported automatically

- [ ] **Keep only useful top-level actions for the Full Workshop page**
  - Recommended actions:
    - `Open externally`
    - `Open in Steam`
    - `Reload`

- [ ] **Expose keyboard shortcuts in the UI**
  - Add a small hint/tooltip/help block for shortcuts such as:
    - `Ctrl+F`
    - `F5`
    - `Enter`
    - `Space`

---

## 4. Steam Workshop auto-detection / import pipeline

### P0
- [ ] **Replace 5-second polling with filesystem events**
  - Prefer `notify` / inotify-based watching of the relevant Steam Workshop directories.
  - Trigger rescan/import on actual changes.

- [ ] **Make new Workshop subscriptions import reliably without manual refresh**
  - New items should appear quickly and predictably after Steam updates the library.

### P1
- [ ] **Keep polling only as a fallback path**
  - Event-driven watching should be primary.
  - Polling remains as backup if watching is unavailable.

- [ ] **Restrict watcher scope to only the necessary directories**
  - Avoid unnecessary filesystem work.

- [ ] **Add watcher/import pipeline logs**
  - Suggested log milestones:
    - watcher started
    - path changed
    - rescan queued
    - import succeeded
    - import failed

---

## 5. Full build memory / runtime behavior

### P1
- [ ] **Re-check lazy WebEngine initialization feasibility**
  - Only if it can be done without breaking build/runtime stability.
  - Not P0 because current attempts already showed build/runtime risk.

- [ ] **Verify actual tray/minimize behavior for embedded Workshop**
  - Confirm whether the browser is really released/unloaded on hide/minimize.
  - Document the result.

- [ ] **Add debug information for Workshop mode/runtime path**
  - At least in logs, optionally in a debug/status block:
    - embedded vs external mode
    - fallback reason
    - watcher/import status

### P2
- [ ] **Consider future low-memory policy only if needed**
  - Not a priority: users choosing Full already accept higher memory cost.

---

## 6. Code structure / maintainability

### P1
- [ ] **Split Workshop logic into clearer modules/files**
  - Suggested separation:
    - Workshop page shell
    - Embedded Workshop component
    - External launcher helper
    - Workshop URL helper
    - Steam/workshop watcher/import helper

- [ ] **Minimize Lite/Full drift**
  - Keep one shared Workshop UX layer where possible.
  - Only the launch/render strategy should differ.

- [ ] **Add smoke tests for Workshop mode selection and fallback**
  - Lite path
  - Full path
  - Full fallback path
  - Steam deep-link failure fallback

### P2
- [ ] **Delete dead/misleading code after the cleanup**
  - Remove stale settings, comments, and branches that no longer match behavior.

---

## 7. Documentation / releases

### P0
- [ ] **Rewrite README for the fork**
  - Document what the fork changes.
  - Document Lite vs Full.
  - Document Workshop behavior.
  - Document current navigation.

- [ ] **Update README once `Plugins` and `Settings` move into the sidebar**
  - Keep navigation docs aligned with the real UI.

### P1
- [ ] **Add separate screenshots for Lite and Full**
  - Especially the Workshop page.

- [ ] **Restore a minimal CI pipeline**
  - At least:
    - formatting
    - build sanity
    - smoke checks where possible

- [ ] **Add a short migration note for releases**
  - Explain the split between Lite and Full.
  - Explain Workshop-related behavior changes.
  - Mention `--replace` behavior if relevant to the release.

---

## 8. Extra quality-of-life features

### P1
- [ ] **Add explicit `Open in Steam` action**
  - Separate from `Open in browser`.

- [ ] **Add `Open current page externally` action for Full**
  - If the user navigated inside embedded Workshop, open the same current page externally.

### P2
- [ ] **Optional `Copy current Workshop URL` action**
  - Useful for debugging/sharing.

---

## Near-term recommended execution order

1. Remove the runtime embedded-browser toggle.
2. Formalize Lite/Full behavior.
3. Move Plugins and Settings into the sidebar.
4. Bind WS to localhost.
5. Replace polling with filesystem events for Workshop subscription detection.
6. Improve Workshop fallback UI.
7. Clean up dead code.
8. Update README and restore minimal CI.
