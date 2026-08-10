const std = @import("std");

/// Iterative in-place radix-2 FFT with precomputed twiddles. Size must be a
/// power of two. We feed it real audio with a zeroed imaginary half and only
/// read back the first n/2 magnitudes, which wastes about half the work - at
/// 2048 points a hundred times a second that is not worth a split-radix real
/// transform.
pub const Fft = struct {
    n: usize,
    tw_re: []f32,
    tw_im: []f32,
    rev: []u16,

    pub fn init(gpa: std.mem.Allocator, n: usize) !Fft {
        std.debug.assert(std.math.isPowerOfTwo(n));
        std.debug.assert(n <= 1 << 16);

        const tw_re = try gpa.alloc(f32, n / 2);
        errdefer gpa.free(tw_re);
        const tw_im = try gpa.alloc(f32, n / 2);
        errdefer gpa.free(tw_im);
        const rev = try gpa.alloc(u16, n);
        errdefer gpa.free(rev);

        for (0..n / 2) |k| {
            const a = -2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            tw_re[k] = @cos(a);
            tw_im[k] = @sin(a);
        }

        const bits: u5 = @intCast(std.math.log2_int(usize, n));
        for (0..n) |i| {
            var r: usize = 0;
            var b: u5 = 0;
            while (b < bits) : (b += 1) {
                r = (r << 1) | ((i >> b) & 1);
            }
            rev[i] = @intCast(r);
        }

        return .{ .n = n, .tw_re = tw_re, .tw_im = tw_im, .rev = rev };
    }

    pub fn deinit(self: *Fft, gpa: std.mem.Allocator) void {
        gpa.free(self.tw_re);
        gpa.free(self.tw_im);
        gpa.free(self.rev);
        self.* = undefined;
    }

    /// Transforms re/im in place. Both must be exactly n long.
    pub fn forward(self: *const Fft, re: []f32, im: []f32) void {
        std.debug.assert(re.len == self.n and im.len == self.n);

        for (0..self.n) |i| {
            const j = self.rev[i];
            if (i < j) {
                std.mem.swap(f32, &re[i], &re[j]);
                std.mem.swap(f32, &im[i], &im[j]);
            }
        }

        var len: usize = 2;
        while (len <= self.n) : (len <<= 1) {
            const step = self.n / len;
            var i: usize = 0;
            while (i < self.n) : (i += len) {
                var k: usize = 0;
                while (k < len / 2) : (k += 1) {
                    const wr = self.tw_re[k * step];
                    const wi = self.tw_im[k * step];
                    const a = i + k;
                    const b = a + len / 2;
                    const xr = re[b] * wr - im[b] * wi;
                    const xi = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - xr;
                    im[b] = im[a] - xi;
                    re[a] += xr;
                    im[a] += xi;
                }
            }
        }
    }
};

test "dc only" {
    const gpa = std.testing.allocator;
    var f = try Fft.init(gpa, 16);
    defer f.deinit(gpa);

    var re = [_]f32{1.0} ** 16;
    var im = [_]f32{0.0} ** 16;
    f.forward(&re, &im);

    try std.testing.expectApproxEqAbs(@as(f32, 16.0), re[0], 1e-4);
    for (1..16) |k| try std.testing.expectApproxEqAbs(@as(f32, 0.0), re[k], 1e-3);
}

test "single bin sinusoid lands in that bin" {
    const gpa = std.testing.allocator;
    const n = 64;
    var f = try Fft.init(gpa, n);
    defer f.deinit(gpa);

    var re: [n]f32 = undefined;
    var im = [_]f32{0.0} ** n;
    const bin = 5;
    for (0..n) |i| {
        const t = 2.0 * std.math.pi * @as(f32, @floatFromInt(bin * i)) / @as(f32, @floatFromInt(n));
        re[i] = @cos(t);
    }
    f.forward(&re, &im);

    for (0..n / 2) |k| {
        const mag = @sqrt(re[k] * re[k] + im[k] * im[k]);
        if (k == bin) {
            try std.testing.expect(mag > @as(f32, n) / 2.0 - 0.01);
        } else {
            try std.testing.expect(mag < 0.01);
        }
    }
}
