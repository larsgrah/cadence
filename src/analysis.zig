const std = @import("std");
const Fft = @import("fft.zig").Fft;
const TempoMod = @import("tempo.zig");

pub const Scale = enum {
    /// raw magnitude. bass carries most of the energy in music, so the top
    /// two thirds of the spectrum sit in the single digits and the bar
    /// graph is a wall on the left and nothing else
    linear,
    /// magnitude in dB mapped over `floor_db`. this is what makes the high
    /// bands visible at all
    db,
};

pub const Odf = enum {
    /// positive magnitude change, summed. cheap, and blind to anything that
    /// arrives without getting louder
    flux,
    /// how far the bin that arrived sits from the one the last two frames
    /// predicted. a note that starts under a note already ringing, or a chord
    /// that changes at a steady level, moves phase without moving magnitude,
    /// and flux cannot see either
    complex,
};

pub const Options = struct {
    rate: u32 = 48000,
    /// fft size. 2048 at 48k is a 42.7ms window, so the 23.4Hz bins actually
    /// resolve the low end the aurora rides on. 1024 puts 40Hz in bin 0.
    window: usize = 2048,
    /// samples between frames. 480 at 48k is a frame every 10ms
    hop: usize = 480,
    bands: usize = 44,
    low_hz: f32 = 40,
    high_hz: f32 = 12000,
    /// slow-decaying peak tracker, so output is 0..1 regardless of volume
    autogain: bool = true,
    /// onsets come from flux below this only. full-spectrum flux fires on
    /// every hi-hat, which is correct onset detection and useless for driving
    /// something that should look like it is following the beat. the kick
    /// lives under ~200Hz
    onset_hz: f32 = 200,
    /// what the onset detector and the tempo model run on.
    ///
    /// `flux` by default, and measured rather than assumed: below `onset_hz`
    /// every onset is a kick, a kick is a magnitude event, and `complex` has
    /// nothing left to add. On click tracks at 100, 128 and 140 the two agree
    /// to the millisecond, and on real tracks they land the same median tempo
    /// and trade which one jumps an octave more often. `complex` earns its
    /// keep somewhere with soft tonal onsets, which is not below 200Hz
    odf: Odf = .flux,
    /// how far above its running mean the onset strength has to jump
    onset_threshold: f32 = 1.8,
    /// silence after a hit, in ms. a kick has a tail and reports three times
    /// without it
    onset_refractory_ms: u32 = 110,
    scale: Scale = .db,
    /// how far below the running peak reads as zero. 45 keeps every band in
    /// motion. lower is punchier at the top and saturates the bass, higher
    /// lifts the whole graph off the floor and flattens it
    floor_db: f32 = 45,
};

fn dbNorm(v: f32, floor_db: f32) f32 {
    if (v <= 0) return 0;
    const db = 20.0 * std.math.log10(v);
    if (db <= -floor_db) return 0;
    if (db >= 0) return 1;
    return (db + floor_db) / floor_db;
}

/// One bin's worth of complex-domain onset strength. The last two frames
/// predict this one - magnitude holds where it was, phase keeps advancing at
/// the rate it was advancing - and what comes back is how far reality landed
/// from that guess.
///
/// The phases go in exactly as `atan2` returned them. Doubling one wrapped
/// angle and subtracting another lands on the right prediction modulo 2pi,
/// and cos and sin do not care which turn they are on, so nothing has to be
/// unwrapped here.
fn complexDeviation(re: f32, im: f32, prev_mag: f32, prev_phase: f32, prev2_phase: f32) f32 {
    const mag = @sqrt(re * re + im * im);
    // rectified: a note ending is as big a deviation as one starting, and
    // only one of them is an onset
    if (mag < prev_mag) return 0;

    const pred = 2 * prev_phase - prev2_phase;
    const dr = re - prev_mag * @cos(pred);
    const di = im - prev_mag * @sin(pred);
    return @sqrt(dr * dr + di * di);
}

pub const Frame = struct {
    /// per-band magnitude, 0..1 after gain
    bands: []const f32,
    /// whole-mix level, 0..1. not a band average - it is weighted low, since
    /// that is what reads as "loud" to an eye watching a background
    amp: f32,
    /// positive spectral flux this frame, 0..1 against its own history
    flux: f32,
    /// flux crossed the adaptive threshold and we are past the refractory gap
    onset: bool,
    /// estimated tempo, 0 when nothing convincing is there
    bpm: f32,
    /// 0..1 wrapping, 0 on the beat. only meaningful while `bpm` is nonzero
    phase: f32,
    /// how sure the tempo estimate is, 0..1
    tempo_conf: f32,
};

