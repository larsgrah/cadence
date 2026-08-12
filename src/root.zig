//! cadence - one pipewire capture, one fft, many consumers.
//!
//! This module is the dsp half and has no system dependencies, so it builds
//! and tests on its own. The pipewire client lives in `capture.zig` and is
//! only reachable from the executable.

pub const fft = @import("fft.zig");
pub const stft = @import("stft.zig");
pub const analysis = @import("analysis.zig");
pub const tempo = @import("tempo.zig");
pub const vocoder = @import("vocoder.zig");
pub const wav = @import("wav.zig");
pub const output = @import("output.zig");

pub const Fft = fft.Fft;
pub const Analyzer = analysis.Analyzer;
pub const Options = analysis.Options;
pub const Frame = analysis.Frame;
pub const Tempo = tempo.Tempo;
pub const Format = output.Format;

test {
    @import("std").testing.refAllDecls(@This());
}
