use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use futures_util::{SinkExt, StreamExt};
use prost::Message as _;
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::control;
use crate::control_proto as pb;
use crate::error::{ok_response, Error};
use crate::events::GlobalEvent;

const APPLY_FIRST_FRAME_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
use crate::ipc::proto::ControlMsg;
use crate::model::repo;
use crate::plugin::source_manager::DiscoverDownload;
use crate::queue;
use crate::renderer_manager;
use crate::routing::{
    DisplaySnapshot, LayoutSource, LibrarySnapshot, RendererSnapshot, RouterEvent,
};
use crate::settings::{SettingsStore, WallpaperFilterState, WallpaperSortRuleState};
use crate::tasks;
use crate::wallpaper::properties::{
    dedupe_predefined_schema, is_daemon_display_property_key, user_property_default_wire_value,
    WallpaperLayoutOverride,
};
use crate::wallpaper::sort::apply_wallpaper_sorts;
use crate::AppState;

/// Bind the WebSocket control plane and return the actual local address.
/// The returned future runs the accept loop.
pub async fn bind(
    state: Arc<AppState>,
    addr: &str,
) -> Result<(
    std::net::SocketAddr,
    impl std::future::Future<Output = Result<()>>,
)> {
    let listener = TcpListener::bind(addr).await?;
    let local_addr = listener.local_addr()?;
    log::info!("ws control plane listening on {local_addr}");
    let fut = accept_loop(state, listener);
    Ok((local_addr, fut))
}

pub async fn serve(state: Arc<AppState>, addr: &str) -> Result<()> {
    let (_, fut) = bind(state, addr).await?;
    fut.await
}

// Filter state ↔ pb conversion lives on `WallpaperFilterState` itself
// so ws_server and control share one round-trip implementation.

async fn accept_loop(state: Arc<AppState>, listener: TcpListener) -> Result<()> {
    loop {
        let (stream, peer) = listener.accept().await?;
        let state = state.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_conn(state, stream, peer).await {
                log::warn!("ws conn {peer} ended: {e}");
            }
        });
    }
}

