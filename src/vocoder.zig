//! Phase vocoder. Time-stretch by reading frames out at a different rate than
//! they went in, pitch-shift by stretching and then resampling by the same
//! factor.
//!
//! The whole problem is phase. Magnitude can be moved between frames as-is,
//! but a bin's phase has to keep advancing at the rate the input said it was
//! advancing, over a hop that is now a different length. What the analysis
//! phase difference actually tells us is a frequency, and a frequency is what
//! survives a change of hop.

const std = @import("std");
const stft = @import("stft.zig");

const two_pi = 2.0 * std.math.pi;

/// Into [-pi, pi). Every phase difference has to go through this: `atan2`
/// only ever returns one turn's worth, so a bin advancing by more than half a
/// turn per hop comes back looking like it went backwards.
fn wrapPhase(x: f32) f32 {
    return x - two_pi * @round(x / two_pi);
}

pub const Options = struct {
    window: usize = 2048,
    /// The longer of the two hops. Stretching up shortens the analysis hop
    /// and stretching down shortens the synthesis one, so neither ever gets
    /// coarser than this.
    ///
    /// window/4 is the number that matters. Let a hop past it and that side
    /// gets thin: the synthesis overlap stops being flat and the level pulses
    /// with the frames, and the analysis overlap stops sampling the phase
    /// often enough to say what a bin is really doing.
    hop: usize = 512,
    /// output length over input length. 2 is half speed, same pitch
    stretch: f32 = 1.0,
    /// hold each partial's bins to the phase of the peak they belong to.
    /// off is the textbook vocoder, and it sounds like one - the bins of one
    /// partial drift out of step and what was a note turns into a smear
    lock: bool = true,
    /// snap phase back to the input when the spectrum jumps. a drum hit is
    /// the one thing a vocoder cannot interpolate its way through, and
    /// letting the accumulator carry on through it is what smears it
    reset_on_transient: bool = true,
    /// how far above its running mean the frame's flux has to jump
    transient_threshold: f32 = 2.5,
};

