/* waywallen-bridge — C library for renderer subprocesses to talk to
 * the waywallen daemon over its IPC Unix-domain socket.
 *
 * This header layers length-prefix framing + SCM_RIGHTS fd passing
 * on top of the auto-generated per-message encoders/decoders in
 * <waywallen-bridge/ipc_v1.h>.
 *
 * Wire frame (same layout as waywallen-display-v1):
 *
 *     [u16 LE opcode][u16 LE total_length][body...]
 *
 * where total_length includes the 4-byte header. Ancillary fds ride
 * along on the same sendmsg/recvmsg call.
 *
 * Error conventions: all functions return 0 on success and a negative
 * value on failure. The negative is either a negated errno, or one of
 * the WW_ERR_* codes defined in <waywallen-bridge/ipc_v1.h>.
 *
 * Thread safety: none. Each socket is single-writer, single-reader
 * from the caller's perspective.
 */
#ifndef WAYWALLEN_BRIDGE_H
#define WAYWALLEN_BRIDGE_H

#include <waywallen-bridge/ipc_v1.h>
#include <waywallen-bridge/drm_fourcc.h>
#include <waywallen-bridge/protocol_bits.h>

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -----------------------------------------------------------------------
 * Connection
 * ----------------------------------------------------------------------- */

/* Connect to the daemon's IPC socket at `socket_path`.
 * Returns the socket fd (>=0) on success, or a negative errno on failure. */
int ww_bridge_connect(const char *socket_path);

/* Close a bridge socket. Equivalent to close(fd). */
void ww_bridge_close(int sock);


/* -----------------------------------------------------------------------
 * Low-level framing
 * ----------------------------------------------------------------------- */

/* Send a pre-encoded message body. `opcode` is the message opcode,
 * `body` is the encoded bytes (use ww_*_encode into a ww_buf_t to fill),
 * `fds`/`n_fds` are optional SCM_RIGHTS ancillary fds.
 *
 * Hard limits: body_len + 4 must fit in u16 (65531 max body), n_fds <= 64.
 *
 * Returns 0 on success. */
int ww_bridge_send_frame(int sock,
                         uint16_t opcode,
                         const uint8_t *body,
                         size_t body_len,
                         const int *fds,
                         size_t n_fds);

/* Receive a single framed message. On success:
 *   - *opcode_out      is the message opcode
 *   - *body_out        is a freshly-malloc()d buffer of length *body_len_out
 *                      (caller must free() it)
 *   - fds_out[0..*n_fds_out]  gets any SCM_RIGHTS fds that arrived (caller
 *                             owns them; call close() when done)
 *
 * `fds_cap` bounds how many fds we'll accept; exceeding it is an error.
 * Returns 0 on success, a negative errno on I/O, or WW_ERR_* on protocol
 * errors. */
int ww_bridge_recv_frame(int sock,
                         uint16_t *opcode_out,
                         uint8_t **body_out,
                         size_t *body_len_out,
                         int *fds_out,
                         size_t fds_cap,
                         size_t *n_fds_out);


/* -----------------------------------------------------------------------
 * High-level event senders (subprocess -> daemon)
 * ----------------------------------------------------------------------- */

/* Emit `Ready`. Must be the first event after connecting. No fds.
 *
 * `drm_render_major` / `drm_render_minor` identify the DRM render-node
 * of the GPU the renderer's Vulkan/EGL/etc. instance picked, so the
 * daemon can decide whether each subscribed display is on the same GPU
 * (zero-copy) or a different GPU (must round-trip via HOST_VISIBLE).
 * Pass `(0, 0)` when the renderer cannot resolve its render node — the
 * daemon then conservatively assumes cross-GPU and forces HOST_VISIBLE
 * placement on every subsequent `configure_buffers`. */
int ww_bridge_send_ready(int sock,
                         uint32_t drm_render_major,
                         uint32_t drm_render_minor);

/* Emit `BindBuffers` carrying `m->count` DMA-BUF fds. `fds` must have
 * exactly `m->count` entries. */