async fn handle_conn(
    state: Arc<AppState>,
    stream: TcpStream,
    peer: std::net::SocketAddr,
) -> Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;
    log::debug!("ws conn {peer} open");
    let (mut sink, mut src) = ws.split();

    // Subscribe to router events *before* snapshotting so no updates
    // get dropped between the snapshot and the live stream starting.
    let mut events_rx = state.router.subscribe_events();
    // Subscribe to process-wide events (scan lifecycle etc.). Lag here
    // is non-fatal — UI re-fetches on the next event.
    let mut global_rx = state.events.subscribe();
    // Task-lifecycle events feed into `StatusSync` (active task count
    // is one of its fields). Lag is non-fatal; the next push corrects.
    let mut task_rx = state.tasks.subscribe();
    {
        let snap = state.router.snapshot_displays().await;
        let evt = displays_replace_event(snap, &state.settings);
        sink.send(Message::Binary(wrap_event(evt).encode_to_vec()))
            .await?;
    }
    {
        let snap = state.router.snapshot_renderers().await;
        let evt = renderers_replace_event(snap, &state.settings);
        sink.send(Message::Binary(wrap_event(evt).encode_to_vec()))
            .await?;
    }

    {
        let snap = control::list_library_snapshots(&state.db).await;
        let evt = libraries_replace_event(snap);
        sink.send(Message::Binary(wrap_event(evt).encode_to_vec()))
            .await?;
    }
    // Initial daemon-status snapshot. Same wire shape as subsequent
    // pushes so the UI handler is uniform.
    sink.send(Message::Binary(
        wrap_event(status_sync_event(&state)).encode_to_vec(),
    ))
    .await?;
    sink.send(Message::Binary(
        wrap_event(playlist_changed_event(&state).await).encode_to_vec(),
    ))
    .await?;

    loop {
        tokio::select! {
            msg = src.next() => {
                let Some(msg) = msg else { break };
                let msg = msg?;
                let bytes = match msg {
                    Message::Binary(b) => b,
                    Message::Text(t) => t.into_bytes(),
                    Message::Ping(_) | Message::Pong(_) => continue,
                    Message::Close(_) => break,
                    Message::Frame(_) => continue,
                };

                let req = match pb::Request::decode(&bytes[..]) {
                    Ok(r) => r,
                    Err(e) => {
                        let resp = Error::Decode(e).to_response(0);
                        sink.send(Message::Binary(wrap_response(resp).encode_to_vec())).await?;
                        continue;
                    }
                };

                let resp = dispatch(&state, req).await;
                sink.send(Message::Binary(wrap_response(resp).encode_to_vec())).await?;
            }
            gevt = global_rx.recv() => {
                match gevt {
                    Ok(e) => {
                        if matches!(e, GlobalEvent::PlaylistChanged) {
                            sink.send(Message::Binary(wrap_event(playlist_changed_event(&state).await).encode_to_vec())).await?;
                        } else if let Some(pe) = global_event_to_pb(&e, &state) {
                            sink.send(Message::Binary(wrap_event(pe).encode_to_vec())).await?;
                        }
                        if matches!(e, GlobalEvent::StatusChanged) {
                            sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("ws {peer}: global event lag {n}");
                        // Resync after lag; snapshots are authoritative,
                        // while transient events are allowed to drop.
                        sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
                        sink.send(Message::Binary(wrap_event(playlist_changed_event(&state).await).encode_to_vec())).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        // Daemon shutting down — let the router-event
                        // arm or the request arm break us out cleanly.
                    }
                }
            }
            tevt = task_rx.recv() => {
                match tevt {
                    Ok(_) => {
                        sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("ws {peer}: task event lag {n}");
                        sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {}
                }
            }
            evt = events_rx.recv() => {
                match evt {
                    Ok(e) => {
                        let pe = router_event_to_pb(e, &state.settings);
                        sink.send(Message::Binary(wrap_event(pe).encode_to_vec())).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("ws {peer}: event lag {n}; resending full snapshot");
                        let snap = state.router.snapshot_displays().await;
                        let evt = displays_replace_event(snap, &state.settings);
                        sink.send(Message::Binary(wrap_event(evt).encode_to_vec())).await?;
                        let rsnap = state.router.snapshot_renderers().await;
                        let revt = renderers_replace_event(rsnap, &state.settings);
                        sink.send(Message::Binary(wrap_event(revt).encode_to_vec())).await?;
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                        // Router shut down; stop emitting but keep the
                        // request path alive until the client closes.
                        log::info!("ws {peer}: router event channel closed");
                        // Drain remaining requests without event select.
                        while let Some(msg) = src.next().await {
                            let msg = msg?;
                            let bytes = match msg {
                                Message::Binary(b) => b,
                                Message::Text(t) => t.into_bytes(),
                                Message::Ping(_) | Message::Pong(_) => continue,
                                Message::Close(_) => break,
                                Message::Frame(_) => continue,
                            };
                            let req = match pb::Request::decode(&bytes[..]) {
                                Ok(r) => r,
                                Err(e) => {
                                    let resp = Error::Decode(e).to_response(0);
                                    sink.send(Message::Binary(wrap_response(resp).encode_to_vec())).await?;
                                    continue;
                                }
                            };
                            let resp = dispatch(&state, req).await;
                            sink.send(Message::Binary(wrap_response(resp).encode_to_vec())).await?;
                        }
                        break;
                    }
                }
            }
        }
    }

    log::debug!("ws conn {peer} closed");
    Ok(())
}

// ---------------------------------------------------------------------------
// RouterEvent → pb::Event translation

fn renderer_def_to_pb(
    def: &crate::plugin::renderer_registry::RendererDef,
    plugin_version: &str,
) -> pb::RendererPluginInfo {
    let mut settings: Vec<pb::SettingSchema> = def
        .settings
        .iter()
        .map(|(k, v)| crate::control_proto::setting_def_to_proto(k, v))
        .collect();
    // Stable order so UIs can rely on deterministic layout: by manifest
    // `order` then key name.
    settings.sort_by(|a, b| a.order.cmp(&b.order).then(a.key.cmp(&b.key)));
    pb::RendererPluginInfo {
        name: def.name.clone(),
        bin: def.bin.to_string_lossy().into_owned(),
        types: def.types.iter().map(|t| t.to_string()).collect(),
        priority: def.priority,
        // Renderers no longer carry their own version; they inherit the
        // owning plugin's. Compatibility is `spawn_version` + bridge.
        version: plugin_version.to_string(),
        settings,
        plugin_id: def.plugin_id.clone(),
    }
}

fn gpu_info_to_pb(g: &crate::gpu::GpuInfo) -> pb::GpuInfo {
    pb::GpuInfo {
        render_node: g
            .render_node
            .as_ref()
            .and_then(|p| p.to_str())
            .map(str::to_string)
            .unwrap_or_default(),
        primary_node: g
            .primary_node
            .as_ref()
            .and_then(|p| p.to_str())
            .map(str::to_string)
            .unwrap_or_default(),
        render_major: g.render_major,
        render_minor: g.render_minor,
        primary_major: g.primary_major,
        primary_minor: g.primary_minor,
        pci_bdf: g.pci_bdf.clone().unwrap_or_default(),
        vendor_id: g.vendor_id as u32,
        device_id: g.device_id as u32,
        driver: g.driver.clone(),
        description: g.description.clone(),
    }
}

fn display_snapshot_to_pb(s: DisplaySnapshot, settings: &SettingsStore) -> pb::DisplayInfo {
    // Router snapshots carry effective layout; settings are consulted only
    // for persisted display override and alias fields.
    let layout_key: &str = s
        .instance_id
        .as_deref()
        .filter(|iid| settings.display_prefs(iid).is_some())
        .unwrap_or(s.name.as_str());
    let override_prefs = settings.display_prefs(layout_key).unwrap_or_default();
    pb::DisplayInfo {
        display_id: s.id,
        name: s.name,
        width: s.width,
        height: s.height,
        refresh_mhz: s.refresh_mhz,
        links: s
            .links
            .into_iter()
            .map(|l| pb::DisplayLinkInfo {
                renderer_id: l.renderer_id,
                z_order: l.z_order,
            })
            .collect(),
        effective_layout: Some(layout_prefs_to_pb_resolved(&s.effective_layout)),
        layout_override: Some(layout_override_to_pb(&override_prefs)),
        drm_render_major: s.drm_render_major,
        drm_render_minor: s.drm_render_minor,
        alias: override_prefs.alias.clone().unwrap_or_default(),
        display_layout: Some(layout_prefs_to_pb_resolved(&s.display_layout)),
        effective_layout_source: layout_source_to_pb(s.effective_layout_source) as i32,
    }
}

fn layout_source_to_pb(source: LayoutSource) -> pb::LayoutSource {
    match source {
        LayoutSource::Global => pb::LayoutSource::Global,
        LayoutSource::Display => pb::LayoutSource::Display,
        LayoutSource::Wallpaper => pb::LayoutSource::Wallpaper,
    }
}

fn layout_prefs_to_pb_resolved(r: &crate::settings::ResolvedLayout) -> pb::LayoutPrefs {
    pb::LayoutPrefs {
        fillmode: fillmode_to_pb(r.fillmode) as i32,
        align: align_to_pb(r.location.to_align()) as i32,
        rotation: rotation_to_pb(r.rotation) as i32,
        location_x: u32::from(r.location.x.min(100)),
        location_y: u32::from(r.location.y.min(100)),
        location_set: true,
    }
}

fn layout_override_to_pb(p: &crate::settings::DisplayPrefs) -> pb::LayoutOverride {
    let location = p
        .location
        .or_else(|| p.align.map(crate::display::layout::Location::from_align));
    pb::LayoutOverride {
        fillmode_set: p.fillmode.is_some(),
        fillmode: p
            .fillmode
            .map(fillmode_to_pb)
            .unwrap_or(pb::FillMode::Unspecified) as i32,
        align_set: p.align.is_some(),
        align: p.align.map(align_to_pb).unwrap_or(pb::Align::Unspecified) as i32,
        rotation_set: p.rotation.is_some(),
        rotation: p
            .rotation
            .map(rotation_to_pb)
            .unwrap_or(pb::Rotation::Unspecified) as i32,
        location_set: location.is_some(),
        location_x: location.map(|v| u32::from(v.x.min(100))).unwrap_or(0),
        location_y: location.map(|v| u32::from(v.y.min(100))).unwrap_or(0),
    }
}

fn fillmode_to_pb(fm: crate::display::layout::FillMode) -> pb::FillMode {
    use crate::display::layout::FillMode as F;
    match fm {
        F::Stretched => pb::FillMode::Stretched,
        F::PreserveAspectFit => pb::FillMode::PreserveAspectFit,
        F::PreserveAspectCrop => pb::FillMode::PreserveAspectCrop,
        F::Centered => pb::FillMode::Centered,
    }
}

fn fillmode_from_pb(v: i32) -> Option<crate::display::layout::FillMode> {
    use crate::display::layout::FillMode as F;
    match pb::FillMode::try_from(v).ok()? {
        pb::FillMode::Unspecified => None,
        pb::FillMode::Stretched => Some(F::Stretched),
        pb::FillMode::PreserveAspectFit => Some(F::PreserveAspectFit),
        pb::FillMode::PreserveAspectCrop => Some(F::PreserveAspectCrop),
        pb::FillMode::Centered => Some(F::Centered),
    }
}

fn rotation_to_pb(r: crate::display::layout::Rotation) -> pb::Rotation {
    use crate::display::layout::Rotation as R;
    match r {
        R::Normal => pb::Rotation::Normal,
        R::Cw90 => pb::Rotation::Cw90,
        R::Cw180 => pb::Rotation::Cw180,
        R::Cw270 => pb::Rotation::Cw270,
    }
}

fn rotation_from_pb(v: i32) -> Option<crate::display::layout::Rotation> {
    use crate::display::layout::Rotation as R;
    match pb::Rotation::try_from(v).ok()? {
        pb::Rotation::Unspecified => None,
        pb::Rotation::Normal => Some(R::Normal),
        pb::Rotation::Cw90 => Some(R::Cw90),
        pb::Rotation::Cw180 => Some(R::Cw180),
        pb::Rotation::Cw270 => Some(R::Cw270),
    }
}

fn align_to_pb(a: crate::display::layout::Align) -> pb::Align {
    use crate::display::layout::Align as A;
    match a {
        A::TopLeft => pb::Align::TopLeft,
        A::Top => pb::Align::Top,
        A::TopRight => pb::Align::TopRight,
        A::Left => pb::Align::Left,
        A::Center => pb::Align::Center,
        A::Right => pb::Align::Right,
        A::BottomLeft => pb::Align::BottomLeft,
        A::Bottom => pb::Align::Bottom,
        A::BottomRight => pb::Align::BottomRight,
    }
}

fn align_from_pb(v: i32) -> Option<crate::display::layout::Align> {
    use crate::display::layout::Align as A;
    match pb::Align::try_from(v).ok()? {
        pb::Align::Unspecified => None,
        pb::Align::TopLeft => Some(A::TopLeft),
        pb::Align::Top => Some(A::Top),
        pb::Align::TopRight => Some(A::TopRight),
        pb::Align::Left => Some(A::Left),
        pb::Align::Center => Some(A::Center),
        pb::Align::Right => Some(A::Right),
        pb::Align::BottomLeft => Some(A::BottomLeft),
        pb::Align::Bottom => Some(A::Bottom),
        pb::Align::BottomRight => Some(A::BottomRight),
    }
}

fn location_from_pb(x: u32, y: u32) -> crate::display::layout::Location {
    crate::display::layout::Location::new(x.min(100) as u8, y.min(100) as u8)
}

fn resolved_layout_from_pb(p: &pb::LayoutPrefs) -> crate::settings::ResolvedLayout {
    crate::settings::ResolvedLayout {
        fillmode: fillmode_from_pb(p.fillmode).unwrap_or_default(),
        location: if p.location_set {
            location_from_pb(p.location_x, p.location_y)
        } else {
            align_from_pb(p.align)
                .map(crate::display::layout::Location::from_align)
                .unwrap_or_default()
        },
        rotation: rotation_from_pb(p.rotation).unwrap_or_default(),
    }
}

fn autopause_mode_to_pb(m: crate::settings::AutopauseMode) -> pb::AutopauseMode {
    use crate::settings::AutopauseMode as M;
    match m {
        M::Never => pb::AutopauseMode::Never,
        M::Any => pb::AutopauseMode::Any,
        M::Max => pb::AutopauseMode::Max,
        M::Focus => pb::AutopauseMode::Focus,
        M::FocusOrMax => pb::AutopauseMode::FocusOrMax,
        M::FullScreen => pb::AutopauseMode::FullScreen,
    }
}

fn autopause_mode_from_pb(v: i32) -> crate::settings::AutopauseMode {
    use crate::settings::AutopauseMode as M;
    match pb::AutopauseMode::try_from(v).unwrap_or(pb::AutopauseMode::Never) {
        pb::AutopauseMode::Never => M::Never,
        pb::AutopauseMode::Any => M::Any,
        pb::AutopauseMode::Max => M::Max,
        pb::AutopauseMode::Focus => M::Focus,
        pb::AutopauseMode::FocusOrMax => M::FocusOrMax,
        pb::AutopauseMode::FullScreen => M::FullScreen,
    }
}

fn global_to_pb(g: &crate::settings::GlobalSettings) -> pb::GlobalSettings {
    let (wallpaper_filters, wallpaper_filter_logics) = g.wallpaper_filter.clone().to_pb();
    let wallpaper_sorts = WallpaperSortRuleState::vec_to_pb(&g.wallpaper_sorts);
    let hotkey_bindings = g
        .hotkeys
        .bindings
        .iter()
        .map(|(action, seqs)| {
            (
                action.clone(),
                pb::HotkeyBinding {
                    sequences: seqs.clone(),
                },
            )
        })
        .collect();
    pb::GlobalSettings {
        wallpaper_filters,
        wallpaper_filter_logics,
        wallpaper_sorts,
        layout_defaults: Some(pb::LayoutPrefs {
            fillmode: fillmode_to_pb(g.layout.fillmode) as i32,
            align: align_to_pb(
                g.layout
                    .location
                    .unwrap_or_else(|| crate::display::layout::Location::from_align(g.layout.align))
                    .to_align(),
            ) as i32,
            rotation: rotation_to_pb(g.layout.rotation) as i32,
            location_x: u32::from(
                g.layout
                    .location
                    .unwrap_or_else(|| crate::display::layout::Location::from_align(g.layout.align))
                    .x
                    .min(100),
            ),
            location_y: u32::from(
                g.layout
                    .location
                    .unwrap_or_else(|| crate::display::layout::Location::from_align(g.layout.align))
                    .y
                    .min(100),
            ),
            location_set: true,
        }),
        autopause: Some(pb::AutopauseSettings {
            mode: autopause_mode_to_pb(g.autopause.mode) as i32,
            resume_ms: g.autopause.resume_ms,
            pause_on_lock: g.autopause.pause_on_lock,
            pause_on_user_switch: g.autopause.pause_on_user_switch,
        }),
        queue_mode: g.queue_mode.clone(),
        rotation_secs: g.rotation_secs,
        wallpaper_skip_types: g.wallpaper_skip_types.clone(),
        wallpaper_filter_tags: g.wallpaper_filter_tags.clone(),
        wallpaper_skip_content_ratings: g.wallpaper_skip_content_ratings.clone(),
        hotkey_bindings,
    }
}

fn displays_replace_event(snap: Vec<DisplaySnapshot>, settings: &SettingsStore) -> pb::Event {
    pb::Event {
        payload: Some(pb::event::Payload::DisplaySnapshot(pb::DisplaySnapshot {
            displays: snap
                .into_iter()
                .map(|s| display_snapshot_to_pb(s, settings))
                .collect(),
        })),
    }
}

fn renderer_snapshot_to_pb(s: RendererSnapshot, settings: &SettingsStore) -> pb::RendererInstance {
    let fps: u32 = settings
        .plugin(&s.name)
        .and_then(|kv| kv.get("fps").and_then(|v| v.parse().ok()))
        .unwrap_or(0);
    pb::RendererInstance {
        renderer_id: s.id,
        fps,
        status: s.status.as_str().to_string(),
        name: s.name,
        pid: s.pid,
        drm_render_major: s.drm_render_major,
        drm_render_minor: s.drm_render_minor,
        texture_width: s.texture_width,
        texture_height: s.texture_height,
    }
}

fn renderers_replace_event(snap: Vec<RendererSnapshot>, settings: &SettingsStore) -> pb::Event {
    pb::Event {
        payload: Some(pb::event::Payload::RendererSnapshot(pb::RendererSnapshot {
            renderers: snap
                .into_iter()
                .map(|s| renderer_snapshot_to_pb(s, settings))
                .collect(),
        })),
    }
}

fn library_instance_to_pb(s: LibrarySnapshot) -> pb::LibraryInstance {
    pb::LibraryInstance {
        id: s.id,
        path: s.path,
        plugin_name: s.plugin_name,
    }
}

fn libraries_replace_event(snap: Vec<LibrarySnapshot>) -> pb::Event {
    pb::Event {
        payload: Some(pb::event::Payload::LibrarySnapshot(pb::LibrarySnapshot {
            libraries: snap.into_iter().map(library_instance_to_pb).collect(),
        })),
    }
}

fn router_event_to_pb(e: RouterEvent, settings: &SettingsStore) -> pb::Event {
    match e {
        RouterEvent::DisplayUpsert(s) => pb::Event {
            payload: Some(pb::event::Payload::DisplayChanged(pb::DisplayChanged {
                display: Some(display_snapshot_to_pb(s, settings)),
            })),
        },
        RouterEvent::DisplayRemoved(id) => pb::Event {
            payload: Some(pb::event::Payload::DisplayRemoved(pb::DisplayRemoved {
                display_id: id,
            })),
        },
        RouterEvent::DisplaysReplace(list) => displays_replace_event(list, settings),
        RouterEvent::RendererUpsert(s) => pb::Event {
            payload: Some(pb::event::Payload::RendererChanged(pb::RendererChanged {
                renderer: Some(renderer_snapshot_to_pb(s, settings)),
            })),
        },
        RouterEvent::RendererRemoved(id) => pb::Event {
            payload: Some(pb::event::Payload::RendererRemoved(pb::RendererRemoved {
                renderer_id: id,
            })),
        },
        RouterEvent::RenderersReplace(list) => renderers_replace_event(list, settings),
        RouterEvent::LibraryUpsert(s) => pb::Event {
            payload: Some(pb::event::Payload::LibraryChanged(pb::LibraryChanged {
                library: Some(library_instance_to_pb(s)),
            })),
        },
        RouterEvent::LibraryRemoved(id) => pb::Event {
            payload: Some(pb::event::Payload::LibraryRemoved(pb::LibraryRemoved {
                id,
            })),
        },
        RouterEvent::LibrariesReplace(list) => libraries_replace_event(list),
    }
}

/// Snapshot daemon-side runtime state into a `StatusSync` server event.
/// Pushed on WS connect, status changes, and task lifecycle events.
fn status_sync_event(state: &Arc<AppState>) -> pb::Event {
    use std::sync::atomic::Ordering;
    let scan_in_progress = state.scan_in_progress.load(Ordering::SeqCst);
    let active_task_count = state
        .tasks
        .list()
        .into_iter()
        .filter(|r| matches!(r.state, tasks::TaskState::Running))
        .count() as u32;
    let phase = if state.events.is_daemon_ready() {
        pb::DaemonPhase::Ready
    } else {
        pb::DaemonPhase::Starting
    };
    pb::Event {
        payload: Some(pb::event::Payload::StatusSync(pb::StatusSync {
            scan_in_progress,
            active_task_count,
            phase: phase as i32,
        })),
    }
}

fn playlist_display_status_to_pb(
    d: crate::playlist::engine::DisplayStatus,
) -> pb::PlaylistDisplayStatus {
    pb::PlaylistDisplayStatus {
        display_id: d.display_id,
        active_id: d.active_id,
        mode: queue_mode_to_pb_playlist(d.mode),
        interval_secs: d.interval_secs,
        current_id: d.current_id.unwrap_or_default(),
        position: d.position,
        count: d.count,
        remaining_secs: d.remaining_secs,
    }
}

async fn playlist_changed_event(state: &Arc<AppState>) -> pb::Event {
    let auto_attach_id = state.settings.global().auto_attach_playlist_id.unwrap_or(0);
    let displays = state
        .playlists
        .status()
        .await
        .into_iter()
        .map(playlist_display_status_to_pb)
        .collect();
    pb::Event {
        payload: Some(pb::event::Payload::PlaylistChanged(pb::PlaylistChanged {
            displays,
            auto_attach_id,
        })),
    }
}

/// Translate the subset of `GlobalEvent` variants the UI cares about
/// into wire events. Returns `None` for daemon-internal events.
fn global_event_to_pb(e: &GlobalEvent, state: &Arc<AppState>) -> Option<pb::Event> {
    match e {
        GlobalEvent::SyncFinished { count } => Some(pb::Event {
            payload: Some(pb::event::Payload::WallpaperSyncFinished(
                pb::WallpaperSyncFinished {
                    count: *count as u32,
                    error: String::new(),
                },
            )),
        }),
        GlobalEvent::SyncFailed(msg) => Some(pb::Event {
            payload: Some(pb::event::Payload::WallpaperSyncFinished(
                pb::WallpaperSyncFinished {
                    count: 0,
                    error: msg.clone(),
                },
            )),
        }),
        GlobalEvent::LibrariesAdded { paths } => Some(pb::Event {
            payload: Some(pb::event::Payload::LibrariesAdded(pb::LibrariesAdded {
                paths: paths.clone(),
            })),
        }),
        GlobalEvent::DisplayConnectionFailed {
            client_name,
            client_protocol_version,
            error_code,
            reason,
        } => Some(pb::Event {
            payload: Some(pb::event::Payload::DisplayConnectionFailed(
                pb::DisplayConnectionFailed {
                    client_name: client_name.clone(),
                    client_protocol_version: *client_protocol_version,
                    error_code: *error_code,
                    reason: reason.clone(),
                },
            )),
        }),
        GlobalEvent::RemoteDownloadProgress {
            source_id,
            id,
            state,
            error,
        } => Some(pb::Event {
            payload: Some(pb::event::Payload::RemoteDownloadProgress(
                pb::RemoteDownloadProgress {
                    source_id: source_id.clone(),
                    id: id.clone(),
                    state: *state,
                    error: error.clone(),
                },
            )),
        }),
        GlobalEvent::SettingsChanged => {
            let snap = state.settings.snapshot();
            Some(pb::Event {
                payload: Some(pb::event::Payload::SettingsChanged(pb::SettingsChanged {
                    global: Some(global_to_pb(&snap.global)),
                    plugins: snap
                        .plugins
                        .into_iter()
                        .map(|(k, v)| (k, pb::PluginSettings { values: v }))
                        .collect(),
                })),
            })
        }
        GlobalEvent::SourcesReady
        | GlobalEvent::DisplayReady
        | GlobalEvent::DaemonReady
        | GlobalEvent::RestoreApplied(_)
        | GlobalEvent::RestoreFailed(_)
        | GlobalEvent::StatusChanged
        | GlobalEvent::PlaylistChanged => None,
    }
}

// ---------------------------------------------------------------------------
// Dispatch

fn sanitize_path_segment(input: &str) -> String {
    let s: String = input
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    if s.is_empty() {
        "default".to_string()
    } else {
        s
    }
}

fn remote_content_dir(source_id: &str) -> PathBuf {
    let base = crate::settings::default_db_path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("remote").join(sanitize_path_segment(source_id))
}

fn safe_remote_filename(filename: &str, id: &str) -> String {
    Path::new(filename)
        .file_name()
        .and_then(|v| v.to_str())
        .filter(|v| !v.trim().is_empty())
        .map(sanitize_path_segment)
        .unwrap_or_else(|| format!("{}.bin", sanitize_path_segment(id)))
}

fn sidecar_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".json");
    PathBuf::from(s)
}

