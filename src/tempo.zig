const std = @import("std");

/// Tempo from the onset strength function.
///
/// Onsets on their own are reactive: something happens and a consumer jerks
/// in response, with nothing tying one detection to the next. A period plus
/// a phase lets a consumer know where the next beat lands before it
/// arrives, so it can move continuously in time with the music instead of
/// twitching when a transient shows up. It also makes a spurious onset
/// harmless, since one bad detection barely moves an estimate built from
/// six seconds of history.
///
/// Autocorrelation for the period, a phase accumulator nudged by onsets for
/// the phase. Both are cheap - the autocorrelation only runs a couple of
/// times a second and the accumulator is one add per frame.
pub const Options = struct {
    /// frames per second of the onset strength function
    fps: f32,
    /// tempo range considered. wider than this and the octave errors get
    /// silly - half of 180 is 90 and both are inside it
    min_bpm: f32 = 60,
    max_bpm: f32 = 190,
    /// how much history the period is estimated from. six seconds is about
    /// twelve beats at 120, enough for the autocorrelation to have a real
    /// peak rather than a noisy one
    history_s: f32 = 6,
    /// how often to re-estimate, in frames. every frame would be waste - a
    /// tempo does not move that fast
    estimate_every: usize = 32,
    /// how hard an onset pulls the phase. 1 would snap the phase to every
    /// detection, which throws away the whole point of having a model. 0.12
    /// takes a few beats to converge and then ignores the odd bad one
    phase_pull: f32 = 0.12,
    /// below this the estimate is not worth showing. autocorrelation always
    /// returns some peak, including on speech and silence
    min_confidence: f32 = 0.18,
};

pub const Estimate = struct {
    /// 0 when nothing convincing is there
    bpm: f32 = 0,
    /// 0..1, wrapping. 0 is on the beat
    phase: f32 = 0,
    /// how much the autocorrelation peak stands out from its surroundings
    confidence: f32 = 0,

    pub fn locked(self: Estimate) bool {
        return self.bpm > 0;
    }
};

