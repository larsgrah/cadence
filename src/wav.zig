//! Enough of RIFF to read a wav off disk and hand back mono floats.
//!
//! This is here so the dsp can be run on a real track instead of on a
//! synthetic spike train - onset thresholds and tempo behaviour are only
//! arguable against actual music. It reads what a wav is likely to be and
//! refuses the rest rather than guessing.

const std = @import("std");

pub const Error = error{
    NotRiff,
    NotWave,
    NoFormatChunk,
    BadFormatChunk,
    UnsupportedEncoding,
    UnsupportedBitDepth,
    NoChannels,
};

const tag_pcm = 1;
const tag_float = 3;
const tag_extensible = 0xFFFE;

pub const Encoding = enum { pcm, float };

pub const Decoder = struct {
    r: *std.Io.Reader,
    rate: u32,
    channels: u16,
    bits: u16,
    encoding: Encoding,
    /// bytes of sample data still to come, as the data chunk declared it
    remaining: u64,

    pub fn init(r: *std.Io.Reader) !Decoder {
        if (!std.mem.eql(u8, (try r.takeArray(4)), "RIFF")) return error.NotRiff;
        _ = try r.takeInt(u32, .little); // riff size, which plenty of writers get wrong
        if (!std.mem.eql(u8, (try r.takeArray(4)), "WAVE")) return error.NotWave;

        var rate: u32 = 0;
        var channels: u16 = 0;
        var bits: u16 = 0;
        var tag: u16 = 0;
        var have_fmt = false;

        // chunks in any order, and anything unrecognised skipped. LIST and
        // fact turn up in the wild often enough to matter
        while (true) {
            const id = (try r.takeArray(4)).*;
            const size = try r.takeInt(u32, .little);

            if (std.mem.eql(u8, &id, "fmt ")) {
                if (size < 16) return error.BadFormatChunk;
                tag = try r.takeInt(u16, .little);
                channels = try r.takeInt(u16, .little);
                rate = try r.takeInt(u32, .little);
                _ = try r.takeInt(u32, .little); // byte rate
                _ = try r.takeInt(u16, .little); // block align
                bits = try r.takeInt(u16, .little);

                var rest: u32 = size - 16;
                // anything above two channels is written as extensible, which
                // parks the real encoding in the first two bytes of a guid
                if (tag == tag_extensible and rest >= 24) {
                    _ = try r.takeInt(u16, .little); // extension size
                    _ = try r.takeInt(u16, .little); // valid bits
                    _ = try r.takeInt(u32, .little); // channel mask
                    tag = try r.takeInt(u16, .little);
                    rest -= 10;
                }
                try r.discardAll(rest + (rest & 1));
                have_fmt = true;
            } else if (std.mem.eql(u8, &id, "data")) {
                if (!have_fmt) return error.NoFormatChunk;
                if (channels == 0) return error.NoChannels;

                const encoding: Encoding = switch (tag) {
                    tag_pcm => .pcm,
                    tag_float => .float,
                    else => return error.UnsupportedEncoding,
                };
                switch (bits) {
                    8, 16, 24, 32 => {},
                    else => return error.UnsupportedBitDepth,
                }
                if (encoding == .float and bits != 32) return error.UnsupportedBitDepth;

                return .{
                    .r = r,
                    .rate = rate,
                    .channels = channels,
                    .bits = bits,
                    .encoding = encoding,
                    .remaining = size,
                };
            } else {
                // widened before the pad is added, or a chunk claiming
                // 0xFFFFFFFF overflows the add. chunks pad to even
                try r.discardAll(@as(usize, size) + (size & 1));
            }
        }
    }

    /// Fills `out` with mono samples and returns how many. Short only at the
    /// end of the file.
    pub fn read(self: *Decoder, out: []f32) !usize {
        const width = self.bits / 8;
        const frame = width * @as(usize, self.channels);

        var n: usize = 0;
        while (n < out.len and self.remaining >= frame) {
            var sum: f32 = 0;
            for (0..self.channels) |_| {
                const raw = self.r.take(width) catch |e| switch (e) {
                    // a data size that overruns the file is common enough not
                    // to be worth failing over
                    error.EndOfStream => {
                        self.remaining = 0;
                        return n;
                    },
                    else => return e,
                };
                sum += sample(raw, self.bits, self.encoding);
            }
            // averaged rather than summed, to match what the live path sees:
            // capture.c asks pipewire for one channel and lets audioconvert
            // do the downmix
            out[n] = sum / @as(f32, @floatFromInt(self.channels));
            n += 1;
            self.remaining -= frame;
        }
        return n;
    }

    /// The same, without the downmix. Fills `out` with interleaved frames and
    /// returns how many frames, so `out` wants room for a whole number of
    /// them.
    ///
    /// The analyzer has no use for this - it asks pipewire for one channel and
    /// averages a file to match. It is here for callers that are loading audio
    /// rather than measuring it, where throwing a stereo image away is not a
    /// simplification but a loss.
    pub fn readInterleaved(self: *Decoder, out: []f32) !usize {
        const width = self.bits / 8;
        const frame = width * @as(usize, self.channels);
        const want = out.len / self.channels;

        var n: usize = 0;
        while (n < want and self.remaining >= frame) {
            for (0..self.channels) |c| {
                const raw = self.r.take(width) catch |e| switch (e) {
                    error.EndOfStream => {
                        self.remaining = 0;
                        // a frame that ran out partway is not a frame
                        return n;
                    },
                    else => return e,
                };
                out[n * self.channels + c] = sample(raw, self.bits, self.encoding);
            }
            n += 1;
            self.remaining -= frame;
        }
        return n;
    }
};

