use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use waywallen::display::proto::{codec, Request as ProtoRequest};
use crate::OutputBinding;
use waywallen::routing::autopause::{
    FLAG_ACTIVE, FLAG_FULLSCREEN, FLAG_MAXIMIZED, FLAG_NON_MINIMIZED,
};

pub type BindingRegistry = Arc<Mutex<HashMap<String, Arc<OutputBinding>>>>;

pub fn new_registry() -> BindingRegistry {
    Arc::new(Mutex::new(HashMap::new()))
}

pub fn detect_socket() -> Option<PathBuf> {
    let his = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    let xdg = std::env::var_os("XDG_RUNTIME_DIR")?;
    let mut path = PathBuf::from(xdg);
    path.push("hypr");
    path.push(his);
    path.push(".socket2.sock");
    if path.exists() {
        Some(path)
    } else {
        None
    }
}

pub fn spawn(registry: BindingRegistry) {
    let Some(sock) = detect_socket() else {
        return;
    };
    log::info!("hyprland_watcher: enabled (socket={})", sock.display());
    thread::spawn(move || run_loop(sock, registry));
}

fn run_loop(socket_path: PathBuf, registry: BindingRegistry) {
    loop {
        match UnixStream::connect(&socket_path) {
            Ok(stream) => {
                push_state(&registry);
                let reader = BufReader::new(stream);
                for line in reader.lines() {
                    match line {
                        Ok(_) => push_state(&registry),
                        Err(e) => {
                            log::warn!("hyprland_watcher: read error: {e}");
                            break;
                        }
                    }
                }
            }
            Err(e) => log::warn!("hyprland_watcher: connect {}: {e}", socket_path.display()),
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn push_state(registry: &BindingRegistry) {
    let snapshot = match hyprctl_snapshot() {
        Ok(v) => v,
        Err(e) => {
            log::warn!("hyprland_watcher: hyprctl: {e}");
            return;
        }
    };
    let by_output = aggregate_flags(&snapshot);
    let bindings: Vec<Arc<OutputBinding>> = registry
        .lock()
        .unwrap()
        .values()
        .cloned()
        .collect();
    for binding in bindings {
        let flags = by_output
            .get(binding.display_name())
            .copied()
            .unwrap_or(0);
        let prev = binding.window_flags().swap(flags, Ordering::SeqCst);
        if prev == flags {
            continue;
        }
        if !binding.is_registered() {
            continue;
        }
        let Some(stream) = binding.current_stream() else {
            continue;
        };
        let _g = binding.send_lock_guard();
        if let Err(e) = codec::send_request(&stream, &ProtoRequest::WindowState { flags }, &[]) {
            log::warn!(
                "hyprland_watcher: [{}] send window_state failed: {e}",
                binding.display_name()
            );
        } else {
            log::debug!(
                "hyprland_watcher: [{}] window_state flags=0x{flags:x}",
                binding.display_name()
            );
        }
    }
}

#[derive(serde::Deserialize)]
struct Client {
    address: String,
    monitor: i64,
    workspace: Workspace,
    fullscreen: i64,
    mapped: bool,
}

#[derive(serde::Deserialize)]
struct Workspace {
    id: i64,
}

#[derive(serde::Deserialize)]
struct Monitor {
    id: i64,
    name: String,
    #[serde(rename = "activeWorkspace")]
    active_workspace: WorkspaceRef,
}

#[derive(serde::Deserialize)]
struct WorkspaceRef {
    id: i64,
}

#[derive(serde::Deserialize)]
struct ActiveWindow {
    address: String,
}

struct Snapshot {
    clients: Vec<Client>,
    monitors: Vec<Monitor>,
    active_addr: Option<String>,
}

fn hyprctl_snapshot() -> anyhow::Result<Snapshot> {
    let clients = run_hyprctl_json::<Vec<Client>>(&["clients", "-j"])?;
    let monitors = run_hyprctl_json::<Vec<Monitor>>(&["monitors", "-j"])?;
    let active_addr = run_hyprctl_json::<ActiveWindow>(&["activewindow", "-j"])
        .ok()
        .map(|a| a.address)
        .filter(|s| !s.is_empty());
    Ok(Snapshot {
        clients,
        monitors,
        active_addr,
    })
}

fn run_hyprctl_json<T: serde::de::DeserializeOwned>(args: &[&str]) -> anyhow::Result<T> {
    let out = Command::new("hyprctl").args(args).output()?;
    if !out.status.success() {
        anyhow::bail!("hyprctl {args:?} exit {}", out.status);
    }
    Ok(serde_json::from_slice(&out.stdout)?)
}

fn aggregate_flags(snap: &Snapshot) -> HashMap<String, u32> {
    let mon_name: HashMap<i64, String> =
        snap.monitors.iter().map(|m| (m.id, m.name.clone())).collect();
    let active_ws: HashMap<i64, i64> = snap
        .monitors
        .iter()
        .map(|m| (m.id, m.active_workspace.id))
        .collect();
    let active = snap.active_addr.as_deref();
    let mut out: HashMap<String, u32> = HashMap::new();
    for c in &snap.clients {
        if !c.mapped {
            continue;
        }
        let Some(name) = mon_name.get(&c.monitor) else {
            continue;
        };
        if active_ws.get(&c.monitor) != Some(&c.workspace.id) {
            continue;
        }
        let entry = out.entry(name.clone()).or_insert(0);
        *entry |= FLAG_NON_MINIMIZED;
        if Some(c.address.as_str()) == active {
            *entry |= FLAG_ACTIVE;
        }
        match c.fullscreen {
            1 => *entry |= FLAG_MAXIMIZED,
            2 => *entry |= FLAG_FULLSCREEN,
            _ => {}
        }
    }
    out
}