fn publish_remote_download_progress(
    state: &Arc<AppState>,
    source_id: &str,
    id: &str,
    download_state: pb::RemoteDownloadState,
    error: impl Into<String>,
) {
    state.events.publish(GlobalEvent::RemoteDownloadProgress {
        source_id: source_id.to_string(),
        id: id.to_string(),
        state: download_state as i32,
        error: error.into(),
    });
}

async fn default_remote_source_id(state: &Arc<AppState>) -> Result<String> {
    let sm = state.source_manager.lock().await;
    let sources = sm.discover_sources()?;
    sources
        .into_iter()
        .next()
        .map(|s| s.plugin_id)
        .ok_or_else(|| anyhow!("no discover source plugin"))
}

async fn resolve_remote_source_id(state: &Arc<AppState>, source_id: &str) -> Result<String> {
    if !source_id.trim().is_empty() {
        return Ok(source_id.to_string());
    }
    default_remote_source_id(state).await
}

async fn source_plugin_version(state: &Arc<AppState>, source_id: &str) -> String {
    let sm = state.source_manager.lock().await;
    sm.plugin_version(source_id)
        .unwrap_or_else(|| "0.0.0".to_string())
}

async fn ensure_remote_library(
    state: &Arc<AppState>,
    source_id: &str,
    dir: &Path,
) -> Result<crate::model::entities::library::Model> {
    let version = source_plugin_version(state, source_id).await;
    let plugin = repo::upsert_plugin(&state.db, source_id, &version).await?;
    let dir_s = dir.to_string_lossy().to_string();
    let lib = match repo::find_library(&state.db, plugin.id, &dir_s).await? {
        Some(lib) => lib,
        None => repo::add_library(&state.db, plugin.id, &dir_s).await?,
    };
    repo::set_library_metadata_value(
        &state.db,
        lib.id,
        repo::LIBRARY_METADATA_MANAGED_KEY,
        Some(repo::LIBRARY_METADATA_MANAGED_REMOTE),
    )
    .await?;
    Ok(lib)
}

async fn write_remote_sidecar(path: &Path, info: &DiscoverDownload) -> Result<()> {
    let sidecar = sidecar_path(path);
    let tmp = sidecar.with_extension(format!(
        "{}.tmp-{}",
        sidecar
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("json"),
        uuid::Uuid::new_v4()
    ));
    let data = serde_json::to_vec_pretty(info)?;
    tokio::fs::write(&tmp, data).await?;
    tokio::fs::rename(&tmp, &sidecar).await?;
    Ok(())
}

async fn download_remote_file(url: &str, path: &Path) -> Result<()> {
    let tmp = path.with_extension(format!(
        "{}.part-{}",
        path.extension()
            .and_then(|v| v.to_str())
            .unwrap_or("download"),
        uuid::Uuid::new_v4()
    ));
    let result: Result<()> = async {
        let client = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 (X11; Linux x86_64) waywallen")
            .build()?;
        let response = client
            .get(url)
            .send()
            .await
            .with_context(|| format!("download request {url}"))?
            .error_for_status()
            .with_context(|| format!("download response {url}"))?;
        let mut stream = response.bytes_stream();
        let mut file = tokio::fs::File::create(&tmp).await?;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("download chunk")?;
            file.write_all(&chunk).await?;
        }
        file.flush().await?;
        drop(file);
        tokio::fs::rename(&tmp, path).await?;
        Ok(())
    }
    .await;
    if result.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
    }
    result
}

