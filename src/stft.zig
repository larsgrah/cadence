//! Windowed overlap-add STFT, split into the two halves an effect needs.
//! `Analysis` hands out complex spectra, `Synthesis` takes them back and
//! rebuilds a signal. Nothing is assumed about what happens in between, so a
//! caller can rewrite a spectrum, drop frames, or add them back at a
//! different rate than they arrived.
//!
//! `analysis.zig` does not use this. It only ever wants magnitudes and never
//! resynthesizes, so it keeps its own shorter path.

const std = @import("std");
const Fft = @import("fft.zig").Fft;

/// Periodic hann, the same window on both ends. Windowing twice is what lets
/// a modified spectrum overlap-add without seams at the frame edges.
fn hann(win: []f32) void {
    const n: f32 = @floatFromInt(win.len);
    for (win, 0..) |*v, i| {
        const x = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / n;
        v.* = 0.5 - 0.5 * @cos(x);
    }
}

fn checkSize(n: usize, hop: usize) void {
    std.debug.assert(std.math.isPowerOfTwo(n));
    std.debug.assert(hop > 0 and hop <= n);
}

/// How much window squared piles up on each output position when frames land
/// `hop` apart, over one hop of positions. Flat is what lets a *modified*
/// spectrum overlap-add without the level pulsing in time with the frames,
/// and hop = window/4 is where hann goes flat.
///
/// `Synthesis` does not use this - it divides by what actually landed, which
/// is exact for any hop. It is here because a caller picking a hop needs to
/// know, and because the difference is worth being able to point at.
fn overlapProfile(win: []const f32, hop: usize, out: []f32) void {
    std.debug.assert(out.len == hop);
    for (out, 0..) |*v, i| {
        var s: f32 = 0;
        var k = i;
        while (k < win.len) : (k += hop) s += win[k] * win[k];
        v.* = s;
    }
}

/// Windows the input and hands out one spectrum per hop.
pub const Analysis = struct {
    fft: Fft,
    n: usize,
    hop: usize,
    win: []f32,

    ring: []f32,
    ring_w: usize = 0,
    filled: usize = 0,
    since_hop: usize = 0,

    re: []f32,
    im: []f32,

    pub fn init(gpa: std.mem.Allocator, n: usize, hop: usize) !Analysis {
        checkSize(n, hop);

        var self: Analysis = .{
            .fft = undefined,
            .n = n,
            .hop = hop,
            .win = undefined,
            .ring = undefined,
            .re = undefined,
            .im = undefined,
        };

        self.fft = try Fft.init(gpa, n);
        errdefer self.fft.deinit(gpa);
        self.win = try gpa.alloc(f32, n);
        errdefer gpa.free(self.win);
        hann(self.win);
        self.ring = try gpa.alloc(f32, n);
        errdefer gpa.free(self.ring);
        @memset(self.ring, 0);
        self.re = try gpa.alloc(f32, n);
        errdefer gpa.free(self.re);
        self.im = try gpa.alloc(f32, n);

        return self;
    }

    pub fn deinit(self: *Analysis, gpa: std.mem.Allocator) void {
        self.fft.deinit(gpa);
        gpa.free(self.win);
        gpa.free(self.ring);
        gpa.free(self.re);
        gpa.free(self.im);
        self.* = undefined;
    }

    /// Feeds samples and calls `emit` once per completed hop. `re` and `im`
    /// are our scratch and only live for the length of the call, so anything
    /// worth keeping has to be copied. Writing to them in place is the point
    /// though - that is where an effect goes.
    pub fn push(
        self: *Analysis,
        samples: []const f32,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), []f32, []f32) void,
    ) void {
        for (samples) |s| {
            self.ring[self.ring_w] = s;
            self.ring_w = (self.ring_w + 1) % self.n;
            if (self.filled < self.n) self.filled += 1;
            self.since_hop += 1;

            if (self.since_hop >= self.hop and self.filled == self.n) {
                self.since_hop = 0;
                // ring_w is the oldest sample once the buffer is full
                for (0..self.n) |i| {
                    self.re[i] = self.ring[(self.ring_w + i) % self.n] * self.win[i];
                    self.im[i] = 0;
                }
                self.fft.forward(self.re, self.im);
                emit(ctx, self.re, self.im);
            }
        }
    }
};