int ww_bridge_send_bind_buffers(int sock,
                                const ww_evt_bind_buffers_t *m,
                                const int *fds);

/* Emit `FrameReady` with a single acquire sync_fd (dma_fence sync_file).
 * `m->release_point` names the timeline value the daemon will signal on
 * the producer-exported `release_syncobj` once every consumer has
 * finished sampling this frame. */
int ww_bridge_send_frame_ready(int sock,
                               const ww_evt_frame_ready_t *m,
                               int sync_fd);

/* Emit `ReleaseSyncobj` carrying the producer's exported timeline
 * drm_syncobj fd. Send exactly once per connection, after `Ready` and
 * before any `FrameReady`. The fd is the OPAQUE_FD export of a Vulkan
 * TIMELINE semaphore on the renderer's `VkDevice`. The caller retains
 * ownership of `release_syncobj_fd` and is responsible for closing it
 * after this call returns (the kernel dup'd it into SCM_RIGHTS). */
int ww_bridge_send_release_syncobj(int sock, int release_syncobj_fd);

/* Emit `FormatCaps` — the producer's modifier-negotiation declaration.
 * Send exactly once per connection, after `Ready` and before any
 * `BindBuffers`. Caller fills the parallel-array fields directly on
 * `m`; this helper is a thin encode + framed-send wrapper.
 *
 * Validation invariant (mirrored on the daemon side):
 *   m->modifiers.count == m->usages.count == m->plane_counts.count ==
 *   sum(m->mod_counts.data[0..fourccs.count])
 * The helper does NOT enforce this — the renderer must construct the
 * arrays consistently or the daemon's unflatten_caps will reject. */
int ww_bridge_send_format_caps(int sock, const ww_evt_format_caps_t *m);

/* Caller-friendly inputs for `ww_bridge_send_format_caps_v2`. Holds
 * pointers to caller-owned arrays (no copies, no ownership transfer)
 * plus the scalar negotiation knobs. The helper assembles the
 * `ww_evt_format_caps_t` wire shape from these fields, packs the two
 * 16-byte UUIDs as 4×u32 LE, and dispatches to
 * `ww_bridge_send_format_caps`.
 *
 * Length invariants (mirrored on the daemon's `unflatten_caps`):
 *   modifiers_count == usages_count == plane_counts_count ==
 *   sum(mod_counts[0..fourccs_count])
 *
 * `device_uuid` / `driver_uuid`: pass NULL to send 16 zero bytes
 * (renderers without `VK_KHR_external_memory_capabilities` /
 * EGL_DEVICE_UUID_EXT do this). When non-NULL, must point at 16
 * readable bytes. */
typedef struct ww_format_caps_caller {
    const uint32_t *fourccs;        uint32_t fourccs_count;
    const uint32_t *mod_counts;     uint32_t mod_counts_count;
    const uint64_t *modifiers;      uint32_t modifiers_count;
    const uint32_t *usages;         uint32_t usages_count;
    const uint32_t *plane_counts;   uint32_t plane_counts_count;
    const uint8_t  *device_uuid;    /* NULL or 16 bytes */
    const uint8_t  *driver_uuid;    /* NULL or 16 bytes */
    uint32_t        drm_render_major;
    uint32_t        drm_render_minor;
    uint32_t        mem_hints;
    uint32_t        sync_caps;
    uint32_t        color_caps;
    uint32_t        extent_max_w;
    uint32_t        extent_max_h;
} ww_format_caps_caller_t;

/* High-level wrapper around `ww_bridge_send_format_caps` that takes
 * caller-owned C arrays and the negotiation scalars in one struct.
 * Use this when assembling format caps from a probe loop — both
 * renderer plugins go through this path. */
int ww_bridge_send_format_caps_v2(int sock,
                                  const ww_format_caps_caller_t *m);

/* Emit `BindFailed` — non-terminal report that the renderer could not
 * satisfy a `negotiate_buffers` request. Daemon blacklists the
 * (fourcc, modifier) pair on this renderer and re-runs the picker. */
int ww_bridge_send_bind_failed(int sock,
                               uint32_t fourcc,
                               uint64_t modifier,
                               uint32_t reason,
                               const char *message);

