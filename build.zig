const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The behavior-bearing source: tested per-file below, and hashed into the build
    // fingerprint above.
    const source_files = [_][]const u8{
        "src/root.zig",
        "src/protocol.zig",
        "src/gateway.zig",
        "src/browser.zig",
        "src/process.zig",
        "src/tab.zig",
        "src/cdp.zig",
        "src/websocket.zig",
        "src/marionette.zig",
        "src/grab.zig",
        "src/push.zig",
    };

    // Build fingerprint — a hash of the source contents (all of the above plus
    // main.zig). The gateway daemon and CLI are the same binary, so any source
    // change gives a new value; the daemon reports it on every response and the CLI
    // warns (never refuses) when the running daemon differs from the binary on disk.
    // Content-hashed rather than git-derived: it needs no child process (zig's macOS
    // build env breaks the git xcode shim) and catches uncommitted edits too.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "build_id", buildId(b, &source_files));

    // Library module — importable by other Zig programs as "hibrow"
    const hibrow_mod = b.addModule("hibrow", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hibrow_mod.addOptions("build_info", build_info);

    // CLI executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("hibrow", hibrow_mod);
    exe_mod.addOptions("build_info", build_info);

    const exe = b.addExecutable(.{
        .name = "hibrow",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run step: `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the hibrow CLI");
    run_step.dependOn(&run_cmd.step);

    // Test step: runs tests from all source files
    const test_step = b.step("test", "Run all unit tests");

    for (source_files) |src| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        test_mod.addOptions("build_info", build_info);
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
        .link_libc = true,
    });
    main_test_mod.addImport("hibrow", hibrow_mod);
    main_test_mod.addOptions("build_info", build_info);
    const main_test = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_test = b.addRunArtifact(main_test);
    test_step.dependOn(&run_main_test.step);
}

/// Build fingerprint: a hash of the given source files plus src/main.zig, as hex.
/// Reads files from the build root via the build graph's Io (no child process), so
/// it works regardless of the macOS git/xcrun shim. Any missing file is skipped;
/// "unknown" if none could be read (then the skew check is simply inert).
fn buildId(b: *std.Build, source_files: []const []const u8) []const u8 {
    const io = b.graph.io;
    const dir = b.root.root_dir.handle;
    var h = std.hash.Wyhash.init(0);
    var any = false;
    const extra = [_][]const u8{"src/main.zig"};
    for (source_files) |f| hashFile(b, io, dir, f, &h, &any);
    for (extra) |f| hashFile(b, io, dir, f, &h, &any);
    if (!any) return "unknown";
    return b.fmt("{x}", .{h.final()});
}

fn hashFile(b: *std.Build, io: std.Io, dir: std.Io.Dir, path: []const u8, h: *std.hash.Wyhash, any: *bool) void {
    // Declare the read so a source change re-runs configure and regenerates the id;
    // without this, zig caches the stale build_id across rebuilds.
    b.dependOnFileContents(b.path(path));
    var buf: [1 << 20]u8 = undefined;
    const data = dir.readFile(io, path, &buf) catch return;
    h.update(data);
    any.* = true;
}
