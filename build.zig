const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "codex-zig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run codex-zig");
    run_step.dependOn(&run_cmd.step);

    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests_mod.linkSystemLibrary("sqlite3", .{});

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const tui_e2e_cmd = b.addSystemCommand(&.{ "python3", "scripts/tui_e2e.py" });
    tui_e2e_cmd.step.dependOn(b.getInstallStep());
    const app_server_e2e_cmd = b.addSystemCommand(&.{ "python3", "scripts/app_server_stdio_smoke.py" });
    app_server_e2e_cmd.step.dependOn(b.getInstallStep());
    const cli_e2e_cmd = b.addSystemCommand(&.{ "python3", "scripts/cli_smoke.py" });
    cli_e2e_cmd.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Run product-surface E2E smoke tests");
    e2e_step.dependOn(&tui_e2e_cmd.step);
    e2e_step.dependOn(&app_server_e2e_cmd.step);
    e2e_step.dependOn(&cli_e2e_cmd.step);
}