async fn upsert_remote_download(
    state: &Arc<AppState>,
    source_id: &str,
    dir: &Path,
    path: &Path,
    info: &DiscoverDownload,
) -> Result<()> {
    if info.wp_type.trim().is_empty() {
        return Err(anyhow!("download wp_type is empty"));
    }
    let lib = ensure_remote_library(state, source_id, dir).await?;
    let rel = path
        .strip_prefix(dir)
        .ok()
        .and_then(|p| p.to_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("download target is not under remote library"))?;
    let title = if info.title.trim().is_empty() {
        path.file_name()
            .and_then(|v| v.to_str())
            .unwrap_or("Remote wallpaper")
    } else {
        info.title.as_str()
    };
    let item = repo::upsert_item(
        &state.db,
        repo::ItemUpsertArgs {
            plugin_id: lib.plugin_id,
            library_id: lib.id,
            path: rel,
            ty: &info.wp_type,
            display_name: title,
            preview_path: None,
            description: (!info.description.trim().is_empty()).then_some(info.description.as_str()),
            external_id: (!info.external_id.trim().is_empty()).then_some(info.external_id.as_str()),
            size: info.size,
            width: info.width.and_then(|v| i32::try_from(v).ok()),
            height: info.height.and_then(|v| i32::try_from(v).ok()),
            content_rating: info
                .content_rating
                .as_deref()
                .filter(|v| !v.trim().is_empty()),
        },
    )
    .await?;
    let tags = repo::upsert_tags(&state.db, &info.tags).await?;
    let tag_ids: Vec<i64> = tags.into_iter().map(|tag| tag.id).collect();
    repo::replace_item_tags(&state.db, item.id, &tag_ids).await?;
    Ok(())
}

async fn run_remote_download(state: Arc<AppState>, source_id: String, id: String) -> Result<()> {
    publish_remote_download_progress(
        &state,
        &source_id,
        &id,
        pb::RemoteDownloadState::Pending,
        "",
    );

    let info = {
        let sm = state.source_manager.lock().await;
        sm.call_download(&source_id, &id).await?
    };
    if info.url.trim().is_empty() {
        return Err(anyhow!("download url is empty"));
    }

    let dir = remote_content_dir(&source_id);
    tokio::fs::create_dir_all(&dir).await?;

    let filename = safe_remote_filename(&info.filename, &id);
    let target = dir.join(filename);
    publish_remote_download_progress(
        &state,
        &source_id,
        &id,
        pb::RemoteDownloadState::Downloading,
        "",
    );
    download_remote_file(&info.url, &target).await?;
    write_remote_sidecar(&target, &info).await?;
    upsert_remote_download(&state, &source_id, &dir, &target, &info).await?;
    control::notify_wallpaper_db_changed(&state, 1).await;
    publish_remote_download_progress(&state, &source_id, &id, pb::RemoteDownloadState::Done, "");
    Ok(())
}

async fn dispatch(state: &Arc<AppState>, req: pb::Request) -> pb::Response {
    let rid = req.request_id;
    build_response(rid, dispatch_inner(state, req).await)
}

