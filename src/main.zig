const std = @import("std");
const cadence = @import("cadence");

const c = @cImport({
    @cInclude("capture.h");
});

const usage =
    \\cadence - one pipewire capture, one fft, many consumers
    \\
    \\usage: cadence [options]
    \\
    \\  --format cava|jsonl|amp   output shape (default jsonl)
    \\  --target NAME             sink to follow (default: the default sink)
    \\  --bands N                 band count (default 44)
    \\  --low HZ                  lowest band edge (default 40)
    \\  --high HZ                 highest band edge (default 12000)
    \\  --rate HZ                 capture rate (default 48000)
    \\  --window N                fft size, power of two (default 2048)
    \\  --hop N                   samples between frames (default 480, so 100fps)
    \\  --max N                   cava format's integer range (default 100)
    \\  --onset-hz HZ             onsets use flux below this (default 200)
    \\  --onset-threshold X       times the running mean to fire (default 1.8)
    \\  --onset-refractory MS     silence after a hit (default 110)
    \\  --scale db|linear         band scaling (default db)
    \\  --floor DB                what reads as zero in db mode (default 45)
    \\  --no-autogain             emit raw magnitudes instead of 0..1
    \\  -h, --help                this
    \\
    \\A trailing ".monitor" on --target is stripped: cadence attaches to the
    \\sink itself, so the name to pass is the sink's.
    \\
;

const Emitter = struct {
    w: cadence.output.Writer,
    err: ?anyerror = null,

    fn emit(self: *Emitter, f: cadence.Frame) void {
        if (self.err != null) return;
        self.w.write(f) catch |e| {
            self.err = e;
        };
    }
};

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("cadence: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var opts: cadence.Options = .{};
    var format: cadence.Format = .jsonl;
    var max: u32 = 100;
    var target: ?[:0]const u8 = null;

    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        const Need = struct {
            fn val(i: *@TypeOf(it), name: []const u8, ioo: std.Io) [:0]const u8 {
                return i.next() orelse fatal(ioo, "{s} needs a value", .{name});
            }
        };
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var buf: [2048]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &buf);
            try w.interface.writeAll(usage);
            try w.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--format")) {
            const v = Need.val(&it, "--format", io);
            format = std.meta.stringToEnum(cadence.Format, v) orelse
                fatal(io, "unknown format '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = Need.val(&it, "--target", io);
        } else if (std.mem.eql(u8, arg, "--bands")) {
            opts.bands = std.fmt.parseInt(usize, Need.val(&it, "--bands", io), 10) catch
                fatal(io, "--bands wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--low")) {
            opts.low_hz = std.fmt.parseFloat(f32, Need.val(&it, "--low", io)) catch
                fatal(io, "--low wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--high")) {
            opts.high_hz = std.fmt.parseFloat(f32, Need.val(&it, "--high", io)) catch
                fatal(io, "--high wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--rate")) {
            opts.rate = std.fmt.parseInt(u32, Need.val(&it, "--rate", io), 10) catch
                fatal(io, "--rate wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--window")) {
            opts.window = std.fmt.parseInt(usize, Need.val(&it, "--window", io), 10) catch
                fatal(io, "--window wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--hop")) {
            opts.hop = std.fmt.parseInt(usize, Need.val(&it, "--hop", io), 10) catch
                fatal(io, "--hop wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--max")) {
            max = std.fmt.parseInt(u32, Need.val(&it, "--max", io), 10) catch
                fatal(io, "--max wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--onset-hz")) {
            opts.onset_hz = std.fmt.parseFloat(f32, Need.val(&it, "--onset-hz", io)) catch
                fatal(io, "--onset-hz wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--onset-threshold")) {
            opts.onset_threshold = std.fmt.parseFloat(f32, Need.val(&it, "--onset-threshold", io)) catch
                fatal(io, "--onset-threshold wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--onset-refractory")) {
            opts.onset_refractory_ms = std.fmt.parseInt(u32, Need.val(&it, "--onset-refractory", io), 10) catch
                fatal(io, "--onset-refractory wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const v = Need.val(&it, "--scale", io);
            opts.scale = std.meta.stringToEnum(cadence.analysis.Scale, v) orelse
                fatal(io, "unknown scale '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--floor")) {
            opts.floor_db = std.fmt.parseFloat(f32, Need.val(&it, "--floor", io)) catch
                fatal(io, "--floor wants a number", .{});
        } else if (std.mem.eql(u8, arg, "--no-autogain")) {
            opts.autogain = false;
        } else {
            fatal(io, "unknown option '{s}'\n\n{s}", .{ arg, usage });
        }
    }

    if (!std.math.isPowerOfTwo(opts.window))
        fatal(io, "--window must be a power of two, got {d}", .{opts.window});
    if (opts.hop == 0 or opts.hop > opts.window)
        fatal(io, "--hop must be between 1 and --window", .{});
    if (opts.bands == 0) fatal(io, "--bands must be at least 1", .{});
    if (opts.low_hz <= 0 or opts.high_hz <= opts.low_hz)
        fatal(io, "need 0 < --low < --high", .{});
    if (opts.high_hz > @as(f32, @floatFromInt(opts.rate)) / 2)
        fatal(io, "--high is above nyquist for --rate {d}", .{opts.rate});

    var analyzer = try cadence.Analyzer.init(gpa, opts);
    defer analyzer.deinit(gpa);

    // four windows of slack, so a scheduling hiccup on our side does not
    // cost samples
    const ring_frames: u32 = @intCast(std.math.ceilPowerOfTwoAssert(usize, opts.window * 4));

    const cap = c.cadence_open(if (target) |t| t.ptr else null, opts.rate, ring_frames) orelse
        fatal(io, "could not allocate the capture", .{});
    defer c.cadence_close(cap);

    if (c.cadence_start(cap) != 0)
        fatal(io, "{s}", .{c.cadence_error(cap)});

    var out_buf: [64 * 1024]u8 = undefined;
    var file_w = std.Io.File.stdout().writer(io, &out_buf);
    var emitter: Emitter = .{ .w = .{ .out = &file_w.interface, .format = format, .max = max } };

    const chunk = try gpa.alloc(f32, opts.window);
    defer gpa.free(chunk);

    while (true) {
        const n = c.cadence_read(cap, chunk.ptr, @intCast(chunk.len));
        if (n == 0) break;
        analyzer.push(chunk[0..n], &emitter, Emitter.emit);
        if (emitter.err) |e| {
            // the consumer went away. that is a normal way for this to end
            if (e == error.WriteFailed or e == error.BrokenPipe) break;
            return e;
        }
    }

    const err = c.cadence_error(cap);
    if (err[0] != 0) fatal(io, "{s}", .{err});

    // should be 0. anything else means the reader could not keep up with the
    // data thread, which at 100 frames a second would have to be the consumer
    const dropped = c.cadence_dropped(cap);
    if (dropped > 0) {
        var buf: [128]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("cadence: dropped {d} samples\n", .{dropped});
        try w.interface.flush();
    }
}