/// Time-stretch. Streams: push samples, get output blocks back.
pub const Stretch = struct {
    ana: stft.Analysis,
    syn: stft.Synthesis,

    n: usize,
    ana_hop: usize,
    syn_hop: usize,
    /// syn_hop over ana_hop, which is the stretch actually delivered. hops are
    /// whole samples, so this is near what was asked for and rarely equal
    ratio: f32,
    opts: Options,

    mag: []f32,
    phase: []f32,
    prev_phase: []f32,
    /// the running synthesis phase, one accumulator per bin
    sum_phase: []f32,
    prev_mag: []f32,
    peaks: []usize,

    flux_mean: f32 = 0,
    frames: usize = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Stretch {
        std.debug.assert(opts.stretch > 0);

        const n = opts.window;
        const hop: f32 = @floatFromInt(opts.hop);

        // whichever side is being spread out keeps the full hop, and the
        // other side shrinks. going the other way and letting one of them
        // grow is what costs the reconstruction
        const ana_hop: usize = if (opts.stretch >= 1)
            @intFromFloat(@round(hop / opts.stretch))
        else
            opts.hop;
        const syn_hop: usize = if (opts.stretch >= 1)
            opts.hop
        else
            @intFromFloat(@round(hop * opts.stretch));

        std.debug.assert(ana_hop >= 1 and ana_hop <= n);
        std.debug.assert(syn_hop >= 1 and syn_hop <= n);

        const half = n / 2 + 1;

        var self: Stretch = .{
            .ana = undefined,
            .syn = undefined,
            .n = n,
            .ana_hop = ana_hop,
            .syn_hop = syn_hop,
            .ratio = @as(f32, @floatFromInt(syn_hop)) / @as(f32, @floatFromInt(ana_hop)),
            .opts = opts,
            .mag = undefined,
            .phase = undefined,
            .prev_phase = undefined,
            .sum_phase = undefined,
            .prev_mag = undefined,
            .peaks = undefined,
        };

        self.ana = try stft.Analysis.init(gpa, n, ana_hop);
        errdefer self.ana.deinit(gpa);
        self.syn = try stft.Synthesis.init(gpa, n, syn_hop);
        errdefer self.syn.deinit(gpa);

        self.mag = try gpa.alloc(f32, half);
        errdefer gpa.free(self.mag);
        self.phase = try gpa.alloc(f32, half);
        errdefer gpa.free(self.phase);
        self.prev_phase = try gpa.alloc(f32, half);
        errdefer gpa.free(self.prev_phase);
        @memset(self.prev_phase, 0);
        self.sum_phase = try gpa.alloc(f32, half);
        errdefer gpa.free(self.sum_phase);
        @memset(self.sum_phase, 0);
        self.prev_mag = try gpa.alloc(f32, half);
        errdefer gpa.free(self.prev_mag);
        @memset(self.prev_mag, 0);
        self.peaks = try gpa.alloc(usize, half);

        return self;
    }

    pub fn deinit(self: *Stretch, gpa: std.mem.Allocator) void {
        self.ana.deinit(gpa);
        self.syn.deinit(gpa);
        gpa.free(self.mag);
        gpa.free(self.phase);
        gpa.free(self.prev_phase);
        gpa.free(self.sum_phase);
        gpa.free(self.prev_mag);
        gpa.free(self.peaks);
        self.* = undefined;
    }

    /// Feeds samples and calls `emit` with each block of output that comes
    /// out. Blocks are one synthesis hop long. The slice is only valid for
    /// the call.
    pub fn push(
        self: *Stretch,
        samples: []const f32,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []const f32) void,
    ) void {
        const Bridge = struct {
            st: *Stretch,
            inner: @TypeOf(ctx),

            fn onFrame(b: *@This(), re: []f32, im: []f32) void {
                b.st.retime(re, im);
                emit(b.inner, b.st.syn.add(re, im));
            }
        };
        var b: Bridge = .{ .st = self, .inner = ctx };
        self.ana.push(samples, &b, Bridge.onFrame);
    }

    /// Rewrites one spectrum in place so it belongs at the synthesis hop
    /// rather than the analysis one.
    fn retime(self: *Stretch, re: []f32, im: []f32) void {
        const half = self.n / 2;

        for (0..half + 1) |k| {
            self.mag[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
            self.phase[k] = std.math.atan2(im[k], re[k]);
        }

        self.frames += 1;
        if (self.frames == 1) {
            // nothing to advance from yet, so the first frame goes out as it
            // came in and just seeds the accumulators
            @memcpy(self.prev_phase, self.phase);
            @memcpy(self.sum_phase, self.phase);
            @memcpy(self.prev_mag, self.mag);
            return;
        }

        const reset = self.transient();

        for (0..half + 1) |k| {
            // where the bin would be if it sat exactly on its own centre
            // frequency and nothing else was going on
            const centre = two_pi * @as(f32, @floatFromInt(k)) *
                @as(f32, @floatFromInt(self.ana_hop)) / @as(f32, @floatFromInt(self.n));
            // whatever it did on top of that is the bin's real frequency,
            // which is the part that has to be rescaled to the new hop
            const dev = wrapPhase(self.phase[k] - self.prev_phase[k] - centre);
            self.prev_phase[k] = self.phase[k];

            if (reset) {
                self.sum_phase[k] = self.phase[k];
            } else {
                self.sum_phase[k] += (centre + dev) * self.ratio;
            }
        }

        // a reset already put every bin on the input's phase, which is as
        // locked as it gets
        if (self.opts.lock and !reset) self.lockToPeaks(half);

        for (0..half + 1) |k| {
            re[k] = self.mag[k] * @cos(self.sum_phase[k]);
            im[k] = self.mag[k] * @sin(self.sum_phase[k]);
        }
        // dc and nyquist are real, and the rest mirrors, or the inverse comes
        // back with an imaginary half and the output is not a signal
        im[0] = 0;
        im[half] = 0;
        for (1..half) |k| {
            re[self.n - k] = re[k];
            im[self.n - k] = -im[k];
        }
    }

    /// A partial wider than one bin lands in a peak and its neighbours, and
    /// they are all the same sinusoid. Advancing them independently lets them
    /// drift apart, which is the phasiness a plain vocoder is known for. So
    /// only peaks advance, and every other bin is placed at the offset from
    /// its peak that it arrived with.
    fn lockToPeaks(self: *Stretch, half: usize) void {
        var count: usize = 0;
        var k: usize = 1;
        while (k < half) : (k += 1) {
            if (self.mag[k] > self.mag[k - 1] and self.mag[k] >= self.mag[k + 1]) {
                self.peaks[count] = k;
                count += 1;
            }
        }
        if (count == 0) return;

        for (0..count) |i| {
            const p = self.peaks[i];
            // a bin belongs to whichever peak is nearer, so the boundary sits
            // halfway between one peak and the next
            const lo = if (i == 0) 0 else (self.peaks[i - 1] + p + 1) / 2;
            const hi = if (i + 1 == count) half + 1 else (p + self.peaks[i + 1] + 1) / 2;

            var b = lo;
            while (b < hi) : (b += 1) {
                if (b == p) continue;
                self.sum_phase[b] = self.sum_phase[p] + (self.phase[b] - self.phase[p]);
            }
        }
    }

    /// Positive magnitude flux against its own running mean. Same idea as the
    /// onset detector in analysis.zig, over the whole spectrum, and kept here
    /// so a stretch does not need an Analyzer bolted to it.
    fn transient(self: *Stretch) bool {
        var flux: f32 = 0;
        for (self.mag, self.prev_mag) |m, pm| {
            const d = m - pm;
            if (d > 0) flux += d;
        }
        @memcpy(self.prev_mag, self.mag);

        const mean = self.flux_mean;
        self.flux_mean = self.flux_mean * 0.9 + flux * 0.1;

        if (!self.opts.reset_on_transient) return false;
        // the mean needs a few frames before it means anything, or the first
        // sound of the run reads as a transient
        if (self.frames < 8) return false;
        return flux > mean * self.opts.transient_threshold and flux > 1e-6;
    }
};

