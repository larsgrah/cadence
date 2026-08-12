const std = @import("std");
const Frame = @import("analysis.zig").Frame;

pub const Format = enum {
    /// cava's raw ascii: one integer per band, semicolon separated, newline
    /// terminated. drop-in for anything already parsing a cava pipe
    cava,
    /// bands plus the things cava has no way to say
    jsonl,
    /// just the scalar, one float per line, for the amp consumer
    amp,
    /// `amp;strength;onset;bpm;phase;conf;b0;...;bN` as integers. everything
    /// is thousandths except onset (0 or 1) and bpm (tenths).
    ///
    /// jsonl is the nice one to read and the expensive one to parse - a QML
    /// consumer doing JSON.parse on it costs about 0.25% of a core per line
    /// per second, which puts 60fps out of reach. this exists so the scalars
    /// can be read off the front of the line without touching the bands
    @"packed",
};

/// 0..1 as 0..1000. three digits is well past what a bar or a shader
/// uniform can show, and it keeps the line to integers
fn milli(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 1000));
}

pub const Writer = struct {
    out: *std.Io.Writer,
    format: Format,
    /// cava's ascii_max_range
    max: u32 = 100,

    pub fn write(self: *Writer, f: Frame) !void {
        switch (self.format) {
            .cava => {
                for (f.bands) |v| {
                    const scaled: u32 = @intFromFloat(@round(std.math.clamp(v, 0, 1) * @as(f32, @floatFromInt(self.max))));
                    try self.out.print("{d};", .{scaled});
                }
                try self.out.writeByte('\n');
            },
            .jsonl => {
                try self.out.print("{{\"amp\":{d:.4},\"strength\":{d:.4},\"onset\":{}," ++
                    "\"bpm\":{d:.1},\"phase\":{d:.4},\"conf\":{d:.3},\"bands\":[", .{
                    f.amp, f.strength, f.onset, f.bpm, f.phase, f.tempo_conf,
                });
                for (f.bands, 0..) |v, i| {
                    if (i != 0) try self.out.writeByte(',');
                    try self.out.print("{d:.4}", .{v});
                }
                try self.out.writeAll("]}\n");
            },
            .amp => try self.out.print("{d:.4}\n", .{f.amp}),
            .@"packed" => {
                // bpm is tenths, so a display does not jitter between two
                // integers. everything else is thousandths
                try self.out.print("{d};{d};{d};{d};{d};{d}", .{
                    milli(f.amp),
                    milli(f.strength),
                    @intFromBool(f.onset),
                    @as(u32, @intFromFloat(@round(@max(f.bpm, 0) * 10))),
                    milli(f.phase),
                    milli(f.tempo_conf),
                });
                for (f.bands) |v| try self.out.print(";{d}", .{milli(v)});
                try self.out.writeByte('\n');
            },
        }
        try self.out.flush();
    }
};
