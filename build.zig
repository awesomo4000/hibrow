const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — importable by other Zig programs as "hibrow"
    const hibrow_mod = b.addModule("hibrow", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("hibrow", hibrow_mod);

    const exe = b.addExecutable(.{
        .name = "hibrow",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step: `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the hibrow CLI");
    run_step.dependOn(&run_cmd.step);

    // Test step: runs tests from all source files
    const source_files = [_][]const u8{
        "src/root.zig",
        "src/protocol.zig",
        "src/gateway.zig",
        "src/transport.zig",
        "src/net_compat.zig",
        "src/browser.zig",
        "src/process.zig",
        "src/tab.zig",
        "src/cdp.zig",
        "src/websocket.zig",
        "src/marionette.zig",
        "src/grab.zig",
        "src/push.zig",
    };

    const test_step = b.step("test", "Run all unit tests");

    for (source_files) |src| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        const unit_test = b.addTest(.{
            .root_module = test_mod,
        });
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }

    // Also test main.zig (it imports hibrow module)
    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("hibrow", hibrow_mod);
    const main_test = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_test = b.addRunArtifact(main_test);
    test_step.dependOn(&run_main_test.step);
}