/* Emit an `Error` event with a text message. */
int ww_bridge_send_error(int sock, const char *msg);


/* -----------------------------------------------------------------------
 * Modifier negotiation
 *
 * Producer-side bookkeeping for the `format_caps` / `negotiate_buffers`
 * dance: a pinned (fourcc, modifier, plane_count) the slot pool is
 * currently allocated against, plus the full set of (modifier,
 * plane_count) tuples the producer can switch to via re-allocation.
 * ----------------------------------------------------------------------- */

/* One advertised (fourcc, modifier, plane_count) tuple. The daemon's
 * negotiator strict-equals plane_count when intersecting producer and
 * consumer caps, so producers must report truth — see
 * waywallen/src/negotiate.rs:432. */
typedef struct ww_format_entry {
    uint32_t fourcc;
    uint64_t modifier;
    uint32_t plane_count;
} ww_format_entry_t;

/* Producer-side negotiation snapshot. Owned by the caller; the
 * `advertised` array points at producer storage that outlives the
 * negotiation calls. The pinned (fourcc, modifier, plane_count) is
 * the one the slot pool is currently allocated against; on
 * `negotiate_buffers` the producer either re-allocates to a different
 * entry from `advertised` (and updates the pinned tuple) or replies
 * `bind_failed` to push the daemon to re-pick.
 *
 * Invariants:
 *   - The pinned (fourcc, modifier, plane_count) MUST appear in
 *     `advertised`.
 *   - Entries with the same `fourcc` MUST be contiguous in
 *     `advertised` (the format_caps flatten helper walks runs).
 *   - The pinned entry SHOULD be first within its fourcc's run, and
 *     the pinned fourcc SHOULD come before non-pinned fourccs — this
 *     lets the daemon's picker land on the pinned tuple in one round
 *     instead of bouncing through `bind_failed` retries. */
typedef struct ww_negotiation_state {
    uint32_t                  fourcc;
    uint64_t                  modifier;
    uint32_t                  plane_count;
    const ww_format_entry_t  *advertised;
    size_t                    advertised_count;
} ww_negotiation_state_t;

/* True (1) if a (fourcc, modifier) pair is anywhere in `advertised`.
 * False (0) otherwise. NULL `neg` returns 0. Replaces the linear-scan
 * "is this in our advertised set?" check producers do in their
 * NegotiateBuffers handlers. */
int ww_bridge_negotiation_contains(const ww_negotiation_state_t *neg,
                                   uint32_t                      fourcc,
                                   uint64_t                      modifier);

/* Populate a `ww_format_caps_caller_t` from the negotiation state plus
 * caller-provided scratch arrays. Walks `advertised` collapsing
 * contiguous same-fourcc runs into the wire format's
 * `(fourccs[], mod_counts[])` shape; relies on the
 * "same-fourcc-contiguous" invariant above.
 *
 * Scratch sizing (caller owns and outlives `out`); all sized to
 * `neg->advertised_count` for worst-case (one fourcc per entry):
 *   - `scratch_fourccs`      [advertised_count]
 *   - `scratch_mod_counts`   [advertised_count]
 *   - `scratch_modifiers`    [advertised_count]
 *   - `scratch_plane_counts` [advertised_count]
 *   - `scratch_usages`       [advertised_count]
 *
 * `usage` is replicated to every entry of `scratch_usages` (typical
 * value: `WW_USAGE_SAMPLED`). Caller still fills the scalar
 * negotiation knobs (sync_caps, color_caps, mem_hints, extent_max,
 * UUIDs, drm_render_*) on `out` after this call. */
void ww_bridge_negotiation_fill_format_caps(
    const ww_negotiation_state_t *neg,
    uint32_t                      usage,
    uint32_t                     *scratch_fourccs,
    uint32_t                     *scratch_mod_counts,
    uint64_t                     *scratch_modifiers,
    uint32_t                     *scratch_plane_counts,
    uint32_t                     *scratch_usages,
    ww_format_caps_caller_t      *out);


