#pragma once

// PTS → wall-clock pacing helper for the video plugin's render loop.
//
// Header-only because it's small and stateful-but-trivial (a baseline
// time pair plus a couple of conditionals). The plugin instantiates one
// Presenter per VideoDecoder and calls `present_frame(pts)` before
// dispatching each frame's GPU conversion.
//
// Behavior:
//   - First frame primes the baseline (t0_wall = now; t0_pts = pts).
//   - Subsequent frames sleep until t0_wall + (pts - t0_pts).
//   - PTS that drops backwards (loop wrap-around) re-baselines silently.
//   - Frames more than `max_lag` behind schedule are dropped (return
//     false) so a slow consumer or stalled decoder doesn't snowball.
//   - Frames with pts<0 (PTS unavailable) skip pacing entirely.

#include <chrono>
#include <thread>

namespace waywallen::ffvk {

class Presenter {
public:
    using Clock     = std::chrono::steady_clock;
    using Duration  = Clock::duration;
    using TimePoint = Clock::time_point;

    explicit Presenter(Duration max_lag = std::chrono::milliseconds(250))
        : max_lag_(max_lag) {}

    // Force the next call to re-prime the baseline. Useful when the
    // caller knows the stream just looped or the decoder was reset.
    void reset() { primed_ = false; t0_pts_ = -1.0; }

    // Returns true if the caller should render the frame now (possibly
    // after sleeping); false if the frame is too far behind schedule and
    // should be dropped. Always advances the baseline on drop so we
    // recover instead of dropping every subsequent frame too.
    bool present_frame(double pts_seconds) {
        if (pts_seconds < 0.0) return true;  // unknown PTS — render ASAP

        const auto now = Clock::now();
        if (!primed_) {
            t0_wall_ = now;
            t0_pts_  = pts_seconds;
            primed_  = true;
            return true;
        }
        // Backwards jump → loop wrap or seek; re-baseline silently and
        // present immediately so the next frame's pacing is right.
        if (pts_seconds < t0_pts_) {
            t0_wall_ = now;
            t0_pts_  = pts_seconds;
            return true;
        }

        const auto delta = std::chrono::duration_cast<Duration>(
            std::chrono::duration<double>(pts_seconds - t0_pts_));
        const auto target = t0_wall_ + delta;

        if (target + max_lag_ < now) {
            // We're behind the wall by more than max_lag. Drop and
            // re-baseline against the new pts so subsequent frames
            // pace correctly.
            t0_wall_ = now;
            t0_pts_  = pts_seconds;
            return false;
        }
        if (now < target) std::this_thread::sleep_until(target);
        return true;
    }

private:
    Duration  max_lag_;
    TimePoint t0_wall_ {};
    double    t0_pts_  { -1.0 };
    bool      primed_  { false };
};

} // namespace waywallen::ffvk