pub const Analyzer = struct {
    opts: Options,
    fft: Fft,

    ring: []f32,
    ring_w: usize = 0,
    filled: usize = 0,
    since_hop: usize = 0,

    win: []f32,
    re: []f32,
    im: []f32,
    mag: []f32,
    prev_mag: []f32,
    /// only the onset bins, since nothing above them uses phase
    prev_phase: []f32,
    prev2_phase: []f32,

    band_lo: []usize,
    band_hi: []usize,
    out_bands: []f32,

    /// ~0.6s of onset strength, the window the threshold averages over
    flux_hist: []f32,
    flux_peak: f32 = 1e-6,
    flux_w: usize = 0,
    flux_filled: usize = 0,

    peak: f32 = 1e-6,
    refractory: usize = 0,
    onset_bin: usize = 1,

    tempo: TempoMod.Tempo,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Analyzer {
        var self: Analyzer = .{
            .opts = opts,
            .fft = undefined,
            .ring = undefined,
            .win = undefined,
            .re = undefined,
            .im = undefined,
            .mag = undefined,
            .prev_mag = undefined,
            .prev_phase = undefined,
            .prev2_phase = undefined,
            .band_lo = undefined,
            .band_hi = undefined,
            .out_bands = undefined,
            .flux_hist = undefined,
            .tempo = undefined,
        };

        // bin 0 is dc and never belongs to a band. worked out up here because
        // the phase history is only as long as the onset bins
        const nyq_bins: f32 = @floatFromInt(opts.window / 2);
        const hz_per_bin = @as(f32, @floatFromInt(opts.rate)) / @as(f32, @floatFromInt(opts.window));
        self.onset_bin = @intFromFloat(@min(nyq_bins, @max(2.0, @ceil(opts.onset_hz / hz_per_bin))));

        self.fft = try Fft.init(gpa, opts.window);
        errdefer self.fft.deinit(gpa);

        self.ring = try gpa.alloc(f32, opts.window);
        @memset(self.ring, 0);
        self.win = try gpa.alloc(f32, opts.window);
        self.re = try gpa.alloc(f32, opts.window);
        self.im = try gpa.alloc(f32, opts.window);
        self.mag = try gpa.alloc(f32, opts.window / 2);
        self.prev_mag = try gpa.alloc(f32, opts.window / 2);
        @memset(self.prev_mag, 0);
        self.prev_phase = try gpa.alloc(f32, self.onset_bin);
        @memset(self.prev_phase, 0);
        self.prev2_phase = try gpa.alloc(f32, self.onset_bin);
        @memset(self.prev2_phase, 0);
        self.band_lo = try gpa.alloc(usize, opts.bands);
        self.band_hi = try gpa.alloc(usize, opts.bands);
        self.out_bands = try gpa.alloc(f32, opts.bands);
        @memset(self.out_bands, 0);

        const hist_len = @max(8, (opts.rate * 6 / 10) / opts.hop);
        self.flux_hist = try gpa.alloc(f32, hist_len);
        @memset(self.flux_hist, 0);

        // the tempo model runs on the same onset strength the detector uses,
        // one value per hop
        self.tempo = try TempoMod.Tempo.init(gpa, .{
            .fps = @as(f32, @floatFromInt(opts.rate)) / @as(f32, @floatFromInt(opts.hop)),
        });
        errdefer self.tempo.deinit(gpa);

        // hann. periodic rather than symmetric, since consecutive frames
        // overlap and a symmetric window double-counts the endpoint
        for (0..opts.window) |i| {
            const x = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(opts.window));
            self.win[i] = 0.5 - 0.5 * @cos(x);
        }

        // log-spaced band edges
        const log_lo = @log(opts.low_hz);
        const log_hi = @log(opts.high_hz);
        for (0..opts.bands) |b| {
            const f0 = @exp(log_lo + (log_hi - log_lo) * @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(opts.bands)));
            const f1 = @exp(log_lo + (log_hi - log_lo) * @as(f32, @floatFromInt(b + 1)) / @as(f32, @floatFromInt(opts.bands)));
            var lo: usize = @intFromFloat(@max(1.0, @floor(f0 / hz_per_bin)));
            var hi: usize = @intFromFloat(@min(nyq_bins - 1, @ceil(f1 / hz_per_bin)));
            // the bottom bands are narrower than one bin, so they would come
            // out empty. give every band at least one bin of its own
            if (hi <= lo) hi = lo + 1;
            if (hi > opts.window / 2) hi = opts.window / 2;
            if (lo >= hi) lo = hi - 1;
            self.band_lo[b] = lo;
            self.band_hi[b] = hi;
        }

        return self;
    }

    pub fn deinit(self: *Analyzer, gpa: std.mem.Allocator) void {
        self.fft.deinit(gpa);
        gpa.free(self.ring);
        gpa.free(self.win);
        gpa.free(self.re);
        gpa.free(self.im);
        gpa.free(self.mag);
        gpa.free(self.prev_mag);
        gpa.free(self.prev_phase);
        gpa.free(self.prev2_phase);
        gpa.free(self.band_lo);
        gpa.free(self.band_hi);
        gpa.free(self.out_bands);
        gpa.free(self.flux_hist);
        self.tempo.deinit(gpa);
        self.* = undefined;
    }

    /// Feeds mono samples and calls `emit` once per completed hop. Callers on
    /// the pipewire thread pass a callback rather than getting a value back,
    /// since one buffer can be worth several frames.
    pub fn push(
        self: *Analyzer,
        samples: []const f32,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), Frame) void,
    ) void {
        for (samples) |s| {
            self.ring[self.ring_w] = s;
            self.ring_w = (self.ring_w + 1) % self.ring.len;
            if (self.filled < self.ring.len) self.filled += 1;
            self.since_hop += 1;

            if (self.since_hop >= self.opts.hop and self.filled == self.ring.len) {
                self.since_hop = 0;
                emit(ctx, self.frame());
            }
        }
    }

    fn frame(self: *Analyzer) Frame {
        const n = self.opts.window;

        // ring_w is the oldest sample once the buffer is full
        for (0..n) |i| {
            self.re[i] = self.ring[(self.ring_w + i) % n] * self.win[i];
            self.im[i] = 0;
        }
        self.fft.forward(self.re, self.im);

        // `flux` is the reported one and stays magnitude only, full spectrum.
        // `strength` is what drives onsets and tempo, from the bass bins by
        // whichever odf is selected
        var flux: f32 = 0;
        var strength: f32 = 0;
        for (0..n / 2) |k| {
            const re = self.re[k];
            const im = self.im[k];
            const m = @sqrt(re * re + im * im);
            const d = m - self.prev_mag[k];
            if (d > 0) flux += d;

            if (k < self.onset_bin) {
                switch (self.opts.odf) {
                    .flux => if (d > 0) {
                        strength += d;
                    },
                    .complex => {
                        strength += complexDeviation(re, im, self.prev_mag[k], self.prev_phase[k], self.prev2_phase[k]);
                        self.prev2_phase[k] = self.prev_phase[k];
                        self.prev_phase[k] = std.math.atan2(im, re);
                    },
                }
            }

            self.prev_mag[k] = m;
            self.mag[k] = m;
        }

        var raw_peak: f32 = 0;
        for (0..self.opts.bands) |b| {
            var sum: f32 = 0;
            for (self.band_lo[b]..self.band_hi[b]) |k| sum += self.mag[k];
            const v = sum / @as(f32, @floatFromInt(self.band_hi[b] - self.band_lo[b]));
            self.out_bands[b] = v;
            raw_peak = @max(raw_peak, v);
        }

        // amp is tilted at the bottom third of the spectrum. a flat mean over
        // 44 bands is mostly hiss and barely moves on a kick
        var lowsum: f32 = 0;
        var lown: f32 = 0;
        const third = self.opts.bands / 3;
        for (0..self.opts.bands) |b| {
            const w: f32 = if (b < third) 1.0 else 0.35;
            lowsum += self.out_bands[b] * w;
            lown += w;
        }
        var amp = lowsum / lown;

        if (self.opts.autogain) {
            // rises instantly to a new peak, falls slowly, so a quiet passage
            // does not get normalised up into a wall
            self.peak = @max(self.peak * 0.9995, raw_peak);
            const g = @max(self.peak, 1e-6);
            for (self.out_bands) |*v| v.* = @min(1.0, v.* / g);
            amp = @min(1.0, amp / g);
        }

        if (self.opts.scale == .db) {
            for (self.out_bands) |*v| v.* = dbNorm(v.*, self.opts.floor_db);
            amp = dbNorm(amp, self.opts.floor_db);
        }

        const norm_flux = self.normalizedFlux(flux);
        const onset = self.detectOnset(strength);

        // the tempo model gets the same onset strength the detector saw, not
        // the boolean - a period comes out of the shape of the signal, and
        // thresholding it first throws most of that away
        const beat = self.tempo.push(strength, onset);

        return .{
            .bands = self.out_bands,
            .amp = amp,
            .flux = norm_flux,
            .onset = onset,
            .bpm = beat.bpm,
            .phase = beat.phase,
            .tempo_conf = beat.confidence,
        };
    }

    /// Full-spectrum flux against its own slow-decaying peak. It gets its own
    /// tracker rather than sharing the onset history, which is bass only.
    fn normalizedFlux(self: *Analyzer, flux: f32) f32 {
        self.flux_peak = @max(self.flux_peak * 0.999, flux);
        return @min(1.0, flux / @max(self.flux_peak, 1e-6));
    }

    fn detectOnset(self: *Analyzer, strength: f32) bool {
        const n = @min(self.flux_filled, self.flux_hist.len);
        var mean: f32 = 0;
        for (self.flux_hist[0..n]) |v| mean += v;
        if (n > 0) mean /= @floatFromInt(n);

        self.flux_hist[self.flux_w] = strength;
        self.flux_w = (self.flux_w + 1) % self.flux_hist.len;
        if (self.flux_filled < self.flux_hist.len) self.flux_filled += 1;

        if (self.refractory > 0) {
            self.refractory -= 1;
            return false;
        }
        // needs most of the history before a threshold means anything
        if (n < self.flux_hist.len / 2) return false;
        if (strength <= mean * self.opts.onset_threshold or strength <= 1e-5) return false;

        self.refractory = (self.opts.rate * self.opts.onset_refractory_ms / 1000) / self.opts.hop;
        return true;
    }
};