fn sample(raw: []const u8, bits: u16, encoding: Encoding) f32 {
    if (encoding == .float) {
        return @bitCast(std.mem.readInt(u32, raw[0..4], .little));
    }
    return switch (bits) {
        // 8 bit is the odd one out and is unsigned, centred on 128
        8 => (@as(f32, @floatFromInt(raw[0])) - 128.0) / 128.0,
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, raw[0..2], .little))) / 32768.0,
        24 => blk: {
            const u = @as(u32, raw[0]) | (@as(u32, raw[1]) << 8) | (@as(u32, raw[2]) << 16);
            // sign extend the top bit into the word we actually have
            const v: i32 = if (u & 0x800000 != 0) @as(i32, @bitCast(u | 0xFF000000)) else @intCast(u);
            break :blk @as(f32, @floatFromInt(v)) / 8388608.0;
        },
        32 => @as(f32, @floatFromInt(std.mem.readInt(i32, raw[0..4], .little))) / 2147483648.0,
        else => unreachable,
    };
}

const testing = std.testing;

/// Builds a wav in memory. `data` goes in verbatim as the data chunk.
fn buildWav(buf: []u8, tag: u16, channels: u16, rate: u32, bits: u16, data: []const u8) []u8 {
    var w: usize = 0;
    const put = struct {
        fn s(b: []u8, at: *usize, v: []const u8) void {
            @memcpy(b[at.*..][0..v.len], v);
            at.* += v.len;
        }
        fn u16le(b: []u8, at: *usize, v: u16) void {
            std.mem.writeInt(u16, b[at.*..][0..2], v, .little);
            at.* += 2;
        }
        fn u32le(b: []u8, at: *usize, v: u32) void {
            std.mem.writeInt(u32, b[at.*..][0..4], v, .little);
            at.* += 4;
        }
    };

    put.s(buf, &w, "RIFF");
    put.u32le(buf, &w, 0); // deliberately wrong, nothing should read it
    put.s(buf, &w, "WAVE");

    put.s(buf, &w, "fmt ");
    put.u32le(buf, &w, 16);
    put.u16le(buf, &w, tag);
    put.u16le(buf, &w, channels);
    put.u32le(buf, &w, rate);
    put.u32le(buf, &w, rate * channels * bits / 8);
    put.u16le(buf, &w, channels * bits / 8);
    put.u16le(buf, &w, bits);

    put.s(buf, &w, "data");
    put.u32le(buf, &w, @intCast(data.len));
    put.s(buf, &w, data);

    return buf[0..w];
}

test "16 bit mono" {
    var buf: [256]u8 = undefined;
    var data: [8]u8 = undefined;
    std.mem.writeInt(i16, data[0..2], 0, .little);
    std.mem.writeInt(i16, data[2..4], 16384, .little);
    std.mem.writeInt(i16, data[4..6], -16384, .little);
    std.mem.writeInt(i16, data[6..8], -32768, .little);

    const bytes = buildWav(&buf, tag_pcm, 1, 44100, 16, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    try testing.expectEqual(@as(u32, 44100), d.rate);
    try testing.expectEqual(@as(u16, 1), d.channels);

    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), try d.read(&out));
    try testing.expectApproxEqAbs(@as(f32, 0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[3], 1e-6);

    // and it stays finished
    try testing.expectEqual(@as(usize, 0), try d.read(&out));
}