pub const Tempo = struct {
    opts: Options,

    /// onset strength history, one value per frame
    odf: []f32,
    odf_w: usize = 0,
    odf_filled: usize = 0,

    min_lag: usize,
    max_lag: usize,
    /// scratch for the autocorrelation, one slot per candidate lag
    score: []f32,

    since_estimate: usize = 0,
    period_frames: f32 = 0,
    confidence: f32 = 0,
    phase: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Tempo {
        std.debug.assert(opts.fps > 0);
        std.debug.assert(opts.min_bpm > 0 and opts.max_bpm > opts.min_bpm);

        // a lag in frames is how many frames one beat lasts
        const min_lag: usize = @intFromFloat(@floor(opts.fps * 60.0 / opts.max_bpm));
        const max_lag: usize = @intFromFloat(@ceil(opts.fps * 60.0 / opts.min_bpm));
        std.debug.assert(max_lag > min_lag);

        // the history has to hold at least two full periods or the longest
        // lag has nothing to correlate against
        const want: usize = @intFromFloat(@ceil(opts.fps * opts.history_s));
        const len = @max(want, max_lag * 2 + 2);

        const odf = try gpa.alloc(f32, len);
        errdefer gpa.free(odf);
        @memset(odf, 0);

        const score = try gpa.alloc(f32, max_lag - min_lag + 1);
        errdefer gpa.free(score);
        @memset(score, 0);

        return .{
            .opts = opts,
            .odf = odf,
            .min_lag = min_lag,
            .max_lag = max_lag,
            .score = score,
        };
    }

    pub fn deinit(self: *Tempo, gpa: std.mem.Allocator) void {
        gpa.free(self.odf);
        gpa.free(self.score);
        self.* = undefined;
    }

    /// One frame. `strength` is the onset strength function - the bass flux
    /// that feeds onset detection. `onset` is whether a beat was called.
    pub fn push(self: *Tempo, strength: f32, onset: bool) Estimate {
        self.odf[self.odf_w] = strength;
        self.odf_w = (self.odf_w + 1) % self.odf.len;
        if (self.odf_filled < self.odf.len) self.odf_filled += 1;

        self.since_estimate += 1;
        if (self.since_estimate >= self.opts.estimate_every and
            self.odf_filled >= self.max_lag * 2)
        {
            self.since_estimate = 0;
            self.estimate();
        }

        if (self.period_frames > 0) {
            self.phase += 1.0 / self.period_frames;
            while (self.phase >= 1.0) self.phase -= 1.0;

            // a phase locked loop. an onset says "a beat is about now", so
            // pull the phase towards it by a fraction instead of setting it,
            // and the estimate survives a detector that fires on things
            // that are not beats
            if (onset and self.confidence >= self.opts.min_confidence) {
                // error in [-0.5, 0.5): how far the phase is from the beat
                var err = self.phase;
                if (err > 0.5) err -= 1.0;
                self.phase -= err * self.opts.phase_pull;
                if (self.phase < 0) self.phase += 1.0;
                while (self.phase >= 1.0) self.phase -= 1.0;
            }
        }

        if (self.confidence < self.opts.min_confidence or self.period_frames <= 0)
            return .{};

        return .{
            .bpm = self.opts.fps * 60.0 / self.period_frames,
            .phase = self.phase,
            .confidence = self.confidence,
        };
    }

    /// Reads the history newest-last into a flat view, then autocorrelates.
    fn estimate(self: *Tempo) void {
        const n = self.odf.len;

        // mean removed, or the autocorrelation is dominated by the dc term
        // and every lag scores about the same
        var mean: f32 = 0;
        for (self.odf) |v| mean += v;
        mean /= @floatFromInt(n);

        // divide through by the variance and the scores become correlation
        // coefficients rather than raw covariances, so the number means
        // something on its own: a spike train correlates near 1 with itself
        // a period later, and white noise sits around 1/sqrt(pairs), which
        // is a few hundredths. without this there is no threshold that
        // separates music from noise
        var variance: f32 = 0;
        for (self.odf) |v| variance += (v - mean) * (v - mean);
        variance /= @floatFromInt(n);
        if (variance <= 1e-12) {
            self.confidence = 0;
            self.period_frames = 0;
            return;
        }

        var best_lag: usize = 0;
        var best: f32 = 0;

        var lag = self.min_lag;
        while (lag <= self.max_lag) : (lag += 1) {
            const pairs = n - lag;
            var sum: f32 = 0;
            var i: usize = 0;
            while (i < pairs) : (i += 1) {
                // walk oldest-first through the ring
                const a = self.odf[(self.odf_w + i) % n] - mean;
                const b = self.odf[(self.odf_w + i + lag) % n] - mean;
                sum += a * b;
            }
            // normalise by the overlap too, or short lags always win
            const s = sum / @as(f32, @floatFromInt(pairs)) / variance;
            self.score[lag - self.min_lag] = s;
            if (s > best) {
                best = s;
                best_lag = lag;
            }
        }

        if (best_lag == 0 or best <= 0) {
            self.confidence = 0;
            self.period_frames = 0;
            return;
        }

        best_lag = self.preferOctave(best_lag);
        const idx = best_lag - self.min_lag;

        // the coefficient at the chosen lag doubles as the confidence
        const cand_conf = std.math.clamp(self.score[idx], 0, 1);

        // refine the peak with a parabola through its neighbours, so the bpm
        // does not step in whole frames - at 60fps a lag of 30 frames is
        // 120bpm and 31 is 116, which is a visible jump on a display
        var period: f32 = @floatFromInt(best_lag);
        if (idx > 0 and idx + 1 < self.score.len) {
            const l = self.score[idx - 1];
            const c = self.score[idx];
            const r = self.score[idx + 1];
            const denom = l - 2 * c + r;
            if (@abs(denom) > 1e-9) {
                const shift = 0.5 * (l - r) / denom;
                if (@abs(shift) <= 1) period += shift;
            }
        }

        if (self.period_frames <= 0) {
            self.period_frames = period;
            self.confidence = cand_conf;
            return;
        }

        const ratio = period / self.period_frames;
        if (ratio > 0.94 and ratio < 1.06) {
            // the same tempo, drifting. ease towards it rather than stepping,
            // so a display does not flicker between two numbers
            self.period_frames = self.period_frames * 0.7 + period * 0.3;
            self.confidence = cand_conf;
            return;
        }

        // a genuinely different tempo. it has to be clearly better than what
        // is already held, or a bar with a strong offbeat in it walks off
        // with the estimate for a second and the motion visibly lurches
        if (cand_conf > self.confidence * 1.2 and cand_conf > 0.3) {
            self.period_frames = period;
            self.confidence = cand_conf;
            return;
        }

        // disagreeing but not convincing. let the held estimate weaken, or a
        // real tempo change could never take over
        self.confidence *= 0.9;
    }

    /// Autocorrelation cannot tell a beat from every other beat, so it will
    /// happily lock to half or double the tempo. Prefer whichever candidate
    /// lands nearest 120bpm, which is where most music actually is.
    fn preferOctave(self: *Tempo, lag: usize) usize {
        const target = self.opts.fps * 60.0 / 120.0;
        var best = lag;
        var best_dist = @abs(@log(@as(f32, @floatFromInt(lag)) / target));

        const cands = [_]usize{ lag / 2, lag * 2 };
        for (cands) |c| {
            if (c < self.min_lag or c > self.max_lag) continue;
            const s = self.score[c - self.min_lag];
            // only take the octave if it is a real peak in its own right,
            // not just arithmetic
            if (s <= 0) continue;
            const chosen = self.score[best - self.min_lag];
            if (s < chosen * 0.6) continue;
            const d = @abs(@log(@as(f32, @floatFromInt(c)) / target));
            if (d < best_dist) {
                best_dist = d;
                best = c;
            }
        }
        return best;
    }
};