test "db mapping" {
    try std.testing.expectEqual(@as(f32, 0), dbNorm(0, 45));
    try std.testing.expectEqual(@as(f32, 1), dbNorm(1, 45));
    // half amplitude is about -6dB, so a hair under the top of a 45dB range
    try std.testing.expectApproxEqAbs(@as(f32, 0.866), dbNorm(0.5, 45), 0.005);
    // exactly at the floor, and below it
    try std.testing.expectApproxEqAbs(@as(f32, 0), dbNorm(0.00562, 45), 0.005);
    try std.testing.expectEqual(@as(f32, 0), dbNorm(0.0001, 45));
}

test "db scaling lifts the quiet bands off the floor" {
    // the whole reason the scale exists: a band 30dB down must not round to
    // nothing next to one at full scale
    try std.testing.expect(dbNorm(0.0316, 45) > 0.3);
    try std.testing.expect(dbNorm(0.0316, 45) < 0.4);
}

test "a bin holding steady deviates from its prediction by nothing" {
    // constant magnitude, constant phase advance. that is what a sustained
    // note looks like, and it must not read as an onset
    const mag: f32 = 3.0;
    const advance: f32 = 0.9;

    // wrapped exactly as atan2 would have left them, two and one frame back
    const prev2 = @mod(-2 * advance + std.math.pi, 2 * std.math.pi) - std.math.pi;
    const prev = @mod(-advance + std.math.pi, 2 * std.math.pi) - std.math.pi;

    const d = complexDeviation(mag, 0, mag, prev, prev2);
    try std.testing.expectApproxEqAbs(@as(f32, 0), d, 1e-4);
}

