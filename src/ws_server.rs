//! WebSocket + protobuf control plane.
//!
//! Single `/` endpoint. Each connection carries length-prefixed-by-WS-frame
//! `waywallen.control.v1.Request` / `Response` envelopes. All RPCs are
//! multiplexed via `request_id` and the `payload` oneof.

use std::sync::Arc;

use anyhow::Result;
use futures_util::{SinkExt, StreamExt};
use prost::Message as _;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::protocol::Message;

use crate::control;
use crate::control_proto as pb;
use crate::error::{ok_response, Error};
use crate::events::GlobalEvent;
use crate::ipc::proto::ControlMsg;
use crate::model::repo;
use crate::queue;
use crate::renderer_manager;
use crate::routing::{DisplaySnapshot, LibrarySnapshot, RendererSnapshot, RouterEvent};
use crate::settings::{
    FilterLogicState, SettingsStore, WallpaperFilterRuleState, WallpaperFilterState,
    WallpaperIntFilterState, WallpaperSortRuleState, WallpaperStringFilterState,
};
use crate::tasks;
use crate::wallpaper_sort::apply_wallpaper_sorts;
use crate::AppState;

/// Bind the WebSocket control plane and return the actual local address
/// (useful when binding to port 0 for OS-assigned ports).  The returned
/// future runs the accept loop and never returns under normal operation.
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
// (`to_pb` / `from_pb`) so both ws_server and control share the same
// roundtrip. See `crate::settings`.

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
                        if let Some(pe) = global_event_to_pb(&e, &state) {
                            sink.send(Message::Binary(wrap_event(pe).encode_to_vec())).await?;
                        }
                        if matches!(e, GlobalEvent::StatusChanged) {
                            sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("ws {peer}: global event lag {n}");
                        // Resync after lag — the snapshot is the
                        // authority, transient events were the lossy
                        // notifications.
                        sink.send(Message::Binary(wrap_event(status_sync_event(&state)).encode_to_vec())).await?;
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
// ---------------------------------------------------------------------------

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
    // Per-display prefs are keyed by `instance_id` when the consumer
    // advertises one (v4); name is only the fallback. Mirrors
    // `Router::resolved_layout` so the snapshot the UI sees agrees with
    // what `resync_display_set_config` pushes to the display subprocess.
    let layout_key: &str = s
        .instance_id
        .as_deref()
        .filter(|iid| settings.display_prefs(iid).is_some())
        .unwrap_or(s.name.as_str());
    let resolved = settings.resolved_layout(layout_key);
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
        effective_layout: Some(layout_prefs_to_pb_resolved(&resolved)),
        layout_override: Some(layout_override_to_pb(&override_prefs)),
        drm_render_major: s.drm_render_major,
        drm_render_minor: s.drm_render_minor,
        alias: override_prefs.alias.clone().unwrap_or_default(),
    }
}

fn layout_prefs_to_pb_resolved(r: &crate::settings::ResolvedLayout) -> pb::LayoutPrefs {
    pb::LayoutPrefs {
        fillmode: fillmode_to_pb(r.fillmode) as i32,
        align: align_to_pb(r.align) as i32,
        rotation: rotation_to_pb(r.rotation) as i32,
    }
}