/* -----------------------------------------------------------------------
 * Renderer utilities
 *
 * Tiny helpers shared verbatim by every renderer subprocess. Kept in
 * the header so they're trivially inlineable across both C and C++
 * call sites.
 * ----------------------------------------------------------------------- */

/* Monotonic nanosecond timestamp for `frame_ready.ts_ns` and any other
 * place a renderer needs a steady-clock reading. Falls back to 0 on
 * the (vanishingly rare) clock_gettime failure rather than crashing —
 * the daemon treats ts_ns as advisory. */
uint64_t ww_bridge_now_ns(void);

/* Argv consumer for unrecognized `--key value` pairs forwarded by the
 * daemon from source-plugin metadata (e.g. --fps, --workshop_id) that
 * a particular renderer doesn't implement. Behaviour: if argv[*i]
 * starts with "--" and the next token does NOT, advance *i by one to
 * skip the value too. Otherwise leave *i untouched (the outer arg
 * loop's own ++i will move past the bare flag).
 *
 * Safe to call on the trailing-arg case (i+1 >= argc).
 *
 * Usage:
 *   for (int i = 1; i < argc; ++i) {
 *       const char *a = argv[i];
 *       if (strcmp(a, "--width") == 0) { ... }
 *       else { ww_bridge_skip_unknown_kv_arg(&i, argc, argv); }
 *   }
 */
static inline void ww_bridge_skip_unknown_kv_arg(int *i, int argc, char *const argv[]) {
    if (!i || *i < 0 || *i >= argc) return;
    const char *a = argv[*i];
    if (!a || a[0] != '-' || a[1] != '-') return;
    if (*i + 1 >= argc) return;
    const char *next = argv[*i + 1];
    if (!next || (next[0] == '-' && next[1] == '-')) return;
    ++(*i);
}


/* -----------------------------------------------------------------------
 * Diagnostics
 * ----------------------------------------------------------------------- */

/* One labeled row of the GPU info block. Both fields are
 * caller-owned, NUL-terminated. `value == NULL` is rendered as
 * "(null)" — useful when an EGL/Vulkan/GL string accessor returns
 * NULL. `label == NULL` is treated as the empty string. */
typedef struct ww_gpu_info_field {
    const char *label;
    const char *value;
} ww_gpu_info_field_t;

/* Print a "GPU info" diagnostic block to stderr, formatted as
 *
 *     {prefix}: GPU info
 *       {label}: {value}
 *       ...
 *
 * The label column auto-aligns to the widest label across all
 * supplied fields. Caller does the GPU-API queries (eglQueryString,
 * glGetString, vkGetPhysicalDeviceProperties ...) and hands the
 * already-fetched strings to this helper, so the bridge stays free
 * of any EGL/GL/Vulkan dependency. */
void ww_bridge_log_gpu_info(const char *prefix,
                            const ww_gpu_info_field_t *fields,
                            size_t n_fields);


/* -----------------------------------------------------------------------
 * High-level control receive (daemon -> subprocess)
 * ----------------------------------------------------------------------- */

/* Tagged union of all incoming control requests. `op` selects which
 * union arm is populated. String fields inside are heap-allocated —
 * call `ww_bridge_control_free` when done. */
typedef struct ww_bridge_control {
    ww_request_op_t op;
    union {
        ww_req_hello_t              hello;
        ww_req_load_scene_t         load_scene;
        ww_req_play_t               play;
        ww_req_pause_t              pause;
        ww_req_mouse_t              mouse;
        ww_req_set_fps_t            set_fps;
        ww_req_shutdown_t           shutdown;
        ww_req_negotiate_buffers_t  negotiate_buffers;
    } u;
} ww_bridge_control_t;

/* Receive the next control message. Blocks until a full frame is
 * available or the peer closes. Returns 0 on success. */
int ww_bridge_recv_control(int sock, ww_bridge_control_t *out);

/* Free any heap allocations inside a decoded control message. Safe to
 * call on a zero-initialized struct. */
void ww_bridge_control_free(ww_bridge_control_t *msg);


#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WAYWALLEN_BRIDGE_H */
