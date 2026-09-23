const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Zig 0.16's standardOptimizeOption's preferred_optimize_mode only
    // applies when `-Drelease`/`--release=` is passed; a bare `zig build`
    // with no flags falls back to Debug regardless of that setting. We read
    // `-Doptimize=` ourselves and default to ReleaseSmall instead, so a
    // plain `zig build` produces an optimized exe (this is a small
    // background hotkey utility with no hot per-keystroke path now that the
    // WH_KEYBOARD_LL hook is gone - see CLAUDE.md - so there's nothing
    // speed-sensitive enough to prefer ReleaseFast). `-Doptimize=Debug` (or
    // ReleaseSafe/ReleaseFast) still overrides it. Note ReleaseSmall and
    // ReleaseFast both disable Zig's runtime safety checks; rebuild with
    // -Doptimize=Debug or ReleaseSafe to get a safety panic with a stack
    // trace if something crashes.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;

    // dbgLog (lightboard-debug.log) is on by default for Debug builds and
    // off by default otherwise, so a normal release build does no debug
    // file I/O. Pass -Dlog=true to force it on in a release build for
    // troubleshooting, or -Dlog=false to force it off in a debug build.
    const enable_debug_log = b.option(
        bool,
        "log",
        "Enable dbgLog file logging (default: on for Debug, off otherwise)",
    ) orelse (optimize == .Debug);
    const build_options = b.addOptions();
    build_options.addOption(bool, "debug_log", enable_debug_log);

    const exe = b.addExecutable(.{
        .name = "lightboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    exe.subsystem = .Windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run lightboard");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