fn layout_override_to_pb(p: &crate::settings::DisplayPrefs) -> pb::LayoutOverride {
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
    pb::GlobalSettings {
        wallpaper_filters,
        wallpaper_filter_logics,
        wallpaper_sorts,
        layout_defaults: Some(pb::LayoutPrefs {
            fillmode: fillmode_to_pb(g.layout.fillmode) as i32,
            align: align_to_pb(g.layout.align) as i32,
            rotation: rotation_to_pb(g.layout.rotation) as i32,
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
/// Pushed on WS connect, on every `GlobalEvent::StatusChanged`, and on
/// any `TaskEvent`. Authoritative — the UI binds to its fields rather
/// than counting transient start/end events.
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

/// Translate the subset of `GlobalEvent` variants the UI cares about
/// into wire `pb::Event`s. Returns `None` for events that are
/// daemon-internal (boot phase markers, restore lifecycle).
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
        GlobalEvent::PlaylistChanged => Some(pb::Event {
            payload: Some(pb::event::Payload::PlaylistChanged(pb::PlaylistChanged {})),
        }),
        GlobalEvent::SourcesReady
        | GlobalEvent::DisplayReady
        | GlobalEvent::DaemonReady
        | GlobalEvent::RestoreApplied(_)
        | GlobalEvent::RestoreFailed(_)
        | GlobalEvent::StatusChanged => None,
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

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
            // Treat it as both the CLI argv extras (path / assets / …)
            // and the Init.settings kv. This is loose by design — the
            // RPC is for advanced/manual use; `WallpaperApply` is the
            // intended end-user path and sources settings cleanly from
            // the settings store.
            //
            // `r.fps` rides on `settings["fps"]` so the renderer sees
            // it via `Init.settings` — the typed scalar is gone.
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
            // renderer_manager returns the typed Error directly (spawn
            // produces RendererSpawnFailed/NoRendererForType/RendererNotFound
            // depending on the failure); just propagate.
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
                // fps lives in the plugin section of the settings store
                // now (`Settings::reconcile` already enforces the
                // schema). 0 = unknown / unset.
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
                        has_source: pkg.has_source,
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

            let mut raw_entries: Vec<&crate::wallpaper_type::WallpaperEntry> = all_entries
                .iter()
                .filter(|e| r.wp_type.is_empty() || e.wp_type == r.wp_type)
                .collect();
            if !r.skip_types.is_empty() {
                raw_entries.retain(|e| !r.skip_types.iter().any(|t| t == &e.wp_type));
            }

            // Inject the free-text search as an extra filter rule
            // placed in its own group. `build_grouped_condition` AND-s
            // any group not referenced by a `FilterLogic` into the
            // outer condition, so a fresh group id with no matching
            // logic edges combines via AND with whatever the user-built
            // rules already say.
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

            let mut filtered_entries: Vec<&crate::wallpaper_type::WallpaperEntry> =
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

            let page_entries: Vec<&crate::wallpaper_type::WallpaperEntry> = filtered_entries
                .into_iter()
                .skip(offset)
                .take(take)
                .collect();

            // Batch-load tags for just the items on this page (avoid
            // an N+1 round-trip when paginating large libraries).
            let page_item_ids: Vec<i64> = page_entries.iter().map(|e| e.item_id).collect();
            let tag_map = repo::list_tags_for_items(&state.db, &page_item_ids).await?;

            // WallpaperList intentionally does NOT fill user-property
            // schema/overrides — the schema is renderer-published (only
            // available for an actively-running wallpaper) and the
            // overrides need a per-item DB read. Detail panel grabs
            // both via WallpaperGet.
            let entries: Vec<pb::WallpaperEntry> = page_entries
                .into_iter()
                .map(|e| {
                    let tags = tag_map.get(&e.item_id).cloned().unwrap_or_default();
                    entry_to_pb(e, tags, String::new(), String::new())
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
            // Source plugin owns the property schema — read project.json
            // (or equivalent) on demand. Empty string when the plugin
            // doesn't expose properties or this entry has none.
            let schema = state
                .source_manager
                .lock()
                .await
                .call_properties(&entry.plugin_name, &entry)
                .await
                .ok()
                .flatten()
                .unwrap_or_default();
            let overrides = repo::get_user_property_overrides_raw(&state.db, entry.item_id)
                .await?
                .unwrap_or_default();

            Res::WallpaperGet(pb::WallpaperGetResponse {
                entry: Some(entry_to_pb(&entry, tags, schema, overrides)),
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
            // Push live: unknown keys on the renderer side go through
            // setPropertyString → MainSetProperty → shader cbuffer.
            let push_tag = if let Some(h) = state
                .renderer_manager
                .find_by_resource(&entry.resource)
                .await
            {
                let kv = vec![(r.key.clone(), r.value.clone())];
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
            };
            log::debug!(
                "WallpaperPropertySet: {}={} on {} persist={} push={}",
                r.key,
                r.value,
                r.wallpaper_id,
                persist_tag,
                push_tag
            );
            Res::WallpaperPropertySet(pb::WallpaperPropertySetResponse {})
        }

        Req::WallpaperScan(_) => {
            // Fire-and-forget: kick the rescan onto the TaskManager and
            // return immediately. Completion (or failure) reaches the
            // UI via the `WallpaperSyncFinished` server event, so the
            // request is just an ack. `spawn_async_unique` collapses
            // overlapping triggers (rapid clicks, library churn) under
            // one in-flight scan.
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
            let new_rotation = if r.clear_rotation {
                None
            } else {
                r.r#override
                    .as_ref()
                    .filter(|o| o.rotation_set)
                    .and_then(|o| rotation_from_pb(o.rotation))
            };
            state
                .router
                .set_display_layout(
                    r.name.clone(),
                    new_fillmode,
                    new_align,
                    new_rotation,
                    r.clear_fillmode,
                    r.clear_align,
                    r.clear_rotation,
                )
                .await;
            // Look up the (possibly absent) DisplayInfo to return.
            let snap = state.router.snapshot_displays().await;
            let display = snap
                .into_iter()
                .find(|d| d.name == r.name)
                .map(|d| display_snapshot_to_pb(d, &state.settings));
            Res::DisplayLayoutSet(pb::DisplayLayoutSetResponse { display })
        }

        Req::DisplayRename(r) => {
            let new_alias = if r.clear || r.alias.trim().is_empty() {
                None
            } else {
                Some(r.alias.clone())
            };
            state
                .router
                .set_display_alias(r.name.clone(), new_alias, r.clear)
                .await;
            let snap = state.router.snapshot_displays().await;
            let display = snap
                .into_iter()
                .find(|d| d.name == r.name)
                .map(|d| display_snapshot_to_pb(d, &state.settings));
            Res::DisplayRename(pb::DisplayRenameResponse { display })
        }

        Req::RemoteAvailability(_) => Res::RemoteAvailability(pb::RemoteAvailabilityResponse {
            owned: true,
            content_dir: String::new(),
        }),

        Req::RemoteSearch(_) => Res::RemoteSearch(pb::RemoteSearchResponse {
            items: Vec::new(),
            has_more: false,
            error: String::new(),
        }),

        Req::RemoteDownload(_) => Res::RemoteDownload(pb::RemoteDownloadResponse {
            accepted: false,
            error: "no remote source plugin".into(),
        }),

        Req::RemoteUninstall(_) => Res::RemoteUninstall(pb::RemoteUninstallResponse {
            removed: false,
            error: "no remote source plugin".into(),
        }),

        Req::RemoteDetails(_) => Res::RemoteDetails(pb::RemoteDetailsResponse {
            description: String::new(),
            size: String::new(),
            tags: Vec::new(),
            error: String::new(),
        }),

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
            // Renderer pick: empty renderer_name uses priority resolve
            // (current behaviour); explicit name must match a registered
            // renderer that supports this wallpaper's type.
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
            // Render-target size is the renderer's own decision
            // (content native + `resolution` plugin setting); the
            // daemon no longer forwards an extent hint. Per-plugin
            // settings flow into spawn metadata as baseline kv;
            // per-wallpaper metadata wins on collisions.
            let plugin_kv = state.settings.plugin(&plugin_name).unwrap_or_default();

            // Per-item user-property overrides ride as a separate JSON
            // payload in `Init.user_properties` (decoupled from the
            // schema-validated plugin settings). The renderer parses it
            // once on startup and routes each entry through the WE
            // user-property pipeline; no name collisions with plugin
            // settings are possible.
            let user_properties_json =
                repo::get_user_property_overrides_raw(&state.db, entry.item_id).await?;

            // SPAWN_VERSION 3: extras (canonical `path` + manifest
            // whitelist like `assets`/`workshop_id`) ride as CLI
            // argv. Ask the source plugin for the dict via its
            // `extras(entry)` Lua callback. Lua failures used to fall
            // back to `entry.metadata` silently with a warn; now they
            // surface as `SourceExtrasFailed` so the UI shows the real
            // problem instead of a confusing "wrong settings" follow-up.
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
                // Pin reuse + spawn to the explicit pick when the
                // request named one; otherwise let the manager fall
                // back to priority resolve (legacy behaviour).
                renderer_name: if r.renderer_name.is_empty() {
                    None
                } else {
                    Some(plugin_name.clone())
                },
                user_properties_json,
            };

            // Reuse an existing renderer when wp_type / extent / plugin
            // / extras (path) all match and the handle hasn't been
            // marked stale by an identity-tagged SettingsSet. Plugin
            // settings live in the settings store and are pushed by
            // SettingsSet's own broadcast, so the reuse path doesn't
            // need to dispatch ApplySettings here.
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
                    // Stop any pre-existing renderer whose every
                    // enabled display link is in the relink target
                    // set BEFORE the new one is spawned, so peak GPU
                    // memory stays at one working set's worth instead
                    // of overlapping two.
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
                        // Orderly shutdown: tells displays to unbind,
                        // waits for ack, then graceful Shutdown of the
                        // producer. See stop_renderers_orderly doc.
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

            if r.display_ids.is_empty() {
                state.router.relink_all_displays_to(&renderer_id).await;
            } else {
                state
                    .router
                    .relink_displays_to(&r.display_ids, &renderer_id)
                    .await;
            }

            // Mirror the persistence side-effects of
            // `control::apply_wallpaper_by_id`: pin the playlist cursor
            // so the next sequential/random step has an anchor.
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
            // Specific list means only those. The global write below
            // stays as the fallback for displays that have no record
            // yet (e.g. a brand-new monitor connected for the first
            // time after restart).
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
            // values so callers can update plugins alone by sending
            // None for global.
            let mut new_plugins: std::collections::HashMap<
                String,
                std::collections::HashMap<String, String>,
            > = r.plugins.into_iter().map(|(k, v)| (k, v.values)).collect();

            // Schema validation up-front. Reject the entire RPC if any
            // declared key fails type / bounds / choices — partial
            // commits would leave the toml in a state that doesn't
            // match what the caller asked for.
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

            // Snapshot the previous per-plugin settings so we can diff
            // against the new ones and dispatch ApplySettings to any
            // live renderer whose plugin name matches.
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
                // Filter change invalidates the queue's shuffle round
                // (candidate set changed); next step rematerializes.
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
            // Hot-apply queue mode + rotation interval. Autopause has no
            // hot-apply step — `router::resolved_autopause` re-reads
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
            // Step 4: live renderer hot-reload.
            // For each plugin that actually changed, walk live
            // renderers for that plugin name and push the delta.
            // Identity-tagged keys produce a warn log (would require
            // a respawn, which is too invasive for a settings RPC).
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
            // Hot-reload failures used to be `log::warn`-and-continue.
            // Now we collect every per-renderer failure during the
            // walk; if any happened, propagate one aggregate
            // `SettingsApplyFailed` after publishing the change event
            // (settings are persisted regardless — the caller still
            // needs to know hot-reload was incomplete).
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

                // Forward every key the user actually changed (within
                // the manifest schema) to all live renderers of this
                // plugin. The renderer applies what it can hot-reload
                // and ignores the rest; whatever it didn't accept will
                // take effect on its next spawn via `Init.settings`,
                // which sources the same settings store.
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
            // Rescan so the new library's items flow into the
            // in-memory snapshot + DB without waiting for the
            // next daemon restart. Shares `"scan/refresh"`
            // dedup key with manual scans — rapid LibraryAdd
            // bursts collapse into a single in-flight scan.
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
                displays: st
                    .into_iter()
                    .map(|d| pb::PlaylistDisplayStatus {
                        display_id: d.display_id,
                        active_id: d.active_id,
                        mode: queue_mode_to_pb_playlist(d.mode),
                        interval_secs: d.interval_secs,
                        current_id: d.current_id.unwrap_or_default(),
                        position: d.position,
                        count: d.count,
                        remaining_secs: d.remaining_secs,
                    })
                    .collect(),
            })
        }

        Req::PlaylistExport(r) => {
            let pl = crate::playlist::repo::get(&state.db, r.id)
                .await?
                .ok_or_else(|| crate::error::Error::PlaylistNotFound(r.id.to_string()))?;
            let local_ids = crate::playlist::repo::entry_ids(&state.db, r.id).await?;
            let mut entry_ids = Vec::with_capacity(local_ids.len());
            for id in &local_ids {
                let portable = crate::model::repo::get_entry(&state.db, *id)
                    .await?
                    .and_then(|e| e.external_id)
                    .unwrap_or_else(|| id.to_string());
                entry_ids.push(portable);
            }
            let mode: crate::queue::Mode = pl.mode.into();
            let doc = PlaylistExportDoc {
                name: pl.name,
                mode: mode.as_str().to_owned(),
                interval_secs: pl.interval_secs as u32,
                entry_ids,
            };
            let json = serde_json::to_string_pretty(&doc)?;
            std::fs::write(&r.path, json)?;
            Res::PlaylistExport(pb::PlaylistExportResponse {})
        }

        Req::PlaylistImport(r) => {
            let data = std::fs::read_to_string(&r.path)?;
            let doc: PlaylistExportDoc = serde_json::from_str(&data)?;
            let mode = crate::queue::Mode::from_str(&doc.mode).unwrap_or_default();
            let now = tasks::now_ms();
            let mut local_ids = Vec::with_capacity(doc.entry_ids.len());
            let mut missing_count = 0u32;
            for stored in &doc.entry_ids {
                if let Some(iid) =
                    crate::model::repo::find_item_id_by_external_id(&state.db, stored).await?
                {
                    local_ids.push(iid);
                } else if let Ok(iid) = stored.parse::<i64>() {
                    if crate::model::repo::get_entry(&state.db, iid)
                        .await?
                        .is_some()
                    {
                        local_ids.push(iid);
                    } else {
                        missing_count += 1;
                    }
                } else {
                    missing_count += 1;
                }
            }
            let id = if r.into_id > 0 {
                crate::playlist::repo::rename(&state.db, r.into_id, &doc.name, now).await?;
                crate::playlist::repo::set_mode(&state.db, r.into_id, mode, now).await?;
                crate::playlist::repo::set_interval(&state.db, r.into_id, doc.interval_secs, now)
                    .await?;
                crate::playlist::repo::set_items(&state.db, r.into_id, &local_ids, now).await?;
                crate::playlist::engine::Engine::rebuild_for_playlist(&state, r.into_id).await;
                r.into_id
            } else {
                crate::playlist::repo::create(
                    &state.db,
                    &doc.name,
                    mode,
                    doc.interval_secs,
                    now,
                    &local_ids,
                )
                .await?
            };
            state.events.publish(GlobalEvent::PlaylistChanged);
            Res::PlaylistImport(pb::PlaylistImportResponse { id, missing_count })
        }

        Req::PlaylistJumpTo(r) => {
            crate::playlist::engine::Engine::jump_to(&state, r.id, &r.entry_id).await?;
            Res::PlaylistJumpTo(pb::Empty {})
        }
    })
}

#[derive(serde::Serialize, serde::Deserialize)]
struct PlaylistExportDoc {
    name: String,
    mode: String,
    interval_secs: u32,
    entry_ids: Vec<String>,
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
/// `Unspecified` (0) and any unrecognized variant default to
/// Sequential — that's what a client that forgot the field meant.
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
// ---------------------------------------------------------------------------

/// Encode a dispatch result onto the wire. Thin wrapper around
/// `Error::to_response` / `ok_response` from `crate::error`; the dispatch
/// boundary is the only place the daemon-side `Error` becomes wire bytes.
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
    e: &crate::wallpaper_type::WallpaperEntry,
    tags: Vec<String>,
    user_properties_schema: String,
    user_property_overrides: String,
) -> pb::WallpaperEntry {
    // `e` is reconstructed from the DB (the source of truth), so its
    // fields are already the freshest values — no overlay needed.
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
    }
}

#[cfg(test)]
mod tests {
    // Wallpaper filter SQL tests live in `model::filter`.
}
