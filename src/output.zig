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
};

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
        }
        try self.out.flush();
    }
};
