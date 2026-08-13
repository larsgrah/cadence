//! Audio out, over the C client in playback.c.
//!
//! Kept out of the `cadence` module on purpose: that one is dsp and has no
//! system dependencies, so it builds and tests anywhere. This one links
//! pipewire, so anything importing it needs the headers.

const std = @import("std");

const Handle = opaque {};

extern fn cadence_play_open(name: [*:0]const u8, rate: u32, channels: u32, ring_frames: u32) ?*Handle;
extern fn cadence_play_start(p: *Handle) c_int;
extern fn cadence_play_space(p: *const Handle) u32;
extern fn cadence_play_write(p: *Handle, src: [*]const f32, frames: u32) u32;
extern fn cadence_play_pos(p: *const Handle) u64;
extern fn cadence_play_pause(p: *Handle, paused: c_int) void;
extern fn cadence_play_paused(p: *const Handle) c_int;
extern fn cadence_play_flush(p: *Handle) u64;
extern fn cadence_play_stop(p: *Handle) void;
extern fn cadence_play_close(p: *Handle) void;
extern fn cadence_play_error(p: *const Handle) [*:0]const u8;
extern fn cadence_play_underruns(p: *const Handle) u64;

pub const Options = struct {
    /// what a mixer shows this as
    name: [*:0]const u8 = "cadence",
    rate: u32 = 48000,
    channels: u32 = 2,
    /// how far ahead the writer may get. a power of two, and the cost of a
    /// seek, since everything queued behind the playhead is thrown away
    ring_frames: u32 = 1 << 15,
};

pub const Playback = struct {
    handle: *Handle,
    channels: u32,

    pub const Error = error{ PlaybackOpenFailed, PlaybackStartFailed };

    pub fn open(opts: Options) Error!Playback {
        const h = cadence_play_open(opts.name, opts.rate, opts.channels, opts.ring_frames) orelse
            return error.PlaybackOpenFailed;
        errdefer cadence_play_close(h);

        if (cadence_play_start(h) != 0) return error.PlaybackStartFailed;
        return .{ .handle = h, .channels = opts.channels };
    }

    pub fn close(self: *Playback) void {
        cadence_play_close(self.handle);
        self.* = undefined;
    }

    /// Frames of room.
    pub fn space(self: *const Playback) u32 {
        return cadence_play_space(self.handle);
    }

    /// Takes interleaved frames and returns how many it accepted, which is
    /// however many fit. Never blocks.
    pub fn write(self: *Playback, interleaved: []const f32) u32 {
        const frames: u32 = @intCast(interleaved.len / self.channels);
        if (frames == 0) return 0;
        return cadence_play_write(self.handle, interleaved.ptr, frames);
    }

    /// The frame of the written stream currently being heard.
    pub fn pos(self: *const Playback) u64 {
        return cadence_play_pos(self.handle);
    }

    pub fn setPaused(self: *Playback, paused: bool) void {
        cadence_play_pause(self.handle, @intFromBool(paused));
    }

    pub fn isPaused(self: *const Playback) bool {
        return cadence_play_paused(self.handle) != 0;
    }

    /// Drops everything queued and returns the position that will be reached
    /// once it has. Write from the new position after calling this.
    pub fn flush(self: *Playback) u64 {
        return cadence_play_flush(self.handle);
    }

    pub fn stop(self: *Playback) void {
        cadence_play_stop(self.handle);
    }

    /// Frames of silence the sink had to be given because we were late.
    pub fn underruns(self: *const Playback) u64 {
        return cadence_play_underruns(self.handle);
    }

    pub fn errorText(self: *const Playback) []const u8 {
        return std.mem.span(cadence_play_error(self.handle));
    }
};
