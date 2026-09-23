const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