async fn dispatch_inner(
    state: &Arc<AppState>,
    req: pb::Request,
) -> Result<pb::response::Payload, Error> {
    let payload = req
        .payload
        .ok_or(Error::UnexpectedPayload("empty request payload"))?;

    use pb::request::Payload as Req;
    use pb::response::Payload as Res;

    Ok(match payload {
        Req::Health(_) => Res::Health(pb::HealthResponse {
            service: "waywallen".into(),
            state: "healthy".into(),
        }),

        Req::RendererSpawn(r) => {
            // Low-level RPC: caller hands in a single `metadata` map.
            // Treat it as both CLI extras and Init.settings for manual use.
            let mut settings = r.metadata.clone();
            if r.fps != 0 {
                settings.insert("fps".to_string(), r.fps.to_string());
            }
            let spawn_req = renderer_manager::SpawnRequest {
                wp_type: if r.wp_type.is_empty() {
                    "scene".into()
                } else {
                    r.wp_type
                },
                extras: r.metadata,
                settings,
                test_pattern: false,
                renderer_name: None,
                user_properties_json: None,
            };
            // renderer_manager returns typed spawn errors directly.
            let id = state.renderer_manager.spawn(spawn_req).await?;
            if let Some(handle) = state.renderer_manager.get(&id).await {
                state.router.register_renderer(handle).await;
            }
            Res::RendererSpawn(pb::RendererSpawnResponse { renderer_id: id })
        }

        Req::RendererList(_) => {
            let ids = state.renderer_manager.list().await;
            let mut instances = Vec::with_capacity(ids.len());
            for id in &ids {
                let (name, pid, drm_render_major, drm_render_minor, texture_width, texture_height) =
                    match state.renderer_manager.get(id).await {
                        Some(h) => {
                            let (tw, th) = h.texture_size();
                            (
                                h.name.clone(),
                                h.pid.unwrap_or(0),
                                h.gpu.major,
                                h.gpu.minor,
                                tw,
                                th,
                            )
                        }
                        None => (String::new(), 0, 0, 0, 0, 0),
                    };
                // fps now lives in the reconciled plugin settings store.
                let fps: u32 = state
                    .settings
                    .plugin(&name)
                    .and_then(|kv| kv.get("fps").and_then(|v| v.parse().ok()))
                    .unwrap_or(0);
                let status = if state.router.is_paused(id).await {
                    "paused"
                } else {
                    "playing"
                };
                instances.push(pb::RendererInstance {
                    renderer_id: id.clone(),
                    fps,
                    status: status.into(),
                    name,
                    pid,
                    drm_render_major,
                    drm_render_minor,
                    texture_width,
                    texture_height,
                });
            }
            Res::RendererList(pb::RendererListResponse {
                renderers: ids,
                instances,
            })
        }

        Req::RendererPlay(r) => {
            state
                .renderer_manager
                .send_control(&r.renderer_id, ControlMsg::Play)
                .await?;
            Res::RendererPlay(pb::Empty {})
        }

        Req::RendererPause(r) => {
            state
                .renderer_manager
                .send_control(&r.renderer_id, ControlMsg::Pause)
                .await?;
            Res::RendererPause(pb::Empty {})
        }

        Req::RendererMouse(r) => {
            // Subscription-gated: skipped silently when the renderer's
            // manifest doesn't declare events = ["pointer"].
            state
                .renderer_manager
                .send_pointer_motion(&r.renderer_id, r.x as f32, r.y as f32, 0, 0)
                .await?;
            Res::RendererMouse(pb::Empty {})
        }

        Req::RendererFps(r) => {
            state
                .renderer_manager
                .send_control(&r.renderer_id, ControlMsg::SetFps { fps: r.fps })
                .await?;
            Res::RendererFps(pb::Empty {})
        }

        Req::RendererKill(r) => {
            state.router.unregister_renderer(&r.renderer_id).await;
            state.renderer_manager.kill(&r.renderer_id).await?;
            Res::RendererKill(pb::Empty {})
        }

        Req::RendererPluginList(_) => {
            let registry = state.renderer_manager.registry();
            // Renderer version = owning plugin's version, by plugin_id.
            let plugin_versions: std::collections::HashMap<&str, &str> = state
                .plugins
                .iter()
                .map(|p| (p.id.as_str(), p.version.as_str()))
                .collect();
            let renderers = registry
                .all_renderers()
                .iter()
                .map(|def| {
                    renderer_def_to_pb(
                        def,
                        plugin_versions
                            .get(def.plugin_id.as_str())
                            .copied()
                            .unwrap_or(""),
                    )
                })
                .collect();
            // `supported_types` comes from a HashMap; sort so the UI's
            // type chips/menus keep a stable alphabetical order.
            let mut supported_types: Vec<_> =
                registry.supported_types().into_iter().cloned().collect();
            supported_types.sort();
            Res::RendererPluginList(pb::RendererPluginListResponse {
                renderers,
                supported_types,
            })
        }

        Req::PluginList(_) => {
            // Plugin-centric view: each installable plugin package with the
            // renderer components it provides (looked up by plugin_id).
            let registry = state.renderer_manager.registry();
            let all = registry.all_renderers();
            let plugins = state
                .plugins
                .iter()
                .map(|pkg| {
                    let renderers = all
                        .iter()
                        .filter(|def| def.plugin_id == pkg.id)
                        .map(|def| renderer_def_to_pb(def, &pkg.version))
                        .collect();
                    pb::PluginInfo {
                        id: pkg.id.clone(),
                        name: pkg.name.clone(),
                        version: pkg.version.clone(),
                        has_source: pkg.has_entry,
                        renderers,
                        system: pkg.system,
                    }
                })
                .collect();
            Res::PluginList(pb::PluginListResponse { plugins })
        }

        Req::TagList(_) => {
            let tags = repo::list_tags(&state.db)
                .await?
                .into_iter()
                .map(|t| t.name)
                .collect();
            Res::TagList(pb::TagListResponse { tags })
        }

        Req::ContentRatingList(_) => {
            let ratings = repo::list_content_ratings(&state.db).await?;
            Res::ContentRatingList(pb::ContentRatingListResponse { ratings })
        }

        Req::WallpaperList(r) => {
            log::info!(
                "WallpaperList: page={} page_size={} wp_type={:?} filters={} search={:?}",
                r.page,
                r.page_size,
                r.wp_type,
                r.filters.len(),
                r.search_text
            );
            // Entries come straight from the DB (the read source of
            // truth), fully populated — no in-memory snapshot.
            let all_entries = repo::load_entries(&state.db).await?;

            let mut raw_entries: Vec<&crate::wallpaper::types::WallpaperEntry> = all_entries
                .iter()
                .filter(|e| r.wp_type.is_empty() || e.wp_type == r.wp_type)
                .collect();
            if !r.skip_types.is_empty() {
                raw_entries.retain(|e| !r.skip_types.iter().any(|t| t == &e.wp_type));
            }

            // Inject free-text search as its own filter group so it ANDs
            // with any user-authored rule graph.
            let mut filters_with_search = r.filters.clone();
            let search_text = r.search_text.trim();
            if !search_text.is_empty() {
                let next_group = filters_with_search
                    .iter()
                    .map(|f| f.group)
                    .max()
                    .map(|g| g + 1)
                    .unwrap_or(0);
                filters_with_search.push(pb::WallpaperFilterRule {
                    r#type: pb::WallpaperFilterType::Name as i32,
                    group: next_group,
                    payload: Some(pb::wallpaper_filter_rule::Payload::StringFilter(
                        pb::WallpaperStringFilter {
                            value: search_text.to_owned(),
                            condition: pb::StringCondition::Contains as i32,
                        },
                    )),
                });
            }

            // Quick tag filter: keep only wallpapers having any of the
            // selected tags, AND-ed in via its own fresh group.
            if !r.filter_tags.is_empty() {
                let next_group = filters_with_search
                    .iter()
                    .map(|f| f.group)
                    .max()
                    .map(|g| g + 1)
                    .unwrap_or(0);
                filters_with_search.push(pb::WallpaperFilterRule {
                    r#type: pb::WallpaperFilterType::Tag as i32,
                    group: next_group,
                    payload: Some(pb::wallpaper_filter_rule::Payload::TagFilter(
                        pb::WallpaperTagFilter {
                            values: r.filter_tags.clone(),
                            condition: pb::StringCondition::Is as i32,
                        },
                    )),
                });
            }

            // Quick content-rating toggles: drop the unselected ratings,
            // each as its own AND-ed group.
            for rating in &r.skip_content_ratings {
                let next_group = filters_with_search
                    .iter()
                    .map(|f| f.group)
                    .max()
                    .map(|g| g + 1)
                    .unwrap_or(0);
                filters_with_search.push(pb::WallpaperFilterRule {
                    r#type: pb::WallpaperFilterType::ContentRating as i32,
                    group: next_group,
                    payload: Some(pb::wallpaper_filter_rule::Payload::StringFilter(
                        pb::WallpaperStringFilter {
                            value: rating.clone(),
                            condition: pb::StringCondition::IsNot as i32,
                        },
                    )),
                });
            }

            let matched_keys = if filters_with_search.is_empty() {
                None
            } else {
                Some(
                    repo::list_item_keys_by_wallpaper_filters(
                        &state.db,
                        &filters_with_search,
                        &r.filter_logics,
                    )
                    .await?
                    .into_iter()
                    .collect::<std::collections::HashSet<(String, String)>>(),
                )
            };

            let mut filtered_entries: Vec<&crate::wallpaper::types::WallpaperEntry> =
                if let Some(matched_keys) = matched_keys.as_ref() {
                    raw_entries
                        .into_iter()
                        .filter(|e| {
                            crate::model::sync::relative_under_root(&e.library_root, &e.resource)
                                .map(|rel| matched_keys.contains(&(e.library_root.clone(), rel)))
                                .unwrap_or(false)
                        })
                        .collect()
                } else {
                    raw_entries
                };

            apply_wallpaper_sorts(&mut filtered_entries, &r.sorts);

            let total = filtered_entries.len() as u32;
            let page_size = r.page_size as usize;
            let (offset, take) = if page_size == 0 {
                (0usize, filtered_entries.len())
            } else {
                ((r.page as usize) * page_size, page_size)
            };
            log::info!("WallpaperList: total={total} returning offset={offset} take={take}");

            let page_entries: Vec<&crate::wallpaper::types::WallpaperEntry> = filtered_entries
                .into_iter()
                .skip(offset)
                .take(take)
                .collect();

            // Batch-load tags for just the items on this page (avoid
            // an N+1 round-trip when paginating large libraries).
            let page_item_ids: Vec<i64> = page_entries.iter().map(|e| e.item_id).collect();
            let tag_map = repo::list_tags_for_items(&state.db, &page_item_ids).await?;

            // WallpaperList skips property schema/overrides; WallpaperGet
            // loads those on demand per item.
            let entries: Vec<pb::WallpaperEntry> = page_entries
                .into_iter()
                .map(|e| {
                    let tags = tag_map.get(&e.item_id).cloned().unwrap_or_default();
                    entry_to_pb(e, tags, String::new(), String::new(), None)
                })
                .collect();

            Res::WallpaperList(pb::WallpaperListResponse {
                wallpapers: entries,
                count: total,
            })
        }

        Req::WallpaperGet(r) => {
            let entry = match r.wallpaper_id.parse::<i64>() {
                Ok(iid) => repo::get_entry(&state.db, iid).await?,
                Err(_) => None,
            };
            let entry = entry.ok_or_else(|| Error::WallpaperNotFound(r.wallpaper_id.clone()))?;
            let tags = entry.tags.clone();
            // Source plugin owns the property schema; empty string means
            // the plugin exposes no properties for this item.
            let schema = state
                .source_manager
                .lock()
                .await
                .call_properties(&entry.plugin_name, &entry)
                .await
                .ok()
                .flatten()
                .map(|schema| dedupe_predefined_schema(&schema))
                .unwrap_or_default();
            let overrides = repo::get_user_property_overrides_raw(&state.db, entry.item_id)
                .await?
                .unwrap_or_default();
            let layout_override =
                repo::get_wallpaper_layout_override_with_legacy(&state.db, entry.item_id).await?;

            Res::WallpaperGet(pb::WallpaperGetResponse {
                entry: Some(entry_to_pb(
                    &entry,
                    tags,
                    schema,
                    overrides,
                    layout_override,
                )),
            })
        }

        Req::WallpaperPropertySet(r) => {
            let entry = match r.wallpaper_id.parse::<i64>() {
                Ok(iid) => repo::get_entry(&state.db, iid).await?,
                Err(_) => None,
            };
            let entry = entry.ok_or_else(|| Error::WallpaperNotFound(r.wallpaper_id.clone()))?;
            // Persist to DB.
            repo::merge_user_property_overrides(
                &state.db,
                entry.item_id,
                &[(r.key.clone(), r.value.clone())],
            )
            .await?;
            let persist_tag = format!("item={}", entry.item_id);
            let live_renderer = state
                .renderer_manager
                .find_by_resource(&entry.resource)
                .await;
            let push_tag = if is_daemon_display_property_key(&r.key) {
                if let Some(h) = live_renderer {
                    let (_, wallpaper_layout_override) =
                        repo::get_wallpaper_render_properties(&state.db, entry.item_id).await?;
                    let id = h.id.clone();
                    state
                        .router
                        .set_renderer_wallpaper_layout_override(&id, wallpaper_layout_override)
                        .await;
                    format!("display-layout={id}")
                } else {
                    String::from("offline")
                }
            } else {
                // Push live; unknown keys are left for renderer-side property
                // dispatch to accept or ignore.
                if let Some(h) = live_renderer {
                    let value = if r.value.is_empty() {
                        let schema = state
                            .source_manager
                            .lock()
                            .await
                            .call_properties(&entry.plugin_name, &entry)
                            .await
                            .ok()
                            .flatten();
                        schema
                            .as_deref()
                            .and_then(|schema| user_property_default_wire_value(schema, &r.key))
                            .unwrap_or_else(|| {
                                log::warn!(
                                    "WallpaperPropertySet: reset {} on {} has no default value",
                                    r.key,
                                    r.wallpaper_id
                                );
                                r.value.clone()
                            })
                    } else {
                        r.value.clone()
                    };
                    let kv = vec![(r.key.clone(), value)];
                    let id = h.id.clone();
                    state
                        .renderer_manager
                        .send_control(&h.id, ControlMsg::SettingChanged { settings: kv })
                        .await
                        .map_err(|e| {
                            Error::Internal(anyhow::anyhow!(
                                "send setting_changed to renderer {}: {e}",
                                h.id
                            ))
                        })?;
                    format!("renderer={id}")
                } else {
                    String::from("offline")
                }
            };
            log::info!(
                "WallpaperPropertySet: {}={} on {} persist={} push={}",
                r.key,
                r.value,
                r.wallpaper_id,
                persist_tag,
                push_tag
            );
            Res::WallpaperPropertySet(pb::WallpaperPropertySetResponse {})
        }

        Req::WallpaperLayoutSet(r) => {
            let entry = match r.wallpaper_id.parse::<i64>() {
                Ok(iid) => repo::get_entry(&state.db, iid).await?,
                Err(_) => None,
            };
            let entry = entry.ok_or_else(|| Error::WallpaperNotFound(r.wallpaper_id.clone()))?;
            let layout = if r.clear {
                None
            } else {
                let Some(layout) = r.layout.as_ref() else {
                    return Err(Error::InvalidArgument(
                        "wallpaper_layout_set requires layout unless clear=true".to_string(),
                    ));
                };
                Some(resolved_layout_from_pb(layout))
            };
            repo::set_wallpaper_layout_override(&state.db, entry.item_id, layout).await?;
            log::info!(
                "WallpaperLayoutSet: wallpaper={} clear={} live_renderer_candidate={}",
                r.wallpaper_id,
                r.clear,
                entry.resource
            );

            let live_renderer = state
                .renderer_manager
                .find_by_resource(&entry.resource)
                .await;
            if let Some(h) = live_renderer {
                let override_layout = layout
                    .map(WallpaperLayoutOverride::from_resolved)
                    .unwrap_or_default();
                state
                    .router
                    .set_renderer_wallpaper_layout_override(&h.id, override_layout)
                    .await;
            }

            let layout_override = layout.map(WallpaperLayoutOverride::from_resolved);
            Res::WallpaperLayoutSet(pb::WallpaperLayoutSetResponse {
                entry: Some(entry_to_pb(
                    &entry,
                    entry.tags.clone(),
                    String::new(),
                    String::new(),
                    layout_override,
                )),
            })
        }

        Req::WallpaperScan(_) => {
            // Fire-and-forget: kick the rescan onto the TaskManager and
            // return immediately; completion arrives via server events.
            let scan_state = state.clone();
            state.tasks.spawn_async_unique(
                tasks::TaskKind::Generic,
                "scan/refresh",
                "scan/refresh",
                async move {
                    control::refresh_sources(&scan_state)
                        .await
                        .map(|_| ())
                        .map_err(anyhow::Error::from)
                },
            );
            Res::WallpaperScan(pb::WallpaperScanResponse { count: 0 })
        }

        Req::SourceList(_) => {
            let plugins = state.source_plugins.read().await;
            let sources = plugins
                .iter()
                .cloned()
                .map(|p| pb::SourcePluginInfo {
                    name: p.name,
                    types: p.types,
                    version: p.version,
                    library_label: p.library_label,
                    library_hint: p.library_hint,
                })
                .collect();
            Res::SourceList(pb::SourceListResponse { sources })
        }

        Req::DisplayList(_) => {
            let snap = state.router.snapshot_displays().await;
            let displays = snap
                .into_iter()
                .map(|d| display_snapshot_to_pb(d, &state.settings))
                .collect();
            Res::DisplayList(pb::DisplayListResponse { displays })
        }

        Req::GpuList(_) => {
            let gpus = state.gpus.iter().map(gpu_info_to_pb).collect();
            Res::GpuList(pb::GpuListResponse { gpus })
        }

        Req::PluginInstall(r) => {
            // Extraction is blocking filesystem work; keep it off the async
            // dispatch worker. Renderer components load on next daemon start.
            let zip_path = r.zip_path.clone();
            let plugin_id = tokio::task::spawn_blocking(move || {
                crate::plugin::installer::install_zip(&zip_path)
            })
            .await
            .map_err(|e| Error::Internal(anyhow::anyhow!("install join: {e}")))??;
            Res::PluginInstall(pb::PluginInstallResponse {
                plugin_id,
                needs_restart: true,
            })
        }

        Req::DisplayLayoutSet(r) => {
            let new_fillmode = if r.clear_fillmode {
                None
            } else {
                r.r#override
                    .as_ref()
                    .filter(|o| o.fillmode_set)
                    .and_then(|o| fillmode_from_pb(o.fillmode))
            };
            let new_align = if r.clear_align {
                None
            } else {
                r.r#override
                    .as_ref()
                    .filter(|o| o.align_set)
                    .and_then(|o| align_from_pb(o.align))
            };
            let new_location = if r.clear_location || r.clear_align {
                None
            } else {
                r.r#override
                    .as_ref()
                    .filter(|o| o.location_set)
                    .map(|o| location_from_pb(o.location_x, o.location_y))
                    .or_else(|| new_align.map(crate::display::layout::Location::from_align))
            };
            let new_rotation = if r.clear_rotation {
                None
            } else {
                r.r#override
                    .as_ref()
                    .filter(|o| o.rotation_set)
                    .and_then(|o| rotation_from_pb(o.rotation))
            };
            let target_id = state
                .router
                .set_display_layout(
                    (r.display_id != 0).then_some(r.display_id),
                    r.name.clone(),
                    new_fillmode,
                    new_location,
                    new_align,
                    new_rotation,
                    r.clear_fillmode,
                    r.clear_align || r.clear_location,
                    r.clear_rotation,
                )
                .await;
            let display = match target_id {
                Some(id) => state
                    .router
                    .snapshot_display(id)
                    .await
                    .map(|d| display_snapshot_to_pb(d, &state.settings)),
                None => None,
            };
            Res::DisplayLayoutSet(pb::DisplayLayoutSetResponse { display })
        }

        Req::DisplayRename(r) => {
            let new_alias = if r.clear || r.alias.trim().is_empty() {
                None
            } else {
                Some(r.alias.clone())
            };
            let target_id = state
                .router
                .set_display_alias(
                    (r.display_id != 0).then_some(r.display_id),
                    r.name.clone(),
                    new_alias,
                    r.clear,
                )
                .await;
            let display = match target_id {
                Some(id) => state
                    .router
                    .snapshot_display(id)
                    .await
                    .map(|d| display_snapshot_to_pb(d, &state.settings)),
                None => None,
            };
            Res::DisplayRename(pb::DisplayRenameResponse { display })
        }

        Req::RemoteAvailability(_) => {
            let sources = {
                let sm = state.source_manager.lock().await;
                sm.discover_sources()?
            };
            let default_source_id = sources
                .first()
                .map(|s| s.plugin_id.clone())
                .unwrap_or_default();
            Res::RemoteAvailability(pb::RemoteAvailabilityResponse {
                sources: sources
                    .into_iter()
                    .map(|s| pb::RemoteSourceInfo {
                        id: s.plugin_id.clone(),
                        name: s.name,
                        supports_search: s.supports_search,
                        sorts: s
                            .sorts
                            .into_iter()
                            .map(|sort| pb::RemoteSortOption {
                                key: sort.key,
                                label: sort.label,
                            })
                            .collect(),
                        tags: s.tags,
                        content_dir: remote_content_dir(&s.plugin_id)
                            .to_string_lossy()
                            .to_string(),
                    })
                    .collect(),
                default_source_id,
            })
        }

        Req::RemoteSearch(r) => {
            let source_id = match resolve_remote_source_id(state, &r.source_id).await {
                Ok(v) => v,
                Err(e) => {
                    return Ok(Res::RemoteSearch(pb::RemoteSearchResponse {
                        items: Vec::new(),
                        has_more: false,
                        error: e.to_string(),
                    }));
                }
            };
            let sort_key = if r.sort_key.trim().is_empty() {
                let sm = state.source_manager.lock().await;
                sm.discover_sources()?
                    .into_iter()
                    .find(|s| s.plugin_id == source_id)
                    .and_then(|s| s.sorts.into_iter().next())
                    .map(|s| s.key)
                    .unwrap_or_default()
            } else {
                r.sort_key.clone()
            };
            let result = {
                let sm = state.source_manager.lock().await;
                sm.call_discover(&source_id, &r.query, &sort_key, r.page, &r.required_tags)
                    .await
            };
            match result {
                Ok(result) => {
                    let mut items = Vec::with_capacity(result.items.len());
                    for item in result.items {
                        let installed =
                            repo::has_item_by_plugin_external_id(&state.db, &source_id, &item.id)
                                .await?;
                        items.push(pb::RemoteItem {
                            id: item.id,
                            title: item.title,
                            preview_url: item.preview_url,
                            author: item.author,
                            installed,
                            source_id: source_id.clone(),
                        });
                    }
                    Res::RemoteSearch(pb::RemoteSearchResponse {
                        items,
                        has_more: result.has_more,
                        error: String::new(),
                    })
                }
                Err(e) => Res::RemoteSearch(pb::RemoteSearchResponse {
                    items: Vec::new(),
                    has_more: false,
                    error: e.to_string(),
                }),
            }
        }

        Req::RemoteDownload(r) => {
            let source_id = match resolve_remote_source_id(state, &r.source_id).await {
                Ok(v) => v,
                Err(e) => {
                    return Ok(Res::RemoteDownload(pb::RemoteDownloadResponse {
                        accepted: false,
                        error: e.to_string(),
                    }));
                }
            };
            if r.id.trim().is_empty() {
                return Ok(Res::RemoteDownload(pb::RemoteDownloadResponse {
                    accepted: false,
                    error: "remote id is empty".into(),
                }));
            }
            let task_state = state.clone();
            let task_source_id = source_id.clone();
            let task_id = r.id.clone();
            state.tasks.spawn_async_unique(
                tasks::TaskKind::Generic,
                format!("remote/download/{task_source_id}/{task_id}"),
                format!("remote/download {task_source_id}:{task_id}"),
                async move {
                    let result = run_remote_download(
                        task_state.clone(),
                        task_source_id.clone(),
                        task_id.clone(),
                    )
                    .await;
                    if let Err(e) = &result {
                        publish_remote_download_progress(
                            &task_state,
                            &task_source_id,
                            &task_id,
                            pb::RemoteDownloadState::Error,
                            e.to_string(),
                        );
                    }
                    result
                },
            );
            Res::RemoteDownload(pb::RemoteDownloadResponse {
                accepted: true,
                error: String::new(),
            })
        }

        Req::RemoteUninstall(r) => {
            let source_id = match resolve_remote_source_id(state, &r.source_id).await {
                Ok(v) => v,
                Err(e) => {
                    return Ok(Res::RemoteUninstall(pb::RemoteUninstallResponse {
                        removed: false,
                        error: e.to_string(),
                    }));
                }
            };
            let rows = repo::list_items_by_plugin_external_id(&state.db, &source_id, &r.id).await?;
            if rows.is_empty() {
                Res::RemoteUninstall(pb::RemoteUninstallResponse {
                    removed: false,
                    error: "remote item is not installed".into(),
                })
            } else {
                for (item, lib) in rows {
                    let path = Path::new(&lib.path).join(&item.path);
                    match tokio::fs::remove_file(&path).await {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        Err(e) => return Err(Error::Io(e)),
                    }
                    let sidecar = sidecar_path(&path);
                    match tokio::fs::remove_file(&sidecar).await {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        Err(e) => return Err(Error::Io(e)),
                    }
                    repo::delete_item(&state.db, item.id).await?;
                }
                control::notify_wallpaper_db_changed(state, 0).await;
                Res::RemoteUninstall(pb::RemoteUninstallResponse {
                    removed: true,
                    error: String::new(),
                })
            }
        }

        Req::RemoteDetails(r) => {
            let source_id = match resolve_remote_source_id(state, &r.source_id).await {
                Ok(v) => v,
                Err(e) => {
                    return Ok(Res::RemoteDetails(pb::RemoteDetailsResponse {
                        description: String::new(),
                        size: String::new(),
                        tags: Vec::new(),
                        error: e.to_string(),
                    }));
                }
            };
            let result = {
                let sm = state.source_manager.lock().await;
                sm.call_details(&source_id, &r.id).await
            };
            match result {
                Ok(details) => Res::RemoteDetails(pb::RemoteDetailsResponse {
                    description: details.description,
                    size: details.size,
                    tags: details.tags,
                    error: String::new(),
                }),
                Err(e) => Res::RemoteDetails(pb::RemoteDetailsResponse {
                    description: String::new(),
                    size: String::new(),
                    tags: Vec::new(),
                    error: e.to_string(),
                }),
            }
        }

        Req::WallpaperApply(r) => {
            let entry = match r.wallpaper_id.parse::<i64>() {
                Ok(iid) => repo::get_entry(&state.db, iid).await?,
                Err(_) => None,
            };
            let entry = entry.ok_or_else(|| Error::WallpaperNotFound(r.wallpaper_id.clone()))?;
            let _ = crate::playlist::engine::Engine::deactivate(&state, &r.display_ids).await;
            if state.router.display_count().await == 0 {
                return Err(Error::NoDisplayRegistered);
            }
            // Empty renderer_name uses priority resolve; explicit names must
            // resolve to a renderer that supports this wallpaper type.
            let registry = state.renderer_manager.registry();
            let plugin_name: String = if r.renderer_name.is_empty() {
                registry
                    .resolve(&entry.wp_type)
                    .map(|def| def.name.clone())
                    .ok_or_else(|| Error::NoRendererForType(entry.wp_type.clone()))?
            } else {
                let def = registry
                    .resolve_by_name(&r.renderer_name)
                    .ok_or_else(|| Error::RendererNotFound(r.renderer_name.clone()))?;
                if !def.types.iter().any(|t| t == &entry.wp_type) {
                    return Err(Error::RendererTypeMismatch {
                        renderer: r.renderer_name.clone(),
                        ty: entry.wp_type.clone(),
                    });
                }
                def.name.clone()
            };
            // Render-target size is the renderer's decision from content
            // native size and plugin settings.
            let plugin_kv = state.settings.plugin(&plugin_name).unwrap_or_default();

            // Renderer-owned per-item user-property overrides ride as
            // a separate JSON payload in `Init.user_properties`.
            let (user_properties_json, wallpaper_layout_override) =
                repo::get_wallpaper_render_properties(&state.db, entry.item_id).await?;

            // Source plugin extras supply canonical path and allowlisted CLI
            // argv for the renderer subprocess.
            let extras = state
                .source_manager
                .lock()
                .await
                .call_extras(&entry.plugin_name, &entry)
                .await?;

            let spawn_req = renderer_manager::SpawnRequest {
                wp_type: entry.wp_type.clone(),
                extras,
                settings: plugin_kv,
                test_pattern: false,
                // Pin reuse and spawn to the explicit pick when requested;
                // otherwise let the manager resolve by priority.
                renderer_name: if r.renderer_name.is_empty() {
                    None
                } else {
                    Some(plugin_name.clone())
                },
                user_properties_json,
            };

            // Reuse a live renderer whose spawn identity matches.
            // Settings changes are pushed by SettingsSet, not by apply.
            let renderer_id = match state.renderer_manager.find_reusable(&spawn_req).await {
                Some(existing_id) => {
                    log::info!(
                        "wallpaper_apply: reusing renderer {existing_id} for wallpaper {}",
                        entry.item_id
                    );
                    existing_id
                }
                None => {
                    // No reuse — a fresh renderer is about to spawn.
                    // Stop fully replaced renderers first to cap peak GPU use.
                    let target: Option<&[u64]> = if r.display_ids.is_empty() {
                        None
                    } else {
                        Some(&r.display_ids)
                    };
                    let to_stop = state.router.renderers_fully_replaced_by(target).await;
                    if !to_stop.is_empty() {
                        log::info!(
                            "wallpaper_apply: stopping {} fully-replaced renderer(s) before spawn: {:?}",
                            to_stop.len(),
                            to_stop,
                        );
                        // Orderly shutdown unbinds displays before graceful
                        // producer shutdown.
                        state
                            .router
                            .stop_renderers_orderly(&to_stop, std::time::Duration::from_secs(1))
                            .await;
                    }
                    let new_id = state.renderer_manager.spawn(spawn_req).await?;
                    if let Some(handle) = state.renderer_manager.get(&new_id).await {
                        state.router.register_renderer(handle).await;
                    }
                    new_id
                }
            };

            state
                .router
                .set_renderer_wallpaper_layout_override(&renderer_id, wallpaper_layout_override)
                .await;

            if r.display_ids.is_empty() {
                state.router.relink_all_displays_to(&renderer_id).await;
            } else {
                state
                    .router
                    .relink_displays_to(&r.display_ids, &renderer_id)
                    .await;
            }

            if let Err(e) = state
                .renderer_manager
                .wait_for_first_frame(&renderer_id, APPLY_FIRST_FRAME_TIMEOUT)
                .await
            {
                state.router.unregister_renderer(&renderer_id).await;
                let _ = state.renderer_manager.kill(&renderer_id).await;
                return Err(e);
            }

            // Mirror control::apply_wallpaper_by_id by pinning the playlist
            // cursor to the applied wallpaper.
            {
                let mut q = state.queue.lock().await;
                q.current = Some(entry.item_id.to_string());
                if !entry.library_root.is_empty() {
                    if let Some(rel) =
                        crate::queue::relative_under_root(&entry.library_root, &entry.resource)
                    {
                        if let Ok(Some(it)) = crate::model::repo::find_item_by_library_path(
                            &state.db,
                            &entry.library_root,
                            &rel,
                        )
                        .await
                        {
                            q.last_db_id = Some(it.id);
                        }
                    }
                }
            }
            // Per-display: empty display_ids means "all currently
            // registered displays" (matches the relink branch above).
            let target_ids: Vec<crate::scheduler::DisplayId> = if r.display_ids.is_empty() {
                state
                    .router
                    .snapshot_displays()
                    .await
                    .into_iter()
                    .map(|d| d.id)
                    .collect()
            } else {
                r.display_ids.clone()
            };
            let keys = state.router.display_settings_keys(&target_ids).await;
            let wp_id = entry.item_id.to_string();
            state.settings.update(|s| {
                for (_did, key) in &keys {
                    let prefs = s.displays.entry(key.clone()).or_default();
                    prefs.last_wallpaper = Some(wp_id.clone());
                }
                s.global.last_wallpaper = Some(wp_id);
            });
            state.settings.flush_now().await;
            // Reset the rotator deadline so a manual apply gets the
            // full quiet window before the next auto tick.
            state.rotation.kick();

            Res::WallpaperApply(pb::WallpaperApplyResponse {
                renderer_id,
                wallpaper_id: entry.item_id.to_string(),
                wp_type: entry.wp_type,
                name: entry.name,
            })
        }

        Req::WallpaperApplyViaPortal(r) => {
            let res = crate::control::apply_wallpaper_via_portal(state, &r.wallpaper_id).await?;
            Res::WallpaperApplyViaPortal(pb::WallpaperApplyViaPortalResponse {
                wallpaper_id: res.wallpaper_id,
                uri: res.uri,
            })
        }

        Req::SettingsGet(_) => {
            let snap = state.settings.snapshot();
            Res::SettingsGet(pb::SettingsGetResponse {
                global: Some(global_to_pb(&snap.global)),
                plugins: snap
                    .plugins
                    .into_iter()
                    .map(|(k, v)| (k, pb::PluginSettings { values: v }))
                    .collect(),
            })
        }

        Req::SettingsSet(r) => {
            // Full replace. Missing `global` falls back to current
            // values so callers can update only plugin settings.
            let mut new_plugins: std::collections::HashMap<
                String,
                std::collections::HashMap<String, String>,
            > = r.plugins.into_iter().map(|(k, v)| (k, v.values)).collect();

            // Schema validation up-front. Reject the entire RPC if any
            // declared key fails type, bounds, or choices.
            {
                let registry = state.renderer_manager.registry();
                for (plugin_name, kv) in new_plugins.iter_mut() {
                    let Some(def) = registry
                        .all_renderers()
                        .into_iter()
                        .find(|d| &d.name == plugin_name)
                    else {
                        continue;
                    };
                    if def.settings.is_empty() {
                        continue;
                    }
                    for (k, v) in kv.iter_mut() {
                        let Some(schema) = def.settings.get(k) else {
                            continue;
                        };
                        let coerced =
                            crate::plugin::renderer_registry::coerce_and_validate(k, v, schema)
                                .map_err(|e| {
                                    Error::SettingsValidationFailed(format!("{plugin_name}.{e}"))
                                })?;
                        *v = coerced;
                    }
                }
            }

            // Snapshot prior plugin settings to compute live-renderer deltas.
            let previous_plugins = state.settings.snapshot().plugins;
            let previous_filter = state.settings.snapshot().global.wallpaper_filter;
            // Snapshot pre-mutation layout defaults so we know whether
            // to re-sync display set_configs after the write.
            let prev_layout = state.settings.snapshot().global.layout.clone();
            let prev_queue_mode = state.settings.snapshot().global.queue_mode.clone();
            let prev_rotation_secs = state.settings.snapshot().global.rotation_secs;
            state.settings.update(|s| {
                if let Some(g) = r.global.as_ref() {
                    s.global.wallpaper_filter = WallpaperFilterState::from_pb(
                        &g.wallpaper_filters,
                        &g.wallpaper_filter_logics,
                    );
                    s.global.wallpaper_sorts =
                        WallpaperSortRuleState::vec_from_pb(&g.wallpaper_sorts);
                    s.global.wallpaper_skip_types = g.wallpaper_skip_types.clone();
                    s.global.wallpaper_filter_tags = g.wallpaper_filter_tags.clone();
                    s.global.wallpaper_skip_content_ratings =
                        g.wallpaper_skip_content_ratings.clone();
                    if let Some(ld) = g.layout_defaults.as_ref() {
                        if let Some(fm) = fillmode_from_pb(ld.fillmode) {
                            s.global.layout.fillmode = fm;
                        }
                        if let Some(al) = align_from_pb(ld.align) {
                            s.global.layout.align = al;
                        }
                        if ld.location_set {
                            s.global.layout.location =
                                Some(location_from_pb(ld.location_x, ld.location_y));
                        }
                        if let Some(rt) = rotation_from_pb(ld.rotation) {
                            s.global.layout.rotation = rt;
                        }
                    }
                    if let Some(ap) = g.autopause.as_ref() {
                        s.global.autopause.mode = autopause_mode_from_pb(ap.mode);
                        s.global.autopause.resume_ms = ap.resume_ms;
                        s.global.autopause.pause_on_lock = ap.pause_on_lock;
                        s.global.autopause.pause_on_user_switch = ap.pause_on_user_switch;
                    }
                    if !g.queue_mode.is_empty() {
                        s.global.queue_mode = g.queue_mode.clone();
                    }
                    s.global.rotation_secs = g.rotation_secs;
                    // Hotkey bindings: empty map on the wire is the
                    // sentinel "don't touch". Non-empty replaces.
                    if !g.hotkey_bindings.is_empty() {
                        let raw: std::collections::BTreeMap<String, Vec<String>> =
                            g.hotkey_bindings
                                .iter()
                                .map(|(k, b)| (k.clone(), b.sequences.clone()))
                                .collect();
                        s.global.hotkeys.replace_from(raw);
                    }
                }
                s.plugins = new_plugins.clone();
            });
            let new_filter = state.settings.snapshot().global.wallpaper_filter.clone();
            if new_filter != previous_filter {
                log::debug!(
                    "wallpaper filter updated: old={:?}, new={:?}",
                    previous_filter,
                    new_filter
                );
                // Filter change invalidates the queue's shuffle round;
                // the next pick materializes the new candidate set.
                state.queue.lock().await.reset_shuffle_round();
            }
            let new_layout = state.settings.snapshot().global.layout.clone();
            if new_layout != prev_layout {
                state.router.resync_all_set_configs().await;
                // Push fresh DisplaySnapshot so subscribers see new
                // effective_layout values.
                let snap = state.router.snapshot_displays().await;
                state.router.emit_displays_replace_for_settings_change(snap);
            }
            // Hot-apply queue mode and rotation interval; autopause re-reads
            // settings on every window-state event.
            let new_queue_mode = state.settings.snapshot().global.queue_mode.clone();
            if new_queue_mode != prev_queue_mode {
                if let Some(m) = queue::state::Mode::from_str(&new_queue_mode) {
                    state.queue.lock().await.set_mode(m);
                }
            }
            let new_rotation_secs = state.settings.snapshot().global.rotation_secs;
            if new_rotation_secs != prev_rotation_secs {
                state.rotation.set_interval(new_rotation_secs);
            }
            // Hot-reload live renderers for plugins whose settings changed.
            let mut plugin_names_changed: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for (name, values) in &new_plugins {
                if previous_plugins.get(name) != Some(values) {
                    plugin_names_changed.insert(name.clone());
                }
            }
            for name in previous_plugins.keys() {
                if !new_plugins.contains_key(name) {
                    plugin_names_changed.insert(name.clone());
                }
            }
            // Collect hot-reload failures and report them after publishing
            // the persisted settings change.
            let mut apply_failures: Vec<String> = Vec::new();
            for plugin_name in plugin_names_changed {
                let def = state
                    .renderer_manager
                    .registry()
                    .all_renderers()
                    .into_iter()
                    .find(|d| d.name == plugin_name)
                    .cloned();
                let Some(def) = def else { continue };
                let new_kv = new_plugins.get(&plugin_name).cloned().unwrap_or_default();
                let old_kv = previous_plugins
                    .get(&plugin_name)
                    .cloned()
                    .unwrap_or_default();

                // Forward changed schema keys to live renderers of this
                // plugin; other keys apply on next spawn.
                let kv: Vec<(String, String)> = new_kv
                    .iter()
                    .filter(|(k, v)| def.settings.contains_key(*k) && old_kv.get(*k) != Some(v))
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect();
                if kv.is_empty() {
                    continue;
                }
                let ids = state.renderer_manager.list().await;
                for id in ids {
                    let Some(handle) = state.renderer_manager.get(&id).await else {
                        continue;
                    };
                    if handle.name != plugin_name {
                        continue;
                    }
                    if let Err(e) = state
                        .renderer_manager
                        .send_setting_changed(&id, kv.clone(), None)
                        .await
                    {
                        apply_failures.push(format!("{id} ({plugin_name}): {e}"));
                    }
                }
            }
            // Push the merged post-write state to all WS subscribers so
            // a second UI bound to the same daemon stays in sync.
            state.events.publish(GlobalEvent::SettingsChanged);
            if !apply_failures.is_empty() {
                return Err(Error::SettingsApplyFailed(format!(
                    "{} renderer(s): {}",
                    apply_failures.len(),
                    apply_failures.join("; ")
                )));
            }
            Res::SettingsSet(pb::Empty {})
        }

        Req::LibraryList(_) => {
            let snap = control::list_library_snapshots(&state.db).await;
            Res::LibraryList(pb::LibraryListResponse {
                libraries: snap.into_iter().map(library_instance_to_pb).collect(),
            })
        }

        Req::LibraryAdd(r) => {
            let plugin = repo::find_plugin_by_name(&state.db, &r.plugin_name)
                .await?
                .ok_or_else(|| Error::SourcePluginNotFound(r.plugin_name.clone()))?;
            let lib = repo::add_library(&state.db, plugin.id, &r.path).await?;
            let snap = LibrarySnapshot {
                id: lib.id,
                path: lib.path,
                plugin_name: r.plugin_name,
            };
            let added_path = snap.path.clone();
            state.router.upsert_library(snap);
            state.events.publish(GlobalEvent::LibrariesAdded {
                paths: vec![added_path],
            });
            // Rescan immediately so the new library reaches the DB and UI
            // without waiting for restart.
            let rescan_state = state.clone();
            state.tasks.spawn_async_unique(
                tasks::TaskKind::Generic,
                "scan/refresh",
                "scan/refresh-after-library-add",
                async move {
                    control::refresh_sources(&rescan_state)
                        .await
                        .map(|_| ())
                        .map_err(anyhow::Error::from)
                },
            );
            Res::LibraryAdd(pb::Empty {})
        }

        Req::LibraryAutoDetect(_) => {
            let added = control::auto_detect_libraries(&state).await?;
            Res::LibraryAutoDetect(pb::LibraryAutoDetectResponse {
                added: added.into_iter().map(library_instance_to_pb).collect(),
            })
        }

        Req::LibraryRemove(r) => {
            repo::remove_library(&state.db, r.id).await?;
            state.router.remove_library(r.id);
            let rescan_state = state.clone();
            state.tasks.spawn_async_unique(
                tasks::TaskKind::Generic,
                "scan/refresh",
                "scan/refresh-after-library-remove",
                async move {
                    control::refresh_sources(&rescan_state)
                        .await
                        .map(|_| ())
                        .map_err(anyhow::Error::from)
                },
            );
            Res::LibraryRemove(pb::Empty {})
        }

        // ---- queue status (user-saved playlists removed) -----------------
        Req::PlaylistList(_) => {
            let items = crate::playlist::repo::list(&state.db).await?;
            let mut playlists = Vec::with_capacity(items.len());
            for s in items {
                let entry_ids = crate::playlist::repo::entry_ids(&state.db, s.id)
                    .await?
                    .into_iter()
                    .map(|e| e.to_string())
                    .collect();
                playlists.push(pb::PlaylistSummary {
                    id: s.id,
                    name: s.name,
                    source_kind: "curated".into(),
                    mode: queue_mode_to_pb_playlist(s.mode),
                    interval_secs: s.interval_secs,
                    item_count: s.item_count,
                    entry_ids,
                });
            }
            Res::PlaylistList(pb::PlaylistListResponse { playlists })
        }

        Req::PlaylistCreate(r) => {
            let mode = pb_playlist_mode_to_queue(r.mode);
            let id = crate::playlist::repo::create(
                &state.db,
                &r.name,
                mode,
                r.interval_secs,
                tasks::now_ms(),
                &parse_entry_ids(&r.entry_ids),
            )
            .await?;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistCreate(pb::PlaylistCreateResponse { id })
        }

        Req::PlaylistDelete(r) => {
            crate::playlist::engine::Engine::deactivate_for_playlist(&state, r.id).await;
            crate::playlist::repo::delete(&state.db, r.id).await?;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistDelete(pb::Empty {})
        }

        Req::PlaylistRename(r) => {
            crate::playlist::repo::rename(&state.db, r.id, &r.name, tasks::now_ms()).await?;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistRename(pb::Empty {})
        }

        Req::PlaylistSetItems(r) => {
            crate::playlist::repo::set_items(
                &state.db,
                r.id,
                &parse_entry_ids(&r.entry_ids),
                tasks::now_ms(),
            )
            .await?;
            crate::playlist::engine::Engine::rebuild_for_playlist(&state, r.id).await;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistSetItems(pb::Empty {})
        }

        Req::PlaylistSetMode(r) => {
            let mode = pb_playlist_mode_to_queue(r.mode);
            crate::playlist::repo::set_mode(&state.db, r.id, mode, tasks::now_ms()).await?;
            crate::playlist::engine::Engine::rebuild_for_playlist(&state, r.id).await;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistSetMode(pb::Empty {})
        }

        Req::PlaylistSetInterval(r) => {
            crate::playlist::repo::set_interval(&state.db, r.id, r.interval_secs, tasks::now_ms())
                .await?;
            crate::playlist::engine::Engine::set_interval_for_playlist(
                &state,
                r.id,
                r.interval_secs,
            )
            .await;
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistSetInterval(pb::Empty {})
        }

        Req::PlaylistActivate(r) => {
            crate::playlist::engine::Engine::activate(&state, &r.display_ids, r.id).await?;
            if r.auto_attach {
                let id = r.id;
                state.settings.update(|s| {
                    s.global.auto_attach_playlist_id = Some(id);
                });
                state.settings.flush_now().await;
            }
            Res::PlaylistActivate(pb::Empty {})
        }

        Req::PlaylistDeactivate(r) => {
            crate::playlist::engine::Engine::deactivate(&state, &r.display_ids).await?;
            if r.clear_auto_attach > 0 {
                let id = r.clear_auto_attach;
                state.settings.update(|s| {
                    if s.global.auto_attach_playlist_id == Some(id) {
                        s.global.auto_attach_playlist_id = None;
                    }
                });
                state.settings.flush_now().await;
            }
            Res::PlaylistDeactivate(pb::Empty {})
        }

        Req::PlaylistStatus(_) => {
            let st = state.playlists.status().await;
            let auto_attach_id = state.settings.global().auto_attach_playlist_id.unwrap_or(0);
            Res::PlaylistStatus(pb::PlaylistStatusResponse {
                auto_attach_id,
                displays: st.into_iter().map(playlist_display_status_to_pb).collect(),
            })
        }

        Req::PlaylistJumpTo(r) => {
            crate::playlist::engine::Engine::jump_to(&state, r.id, &r.entry_id).await?;
            Res::PlaylistJumpTo(pb::Empty {})
        }
    })
}