test "a phase change at a steady level is invisible to flux and loud here" {
    const mag: f32 = 3.0;
    const advance: f32 = 0.9;
    const prev2 = @mod(-2 * advance + std.math.pi, 2 * std.math.pi) - std.math.pi;
    const prev = @mod(-advance + std.math.pi, 2 * std.math.pi) - std.math.pi;

    // same magnitude, so `m - prev_mag` is zero and flux reports nothing at
    // all. the bin arrives half a turn from where it was going to be
    const d = complexDeviation(-mag, 0, mag, prev, prev2);
    try std.testing.expectApproxEqAbs(2 * mag, d, 1e-4);
}

test "a note ending is rectified away" {
    const d = complexDeviation(0, 0, 3.0, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), d);
}

test "band edges are ordered and in range" {
    const gpa = std.testing.allocator;
    var a = try Analyzer.init(gpa, .{ .bands = 44, .window = 2048, .rate = 48000 });
    defer a.deinit(gpa);

    for (0..44) |b| {
        try std.testing.expect(a.band_lo[b] >= 1);
        try std.testing.expect(a.band_hi[b] > a.band_lo[b]);
        try std.testing.expect(a.band_hi[b] <= 1024);
    }
    // log spacing, so edges never walk backwards
    for (1..44) |b| try std.testing.expect(a.band_lo[b] >= a.band_lo[b - 1]);
}