/// Cubic resampling. Not the interesting half of a pitch shift, but linear
/// interpolation audibly dulls the top end and this does not.
pub const Resampler = struct {
    /// input samples per output sample. above 1 reads faster, so the output
    /// is shorter and higher
    ratio: f32,
    /// the four samples the interpolation sits on, oldest first
    h: [4]f32 = @splat(0),
    /// how far into the h[1]..h[2] segment the next output falls
    frac: f32 = 0,
    out: []f32,
    n: usize = 0,

    pub fn init(gpa: std.mem.Allocator, ratio: f32) !Resampler {
        std.debug.assert(ratio > 0);
        return .{ .ratio = ratio, .out = try gpa.alloc(f32, 256) };
    }

    pub fn deinit(self: *Resampler, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
        self.* = undefined;
    }

    /// Catmull-Rom through the four points, at `t` between h[1] and h[2].
    fn interp(h: [4]f32, t: f32) f32 {
        const a = 2 * h[1];
        const b = h[2] - h[0];
        const c = 2 * h[0] - 5 * h[1] + 4 * h[2] - h[3];
        const d = 3 * (h[1] - h[2]) + h[3] - h[0];
        return 0.5 * (a + t * (b + t * (c + t * d)));
    }

    pub fn push(
        self: *Resampler,
        samples: []const f32,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []const f32) void,
    ) void {
        for (samples) |x| {
            self.h[0] = self.h[1];
            self.h[1] = self.h[2];
            self.h[2] = self.h[3];
            self.h[3] = x;

            // every output landing inside the segment that just became
            // available. none of them at all when reading faster than 2x
            while (self.frac < 1.0) {
                self.out[self.n] = interp(self.h, self.frac);
                self.n += 1;
                if (self.n == self.out.len) {
                    emit(ctx, self.out);
                    self.n = 0;
                }
                self.frac += self.ratio;
            }
            self.frac -= 1.0;
        }
    }

    /// Hands over whatever is sitting in the buffer. Worth calling at the end
    /// of a run, pointless in the middle of one.
    pub fn flush(
        self: *Resampler,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []const f32) void,
    ) void {
        if (self.n == 0) return;
        emit(ctx, self.out[0..self.n]);
        self.n = 0;
    }
};