fn parse_entry_ids(v: &[String]) -> Vec<i64> {
    v.iter().filter_map(|s| s.parse::<i64>().ok()).collect()
}

fn pb_playlist_mode_to_queue(m: i32) -> crate::queue::Mode {
    match m {
        2 => crate::queue::Mode::Shuffle,
        3 => crate::queue::Mode::Random,
        _ => crate::queue::Mode::Sequential,
    }
}

fn queue_mode_to_pb_playlist(m: crate::queue::Mode) -> i32 {
    match m {
        crate::queue::Mode::Sequential => 1,
        crate::queue::Mode::Shuffle => 2,
        crate::queue::Mode::Random => 3,
    }
}

/// Decode the proto enum integer into the internal `queue::Mode`.
/// `Unspecified` and unknown values default to Sequential.
fn pb_mode_to_enum(v: i32) -> queue::Mode {
    match pb::PlaylistMode::try_from(v).unwrap_or(pb::PlaylistMode::Unspecified) {
        pb::PlaylistMode::Shuffle => queue::Mode::Shuffle,
        pb::PlaylistMode::Random => queue::Mode::Random,
        _ => queue::Mode::Sequential,
    }
}

fn mode_str_to_pb(s: &str) -> pb::PlaylistMode {
    match queue::Mode::from_str(s) {
        Some(queue::Mode::Sequential) => pb::PlaylistMode::Sequential,
        Some(queue::Mode::Shuffle) => pb::PlaylistMode::Shuffle,
        Some(queue::Mode::Random) => pb::PlaylistMode::Random,
        None => pb::PlaylistMode::Unspecified,
    }
}

