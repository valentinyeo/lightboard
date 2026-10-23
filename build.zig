const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;

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

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clipboard.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const test_step = b.step("test", "Run clipboard policy tests on the build host");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const run_step = b.step("run", "Run lightboard");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