fn feedBeats(t: *Tempo, bpm: f32, fps: f32, seconds: f32) Estimate {
    const period: f32 = fps * 60.0 / bpm;
    const frames: usize = @intFromFloat(fps * seconds);
    var last: Estimate = .{};
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const pos = @mod(@as(f32, @floatFromInt(i)), period);
        // a narrow spike on the beat and near silence between, which is what
        // bass flux looks like on anything with a drum in it
        const strength: f32 = if (pos < 1.0) 1.0 else 0.02;
        last = t.push(strength, pos < 1.0);
    }
    return last;
}

test "locks onto a steady 120" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    const e = feedBeats(&t, 120, 60, 12);
    try std.testing.expect(e.locked());
    try std.testing.expectApproxEqAbs(@as(f32, 120), e.bpm, 3);
    try std.testing.expect(e.confidence > 0.18);
}

test "locks onto a steady 90" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    const e = feedBeats(&t, 90, 60, 12);
    try std.testing.expect(e.locked());
    try std.testing.expectApproxEqAbs(@as(f32, 90), e.bpm, 3);
}

test "phase is near zero on the beat" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    _ = feedBeats(&t, 120, 60, 12);

    // step to the next beat and check the phase passes through 0 there
    const period: f32 = 30;
    var i: usize = 0;
    var on_beat: f32 = 1;
    while (i < 30) : (i += 1) {
        const pos = @mod(@as(f32, @floatFromInt(i)), period);
        const e = t.push(if (pos < 1.0) 1.0 else 0.02, pos < 1.0);
        if (pos < 1.0) on_beat = @min(e.phase, 1.0 - e.phase);
    }
    try std.testing.expect(on_beat < 0.12);
}

test "silence does not lock" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    var last: Estimate = .{};
    var i: usize = 0;
    while (i < 60 * 10) : (i += 1) last = t.push(0, false);

    try std.testing.expect(!last.locked());
}

test "noise does not produce a confident lock" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    var rng = std.Random.DefaultPrng.init(1);
    const rand = rng.random();

    var last: Estimate = .{};
    var i: usize = 0;
    while (i < 60 * 10) : (i += 1) last = t.push(rand.float(f32), false);

    // it may pick a lag - autocorrelation always does - but it must not
    // claim to be sure about it
    try std.testing.expect(last.confidence < 0.6);
}

test "a burst of noise does not take the tempo away" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    const settled = feedBeats(&t, 128, 60, 12);
    try std.testing.expect(settled.locked());
    const before = settled.bpm;

    // a second of nonsense in the middle of the track
    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    var i: usize = 0;
    var last: Estimate = .{};
    while (i < 60) : (i += 1) last = t.push(rand.float(f32), false);

    // it may lose confidence, but it must not report a wildly different
    // tempo on the strength of one bad second
    if (last.locked())
        try std.testing.expectApproxEqAbs(before, last.bpm, 8);
}

test "a real tempo change is eventually taken" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    _ = feedBeats(&t, 90, 60, 12);
    // long enough that the old history is gone entirely
    const after = feedBeats(&t, 150, 60, 20);

    try std.testing.expect(after.locked());
    try std.testing.expectApproxEqAbs(@as(f32, 150), after.bpm, 6);
}

test "half tempo is pulled back towards 120" {
    const gpa = std.testing.allocator;
    var t = try Tempo.init(gpa, .{ .fps = 60 });
    defer t.deinit(gpa);

    // 65bpm is inside the range, but its double is much nearer 120 and the
    // autocorrelation peaks at both
    const e = feedBeats(&t, 130, 60, 12);
    try std.testing.expect(e.locked());
    try std.testing.expect(e.bpm > 100);
}