// ---------------------------------------------------------------------------
// Helpers

/// Encode a dispatch result onto the wire. Thin wrapper around
/// `Error::to_response` / `ok_response` from `crate::error`.
fn build_response(request_id: u64, result: Result<pb::response::Payload, Error>) -> pb::Response {
    match result {
        Ok(payload) => ok_response(request_id, payload),
        Err(e) => e.to_response(request_id),
    }
}

fn wrap_response(resp: pb::Response) -> pb::ServerFrame {
    pb::ServerFrame {
        kind: Some(pb::server_frame::Kind::Response(resp)),
    }
}

#[allow(dead_code)]
pub fn wrap_event(evt: pb::Event) -> pb::ServerFrame {
    pb::ServerFrame {
        kind: Some(pb::server_frame::Kind::Event(evt)),
    }
}

fn entry_to_pb(
    e: &crate::wallpaper::types::WallpaperEntry,
    tags: Vec<String>,
    user_properties_schema: String,
    user_property_overrides: String,
    wallpaper_layout_override: Option<WallpaperLayoutOverride>,
) -> pb::WallpaperEntry {
    // `e` is reconstructed from the DB (the source of truth), so its
    // fields are already the freshest values — no overlay needed.
    let wallpaper_layout_override_set = wallpaper_layout_override.is_some();
    pb::WallpaperEntry {
        id: e.item_id.to_string(),
        name: e.name.clone(),
        wp_type: e.wp_type.clone(),
        resource: e.resource.clone(),
        preview: e.preview.clone().unwrap_or_default(),
        // Per-entry metadata is no longer carried (extras() decouples
        // the renderer launch args); the wire field stays for compat.
        metadata: Default::default(),
        size: e.size.unwrap_or(0),
        width: e.width.unwrap_or(0),
        height: e.height.unwrap_or(0),
        content_rating: e.content_rating.clone().unwrap_or_default(),
        tags,
        user_properties_schema,
        user_property_overrides,
        description: e.description.clone().unwrap_or_default(),
        external_id: e.external_id.clone().unwrap_or_default(),
        wallpaper_layout_override: wallpaper_layout_override
            .map(|layout| layout_prefs_to_pb_resolved(&layout.materialize())),
        wallpaper_layout_override_set,
    }
}

#[cfg(test)]
mod tests {
    // Wallpaper filter SQL tests live in `model::filter`.
}