test "stereo averages down to mono" {
    var buf: [256]u8 = undefined;
    var data: [8]u8 = undefined;
    // one frame hard left, one frame the same both sides
    std.mem.writeInt(i16, data[0..2], 16384, .little);
    std.mem.writeInt(i16, data[2..4], 0, .little);
    std.mem.writeInt(i16, data[4..6], 16384, .little);
    std.mem.writeInt(i16, data[6..8], 16384, .little);

    const bytes = buildWav(&buf, tag_pcm, 2, 48000, 16, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try d.read(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1], 1e-4);
}

test "interleaved keeps the channels apart" {
    var buf: [256]u8 = undefined;
    var data: [8]u8 = undefined;
    // one frame hard left, one frame the same both sides
    std.mem.writeInt(i16, data[0..2], 16384, .little);
    std.mem.writeInt(i16, data[2..4], 0, .little);
    std.mem.writeInt(i16, data[4..6], 16384, .little);
    std.mem.writeInt(i16, data[6..8], 16384, .little);

    const bytes = buildWav(&buf, tag_pcm, 2, 48000, 16, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try d.readInterleaved(&out));
    // the same file that read() averages to 0.25 and 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[3], 1e-4);
}

test "interleaved stops on a whole frame" {
    var buf: [256]u8 = undefined;
    var data: [8]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(i16, data[i * 2 ..][0..2], 16384, .little);

    const bytes = buildWav(&buf, tag_pcm, 2, 48000, 16, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    // room for three samples is room for one stereo frame, not one and a half
    var out: [3]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try d.readInterleaved(&out));
    try testing.expectEqual(@as(usize, 1), try d.readInterleaved(&out));
    try testing.expectEqual(@as(usize, 0), try d.readInterleaved(&out));
}

test "32 bit float passes through" {
    var buf: [256]u8 = undefined;
    var data: [8]u8 = undefined;
    std.mem.writeInt(u32, data[0..4], @bitCast(@as(f32, 0.25)), .little);
    std.mem.writeInt(u32, data[4..8], @bitCast(@as(f32, -0.75)), .little);

    const bytes = buildWav(&buf, tag_float, 1, 48000, 32, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try d.read(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.75), out[1], 1e-6);
}

test "24 bit sign extends" {
    var buf: [256]u8 = undefined;
    // +0x400000 is a quarter up, -0x400000 a quarter down
    const data = [_]u8{ 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 };

    const bytes = buildWav(&buf, tag_pcm, 1, 48000, 24, &data);
    var r = std.Io.Reader.fixed(bytes);
    var d = try Decoder.init(&r);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), try d.read(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[1], 1e-4);
}

test "a chunk in the way gets skipped" {
    // LIST before fmt is normal in anything that has been tagged
    var buf: [256]u8 = undefined;
    var w: usize = 0;
    @memcpy(buf[0..12], "RIFF\x00\x00\x00\x00WAVE");
    w = 12;
    @memcpy(buf[w..][0..4], "LIST");
    w += 4;
    // odd length, so the pad byte has to be skipped too or fmt lands crooked
    std.mem.writeInt(u32, buf[w..][0..4], 5, .little);
    w += 4;
    @memcpy(buf[w..][0..6], "abcde\x00");
    w += 6;

    var rest: [128]u8 = undefined;
    var data: [2]u8 = undefined;
    std.mem.writeInt(i16, data[0..2], 16384, .little);
    const tail = buildWav(&rest, tag_pcm, 1, 22050, 16, &data);
    // splice everything past the tail's own RIFF/WAVE header on
    @memcpy(buf[w..][0 .. tail.len - 12], tail[12..]);
    w += tail.len - 12;

    var r = std.Io.Reader.fixed(buf[0..w]);
    var d = try Decoder.init(&r);
    try testing.expectEqual(@as(u32, 22050), d.rate);

    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 1), try d.read(&out));
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-4);
}

test "a chunk claiming four gigabytes is refused rather than overflowing" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..12], "RIFF\x00\x00\x00\x00WAVE");
    @memcpy(buf[12..16], "JUNK");
    std.mem.writeInt(u32, buf[16..20], 0xFFFFFFFF, .little);
    @memset(buf[20..], 0);

    var r = std.Io.Reader.fixed(&buf);
    try testing.expectError(error.EndOfStream, Decoder.init(&r));
}

test "not a wav is refused rather than guessed at" {
    var r = std.Io.Reader.fixed("this is not a wav file at all");
    try testing.expectError(error.NotRiff, Decoder.init(&r));
}

test "an encoding we cannot read is refused" {
    var buf: [256]u8 = undefined;
    const data = [_]u8{ 0, 0, 0, 0 };
    // 0x11 is ima adpcm, which is not going to decode as pcm
    const bytes = buildWav(&buf, 0x11, 1, 48000, 16, &data);
    var r = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.UnsupportedEncoding, Decoder.init(&r));
}