/// Pitch shift at the original length: stretch by the factor, then read the
/// result back at that same factor.
pub const Shift = struct {
    stretch: Stretch,
    resampler: Resampler,

    /// What the pitch actually gets multiplied by. The stretch is quantised
    /// to whole-sample hops, so this is near what was asked for.
    factor: f32,

    pub fn init(gpa: std.mem.Allocator, opts: Options, pitch: f32) !Shift {
        std.debug.assert(pitch > 0);

        var o = opts;
        o.stretch = pitch;

        var st = try Stretch.init(gpa, o);
        errdefer st.deinit(gpa);

        // resample by what the stretch delivered rather than by what was
        // asked for, or the length drifts
        return .{
            .stretch = st,
            .resampler = try Resampler.init(gpa, st.ratio),
            .factor = st.ratio,
        };
    }

    pub fn deinit(self: *Shift, gpa: std.mem.Allocator) void {
        self.stretch.deinit(gpa);
        self.resampler.deinit(gpa);
        self.* = undefined;
    }

    pub fn push(
        self: *Shift,
        samples: []const f32,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []const f32) void,
    ) void {
        const Bridge = struct {
            sh: *Shift,
            inner: @TypeOf(ctx),

            fn onBlock(b: *@This(), block: []const f32) void {
                b.sh.resampler.push(block, b.inner, emit);
            }
        };
        var b: Bridge = .{ .sh = self, .inner = ctx };
        self.stretch.push(samples, &b, Bridge.onBlock);
    }

    pub fn flush(
        self: *Shift,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []const f32) void,
    ) void {
        self.resampler.flush(ctx, emit);
    }
};

const Collect = struct {
    buf: []f32,
    n: usize = 0,

    fn take(self: *Collect, block: []const f32) void {
        const room = @min(block.len, self.buf.len - self.n);
        @memcpy(self.buf[self.n..][0..room], block[0..room]);
        self.n += room;
    }
};

fn sine(buf: []f32, hz: f32, rate: f32) void {
    for (buf, 0..) |*v, i| {
        v.* = @sin(two_pi * hz * @as(f32, @floatFromInt(i)) / rate);
    }
}

fn rms(buf: []const f32) f32 {
    var s: f32 = 0;
    for (buf) |v| s += v * v;
    return @sqrt(s / @as(f32, @floatFromInt(buf.len)));
}

/// Crossings per second. For a clean sinusoid that is twice the frequency,
/// which is enough to tell whether a shift moved the pitch and by how much.
fn crossingHz(buf: []const f32, rate: f32) f32 {
    var n: usize = 0;
    for (1..buf.len) |i| {
        if ((buf[i - 1] < 0) != (buf[i] < 0)) n += 1;
    }
    const secs = @as(f32, @floatFromInt(buf.len)) / rate;
    return @as(f32, @floatFromInt(n)) / secs / 2.0;
}

test "a stretch of one is the identity" {
    // the phase advance that comes out of a frame is exactly the one that
    // went in, so a unity stretch has to reproduce the signal. if this fails
    // nothing else in here means anything
    const gpa = std.testing.allocator;
    const total = 16384;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 437.0, 48000.0);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);
    @memset(out, 0);

    var st = try Stretch.init(gpa, .{ .stretch = 1.0 });
    defer st.deinit(gpa);

    var c: Collect = .{ .buf = out };
    st.push(in, &c, Collect.take);

    try std.testing.expectEqual(@as(usize, 512), st.ana_hop);
    try std.testing.expect(c.n > 8192);
    for (512..c.n) |i| try std.testing.expectApproxEqAbs(in[i], out[i], 1e-3);
}

test "stretching by two doubles the length and leaves the pitch alone" {
    const gpa = std.testing.allocator;
    const rate: f32 = 48000;
    const total = 48000;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 440.0, rate);

    const out = try gpa.alloc(f32, total * 3);
    defer gpa.free(out);
    @memset(out, 0);

    var st = try Stretch.init(gpa, .{ .stretch = 2.0 });
    defer st.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 256), st.ana_hop);

    var c: Collect = .{ .buf = out };
    st.push(in, &c, Collect.take);

    // one output hop per input hop, and there are twice as many of the latter
    const want = total * 2;
    try std.testing.expect(c.n > want - 4096 and c.n < want + 4096);

    // well clear of the window opening at one end and running dry at the other
    const mid = out[20000..70000];
    try std.testing.expectApproxEqAbs(@as(f32, 440), crossingHz(mid, rate), 5);
    // a unit sine is 1/sqrt(2). crossings alone would be just as happy with
    // something far too quiet, as long as it crossed on schedule
    try std.testing.expectApproxEqAbs(@as(f32, 0.707), rms(mid), 0.03);
}