/// Takes spectra back and overlap-adds them into a signal.
pub const Synthesis = struct {
    fft: Fft,
    n: usize,
    hop: usize,
    win: []f32,

    /// the live overlap region, exactly one window long and wrapping
    acc: []f32,
    /// how much window squared actually landed on each of those positions.
    /// dividing it back out at release is what returns the signal rather than
    /// a windowed version of it, and doing it from what accumulated rather
    /// than from a formula means any hop reconstructs, not just one that
    /// divides the window. the frames at the very start, with nothing yet
    /// overlapping them, come out right too
    wacc: []f32,
    acc_r: usize = 0,
    out: []f32,

    pub fn init(gpa: std.mem.Allocator, n: usize, hop: usize) !Synthesis {
        checkSize(n, hop);

        var self: Synthesis = .{
            .fft = undefined,
            .n = n,
            .hop = hop,
            .win = undefined,
            .acc = undefined,
            .wacc = undefined,
            .out = undefined,
        };

        self.fft = try Fft.init(gpa, n);
        errdefer self.fft.deinit(gpa);
        self.win = try gpa.alloc(f32, n);
        errdefer gpa.free(self.win);
        hann(self.win);
        self.acc = try gpa.alloc(f32, n);
        errdefer gpa.free(self.acc);
        @memset(self.acc, 0);
        self.wacc = try gpa.alloc(f32, n);
        errdefer gpa.free(self.wacc);
        @memset(self.wacc, 0);
        self.out = try gpa.alloc(f32, hop);

        return self;
    }

    pub fn deinit(self: *Synthesis, gpa: std.mem.Allocator) void {
        self.fft.deinit(gpa);
        gpa.free(self.win);
        gpa.free(self.acc);
        gpa.free(self.wacc);
        gpa.free(self.out);
        self.* = undefined;
    }

    /// Adds one frame and returns the hop samples that are finished as a
    /// result. The slice is ours and only valid until the next call. `re` and
    /// `im` are clobbered.
    ///
    /// The first hop of the whole run is where the window is still opening.
    /// It gets divided by very little and is not worth trusting - sample 0
    /// is gone outright, since the window starts at zero.
    pub fn add(self: *Synthesis, re: []f32, im: []f32) []const f32 {
        std.debug.assert(re.len == self.n and im.len == self.n);
        self.fft.inverse(re, im);

        for (0..self.n) |i| {
            const j = (self.acc_r + i) % self.n;
            self.acc[j] += re[i] * self.win[i];
            self.wacc[j] += self.win[i] * self.win[i];
        }

        // the next frame starts a hop along, so nothing behind that can still
        // be added to. take it out and clear it for the frame that reuses it
        for (0..self.hop) |i| {
            const j = (self.acc_r + i) % self.n;
            self.out[i] = if (self.wacc[j] > 1e-6) self.acc[j] / self.wacc[j] else 0;
            self.acc[j] = 0;
            self.wacc[j] = 0;
        }
        self.acc_r = (self.acc_r + self.hop) % self.n;

        return self.out;
    }
};

const RoundTrip = struct {
    syn: *Synthesis,
    buf: []f32,
    n: usize = 0,

    fn take(self: *RoundTrip, re: []f32, im: []f32) void {
        const done = self.syn.add(re, im);
        @memcpy(self.buf[self.n..][0..done.len], done);
        self.n += done.len;
    }
};

/// Analyses and immediately resynthesizes `in`, touching nothing between.
/// Returns how many samples came out, written to `out` at the same positions
/// they went in at.
fn identity(gpa: std.mem.Allocator, n: usize, hop: usize, in: []const f32, out: []f32) !usize {
    var ana = try Analysis.init(gpa, n, hop);
    defer ana.deinit(gpa);
    var syn = try Synthesis.init(gpa, n, hop);
    defer syn.deinit(gpa);

    @memset(out, 0);
    var rt: RoundTrip = .{ .syn = &syn, .buf = out };
    ana.push(in, &rt, RoundTrip.take);
    return rt.n;
}

fn testSignal(buf: []f32) void {
    // a few partials that are not on bin centres, so a bug that only survives
    // one bin or only survives exact bins does not pass
    for (buf, 0..) |*v, i| {
        const t: f32 = @floatFromInt(i);
        v.* = 0.5 * @sin(2.0 * std.math.pi * 437.0 * t / 48000.0) +
            0.3 * @sin(2.0 * std.math.pi * 1310.5 * t / 48000.0) +
            0.2 * @sin(2.0 * std.math.pi * 97.0 * t / 48000.0);
    }
}

test "analysis into synthesis gives the signal back" {
    const gpa = std.testing.allocator;
    const n = 256;
    const hop = n / 4;
    const total = 4096;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    testSignal(in);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);

    const got = try identity(gpa, n, hop, in, out);

    // exact from the first hop on, where the window has actually opened
    try std.testing.expect(got > hop + 1000);
    for (hop..got) |i| try std.testing.expectApproxEqAbs(in[i], out[i], 1e-4);
}

test "a hop that does not divide the window reconstructs just as well" {
    // dividing by what landed rather than by a formula is what buys this, and
    // the vocoder needs it: its analysis hop is whatever the stretch factor
    // works out to, not a neat fraction
    const gpa = std.testing.allocator;
    const n = 256;
    const hop = 100;
    const total = 4096;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    testSignal(in);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);

    const got = try identity(gpa, n, hop, in, out);
    for (hop..got) |i| try std.testing.expectApproxEqAbs(in[i], out[i], 1e-4);
}

test "hann at a quarter hop overlaps to a constant" {
    const gpa = std.testing.allocator;
    const n = 256;
    const hop = n / 4;

    const win = try gpa.alloc(f32, n);
    defer gpa.free(win);
    hann(win);
    const prof = try gpa.alloc(f32, hop);
    defer gpa.free(prof);
    overlapProfile(win, hop, prof);

    for (prof) |v| try std.testing.expectApproxEqAbs(@as(f32, 1.5), v, 1e-4);
}

test "a half hop does not, which is why it is the wrong synthesis hop" {
    const gpa = std.testing.allocator;
    const n = 256;
    const hop = n / 2;

    const win = try gpa.alloc(f32, n);
    defer gpa.free(win);
    hann(win);
    const prof = try gpa.alloc(f32, hop);
    defer gpa.free(prof);
    overlapProfile(win, hop, prof);

    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = 0;
    for (prof) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    // two hann windows half a period apart square and sum to 0.5 + 0.5cos,
    // so the window piles up twice as thick in places as in others
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lo, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hi, 1e-4);
}

test "silence in, silence out" {
    const gpa = std.testing.allocator;
    const total = 2048;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);
    @memset(in, 0);

    const out = try gpa.alloc(f32, total);
    defer gpa.free(out);

    const got = try identity(gpa, 256, 64, in, out);
    for (0..got) |i| try std.testing.expectApproxEqAbs(@as(f32, 0), out[i], 1e-6);
}
