use std::sync::Arc;

use crate::playlist::engine::Engine;
use crate::routing::RouterEvent;
use crate::AppState;

fn resolve_pid(app: &Arc<AppState>, key: &str) -> Option<i64> {
    app.settings
        .display_prefs(key)
        .and_then(|p| p.active_playlist_id)
        .or_else(|| app.settings.global().auto_attach_playlist_id)
}

pub async fn restore_all(app: &Arc<AppState>) {
    let displays = app.router.snapshot_displays().await;
    for d in displays {
        let key = d.instance_id.clone().unwrap_or_else(|| d.name.clone());
        let pid = resolve_pid(app, &key);
        if let Some(pid) = pid {
            if let Err(e) = Engine::activate_resuming_with_first_frame_timeout(
                app,
                &[d.id],
                pid,
                crate::control::APPLY_FIRST_FRAME_TIMEOUT,
            )
            .await
            {
                log::warn!("restore playlist {pid} on display {} failed: {e:#}", d.id);
            }
        }
    }
}

pub async fn watch_hotplug(app: Arc<AppState>) {
    let mut rx = app.router.subscribe_events();
    let mut shutdown = app.shutdown_subscribe();

    let mut sources = app.events.watch_sources_ready();
    let mut displays = app.events.watch_display_ready();
    tokio::select! {
        _ = async {
            let _ = sources.wait_for(|v| *v).await;
            let _ = displays.wait_for(|v| *v).await;
        } => {}
        changed = shutdown.changed() => {
            if changed.is_err() || *shutdown.borrow() { return; }
        }
    }

    restore_all(&app).await;
    loop {
        tokio::select! {
            ev = rx.recv() => {
                match ev {
                    Ok(RouterEvent::DisplayUpsert(s)) => {
                        let key = s.instance_id.clone().unwrap_or_else(|| s.name.clone());
                        if app.playlists.is_owned(s.id).await {
                            continue;
                        }
                        if let Some(pid) = resolve_pid(&app, &key) {
                            if let Err(e) = Engine::activate_resuming_with_first_frame_timeout(
                                &app,
                                &[s.id],
                                pid,
                                crate::control::APPLY_FIRST_FRAME_TIMEOUT,
                            )
                            .await
                            {
                                log::warn!("hotplug activate playlist {pid} failed: {e:#}");
                            }
                        }
                    }
                    Ok(RouterEvent::DisplayRemoved(id)) => {
                        app.playlists.drop_display(id).await;
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                        log::warn!("playlist hotplug watcher lagged {n} events; re-snapshotting");
                        let displays = app.router.snapshot_displays().await;
                        for d in displays {
                            if app.playlists.is_owned(d.id).await {
                                continue;
                            }
                            let key = d.instance_id.clone().unwrap_or_else(|| d.name.clone());
                            if let Some(pid) = resolve_pid(&app, &key) {
                                if let Err(e) =
                                    Engine::activate_resuming_with_first_frame_timeout(
                                        &app,
                                        &[d.id],
                                        pid,
                                        crate::control::APPLY_FIRST_FRAME_TIMEOUT,
                                    )
                                    .await
                                {
                                    log::warn!("lag-recover activate playlist {pid} failed: {e:#}");
                                }
                            }
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { break; }
            }
        }
    }
}