test "halving the length leaves the pitch alone too" {
    const gpa = std.testing.allocator;
    const rate: f32 = 48000;
    const total = 48000;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 440.0, rate);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);
    @memset(out, 0);

    var st = try Stretch.init(gpa, .{ .stretch = 0.5 });
    defer st.deinit(gpa);
    // the synthesis side is the one that shrinks going down
    try std.testing.expectEqual(@as(usize, 512), st.ana_hop);
    try std.testing.expectEqual(@as(usize, 256), st.syn_hop);

    var c: Collect = .{ .buf = out };
    st.push(in, &c, Collect.take);

    const want = total / 2;
    try std.testing.expect(c.n > want - 4096 and c.n < want + 4096);
    const mid = out[4000..20000];
    try std.testing.expectApproxEqAbs(@as(f32, 440), crossingHz(mid, rate), 5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.707), rms(mid), 0.03);
}

test "a shift moves the pitch and keeps the length" {
    const gpa = std.testing.allocator;
    const rate: f32 = 48000;
    const total = 48000;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 300.0, rate);

    const out = try gpa.alloc(f32, total * 2);
    defer gpa.free(out);
    @memset(out, 0);

    var sh = try Shift.init(gpa, .{}, 1.5);
    defer sh.deinit(gpa);

    var c: Collect = .{ .buf = out };
    sh.push(in, &c, Collect.take);
    sh.flush(&c, Collect.take);

    // stretched by 1.5 then read back at 1.5, so the length comes home
    try std.testing.expect(c.n > total - 6000 and c.n < total + 6000);
    const mid = out[10000..40000];
    try std.testing.expectApproxEqAbs(300.0 * sh.factor, crossingHz(mid, rate), 6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.707), rms(mid), 0.03);
}

test "shifting down works the same way" {
    const gpa = std.testing.allocator;
    const rate: f32 = 48000;
    const total = 48000;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 600.0, rate);

    const out = try gpa.alloc(f32, total * 2);
    defer gpa.free(out);
    @memset(out, 0);

    var sh = try Shift.init(gpa, .{}, 0.5);
    defer sh.deinit(gpa);

    var c: Collect = .{ .buf = out };
    sh.push(in, &c, Collect.take);
    sh.flush(&c, Collect.take);

    try std.testing.expect(c.n > total - 8000 and c.n < total + 8000);
    try std.testing.expectApproxEqAbs(600.0 * sh.factor, crossingHz(out[10000..40000], rate), 6);
}

test "phase locking does not cost the identity" {
    // locking rewrites every non-peak bin, so it is worth knowing it puts
    // them back exactly where they were when there is no retiming to do
    const gpa = std.testing.allocator;
    const total = 16384;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    for (in, 0..) |*v, i| {
        const t: f32 = @floatFromInt(i);
        v.* = 0.5 * @sin(two_pi * 437.0 * t / 48000.0) +
            0.3 * @sin(two_pi * 1310.5 * t / 48000.0);
    }

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);
    @memset(out, 0);

    var st = try Stretch.init(gpa, .{ .stretch = 1.0, .lock = true });
    defer st.deinit(gpa);

    var c: Collect = .{ .buf = out };
    st.push(in, &c, Collect.take);

    for (512..c.n) |i| try std.testing.expectApproxEqAbs(in[i], out[i], 1e-3);
}

test "silence stretches to silence" {
    const gpa = std.testing.allocator;
    const total = 16384;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    @memset(in, 0);

    const out = try gpa.alloc(f32, total * 3);
    defer gpa.free(out);
    @memset(out, 0);

    var st = try Stretch.init(gpa, .{ .stretch = 1.7 });
    defer st.deinit(gpa);

    var c: Collect = .{ .buf = out };
    st.push(in, &c, Collect.take);

    for (0..c.n) |i| try std.testing.expectApproxEqAbs(@as(f32, 0), out[i], 1e-6);
}

test "resampling at one ratio is a passthrough with a delay" {
    const gpa = std.testing.allocator;
    const total = 4096;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    sine(in, 437.0, 48000.0);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);
    @memset(out, 0);

    var r = try Resampler.init(gpa, 1.0);
    defer r.deinit(gpa);

    var c: Collect = .{ .buf = out };
    r.push(in, &c, Collect.take);
    r.flush(&c, Collect.take);

    // the interpolation sits on h[1], which is two samples behind the newest
    try std.testing.expectEqual(total, c.n);
    for (2..c.n) |i| try std.testing.expectApproxEqAbs(in[i - 2], out[i], 1e-4);
}
