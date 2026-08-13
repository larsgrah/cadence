const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the dsp half. no system deps, so it builds and tests anywhere
    const mod = b.addModule("cadence", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // audio out, which is pipewire and therefore not part of the dsp module.
    // its own module rather than a library artifact, so a dependent imports
    // it and gets the C, the include path and the system libs with it
    const playback = b.addModule("playback", .{
        .root_source_file = b.path("src/playback.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    playback.linkSystemLibrary("libpipewire-0.3", .{});
    playback.linkSystemLibrary("libspa-0.2", .{});
    playback.addIncludePath(b.path("src"));
    playback.addCSourceFile(.{
        .file = b.path("src/playback.c"),
        .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-Wall", "-Wextra" },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cadence", .module = mod },
        },
    });

    // pkg-config names, not soname - pipewire ships libpipewire-0.3.pc and
    // libspa-0.2.pc, and spa is header-only but carries the include path
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("libpipewire-0.3", .{});
    exe_mod.linkSystemLibrary("libspa-0.2", .{});

    // the pipewire client is C: translate-c cannot parse spa's json-core.h,
    // and the pod builder and _events structs are macro soup anyway
    exe_mod.addIncludePath(b.path("src"));
    exe_mod.addCSourceFile(.{
        .file = b.path("src/capture.c"),
        // gnu11 and _GNU_SOURCE, not c11: spa/utils/string.h uses locale_t,
        // which strict ansi hides, and strndup needs it too
        .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-Wall", "-Wextra" },
    });

    const exe = b.addExecutable(.{
        .name = "cadence",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cadence");
    run_step.dependOn(&run_cmd.step);

    // only the dsp module, so this works without the pipewire headers
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run the dsp tests");
    test_step.dependOn(&run_mod_tests.step);
}