test "six bands over the amp range still get distinct bins" {
    const gpa = std.testing.allocator;
    var a = try Analyzer.init(gpa, .{ .bands = 6, .low_hz = 40, .high_hz = 4000 });
    defer a.deinit(gpa);
    for (0..6) |b| try std.testing.expect(a.band_hi[b] > a.band_lo[b]);
}

const Collect = struct {
    n: usize = 0,
    last: f32 = 0,
    fn take(self: *Collect, f: Frame) void {
        self.n += 1;
        self.last = f.amp;
    }
};

test "a hop of samples produces one frame once the window is full" {
    const gpa = std.testing.allocator;
    const opts: Options = .{ .window = 1024, .hop = 256, .bands = 8 };
    var a = try Analyzer.init(gpa, opts);
    defer a.deinit(gpa);

    var c: Collect = .{};
    var buf: [1024]f32 = undefined;
    for (0..1024) |i| {
        const t = 2.0 * std.math.pi * 440.0 * @as(f32, @floatFromInt(i)) / 48000.0;
        buf[i] = @sin(t) * 0.5;
    }

    // first window fills without emitting anything but the last hop
    a.push(&buf, &c, Collect.take);
    try std.testing.expectEqual(@as(usize, 1), c.n);

    // steady state: one frame per hop
    a.push(&buf, &c, Collect.take);
    try std.testing.expectEqual(@as(usize, 5), c.n);
    try std.testing.expect(c.last > 0.0);
}

test "a kick every half second fires onsets under either odf" {
    const gpa = std.testing.allocator;
    const rate: u32 = 48000;
    const total: usize = 48000 * 4;

    const in = try gpa.alloc(f32, total);
    defer gpa.free(in);

    // 60Hz with a fast decay, close enough to a kick that the detector has
    // the same job. one every half second
    const period: usize = 48000 / 2;
    for (in, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i % period)) / 48000.0;
        v.* = @exp(-t * 25.0) * @sin(2.0 * std.math.pi * 60.0 * t);
    }

    for ([_]Odf{ .flux, .complex }) |odf| {
        var a = try Analyzer.init(gpa, .{ .rate = rate, .odf = odf });
        defer a.deinit(gpa);

        const Count = struct {
            n: usize = 0,
            fn take(self: *@This(), f: Frame) void {
                if (f.onset) self.n += 1;
            }
        };
        var c: Count = .{};
        a.push(in, &c, Count.take);

        // eight kicks, less whatever the threshold spends warming up
        try std.testing.expect(c.n >= 5);
        try std.testing.expect(c.n <= 12);
    }
}

test "silence stays at zero and does not fire onsets" {
    const gpa = std.testing.allocator;
    var a = try Analyzer.init(gpa, .{ .window = 512, .hop = 128, .bands = 6 });
    defer a.deinit(gpa);

    const Count = struct {
        onsets: usize = 0,
        maxamp: f32 = 0,
        fn take(self: *@This(), f: Frame) void {
            if (f.onset) self.onsets += 1;
            self.maxamp = @max(self.maxamp, f.amp);
        }
    };
    var c: Count = .{};
    const quiet = [_]f32{0} ** 4096;
    for (0..8) |_| a.push(&quiet, &c, Count.take);

    try std.testing.expectEqual(@as(usize, 0), c.onsets);
    try std.testing.expectApproxEqAbs(@as(f32, 0), c.maxamp, 1e-6);
}
