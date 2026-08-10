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
    /// `amp;flux;onset;b0;...;bN` as integers 0..1000, onset 0 or 1.
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
                try self.out.print("{{\"amp\":{d:.4},\"flux\":{d:.4},\"onset\":{},\"bands\":[", .{
                    f.amp, f.flux, f.onset,
                });
                for (f.bands, 0..) |v, i| {
                    if (i != 0) try self.out.writeByte(',');
                    try self.out.print("{d:.4}", .{v});
                }
                try self.out.writeAll("]}\n");
            },
            .amp => try self.out.print("{d:.4}\n", .{f.amp}),
            .@"packed" => {
                try self.out.print("{d};{d};{d}", .{
                    milli(f.amp), milli(f.flux), @intFromBool(f.onset),
                });
                for (f.bands) |v| try self.out.print(";{d}", .{milli(v)});
                try self.out.writeByte('\n');
            },
        }
        try self.out.flush();
    }
};
