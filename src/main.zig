///! hibrow CLI — browser multiplexer command-line interface.
///!
///! For every command:
///! 1. Connect to gateway socket (/tmp/hibrow-{uid}/gateway.sock)
///! 2. If connection fails → fork gateway into background, wait, retry
///! 3. Send JSON-RPC request, print result
const std = @import("std");
const hibrow = @import("hibrow");

const usage =
    \\Usage: hibrow <command> [options]
    \\
    \\Commands:
    \\  launch <profile> [--proxy <url>] [--proxy-dns]
    \\      Launch a new browser with the given profile name.
    \\
    \\  ls [profile]
    \\      List running browsers, or details for a specific profile.
    \\
    \\  nav <profile[:tab]> <url>
    \\      Navigate a browser tab to a URL.
    \\
    \\  eval <profile[:tab]> "<js>" | -f <file> | -f-
    \\      Evaluate JavaScript in a browser tab.
    \\
    \\  url <profile[:tab]>
    \\      Print the current URL of a browser tab.
    \\
    \\  console <profile[:tab]>
    \\      Stream console output from a browser tab.
    \\
    \\  tab list|new|close|switch <profile[:tab]>
    \\      Manage tabs within a browser profile.
    \\
    \\  gateway status
    \\      Show gateway daemon status.
    \\
    \\  gateway stop
    \\      Stop the gateway daemon.
    \\
    \\Options:
    \\  --help, -h    Show this help message.
    \\  --version     Show version information.
    \\
;

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip argv[0] (program name)
    _ = args.next();

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "--version")) {
        printVersion();
        return;
    }

    // Dispatch to command handlers
    if (std.mem.eql(u8, command, "launch")) {
        cmdLaunch(&args);
    } else if (std.mem.eql(u8, command, "ls")) {
        cmdList(&args);
    } else if (std.mem.eql(u8, command, "nav")) {
        cmdNavigate(&args);
    } else if (std.mem.eql(u8, command, "eval")) {
        cmdEval(&args);
    } else if (std.mem.eql(u8, command, "url")) {
        cmdUrl(&args);
    } else if (std.mem.eql(u8, command, "console")) {
        cmdConsole(&args);
    } else if (std.mem.eql(u8, command, "tab")) {
        cmdTab(&args);
    } else if (std.mem.eql(u8, command, "gateway")) {
        cmdGateway(&args);
    } else {
        var buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&buf);
        const stderr = &stderr_writer.interface;
        stderr.print("Unknown command: {s}\n\n", .{command}) catch {};
        stderr.flush() catch {};
        printUsage();
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

fn writeStdout(comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    stdout.print(fmt, fmt_args) catch {};
    stdout.flush() catch {};
}

fn writeStderr(comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const stderr = &stderr_writer.interface;
    stderr.print(fmt, fmt_args) catch {};
    stderr.flush() catch {};
}

// ---------------------------------------------------------------------------
// Command stubs
// ---------------------------------------------------------------------------

fn cmdLaunch(args: *std.process.ArgIterator) void {
    const profile = args.next() orelse {
        writeStderr("Error: launch requires a profile name\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: launch browser with profile \"{s}\"\n", .{profile});
}

fn cmdList(args: *std.process.ArgIterator) void {
    _ = args;
    writeStdout("TODO: list running browsers\n", .{});
}

fn cmdNavigate(args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: nav requires a profile[:tab] and URL\n", .{});
        std.process.exit(1);
    };
    const url = args.next() orelse {
        writeStderr("Error: nav requires a URL\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: navigate {s} to {s}\n", .{ target, url });
}

fn cmdEval(args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: eval requires a profile[:tab] and expression\n", .{});
        std.process.exit(1);
    };
    const expr = args.next() orelse {
        writeStderr("Error: eval requires a JavaScript expression\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: eval \"{s}\" in {s}\n", .{ expr, target });
}

fn cmdUrl(args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: url requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: print URL for {s}\n", .{target});
}

fn cmdConsole(args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: console requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: stream console for {s}\n", .{target});
}

fn cmdTab(args: *std.process.ArgIterator) void {
    const action = args.next() orelse {
        writeStderr("Error: tab requires an action (list|new|close|switch)\n", .{});
        std.process.exit(1);
    };
    writeStdout("TODO: tab {s}\n", .{action});
}

fn cmdGateway(args: *std.process.ArgIterator) void {
    const action = args.next() orelse {
        writeStderr("Error: gateway requires an action (status|stop)\n", .{});
        std.process.exit(1);
    };
    if (std.mem.eql(u8, action, "status")) {
        writeStdout("TODO: show gateway status\n", .{});
    } else if (std.mem.eql(u8, action, "stop")) {
        writeStdout("TODO: stop gateway daemon\n", .{});
    } else {
        writeStderr("Unknown gateway action: {s}\n", .{action});
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn printUsage() void {
    writeStdout("{s}", .{usage});
}

fn printVersion() void {
    writeStdout("hibrow {s}\n", .{version});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "usage string is non-empty" {
    try std.testing.expect(usage.len > 0);
}

test "version string is valid semver" {
    try std.testing.expectEqualStrings("0.1.0", version);
}

test "hibrow module is importable" {
    // Verify the hibrow library module is accessible from the CLI
    _ = hibrow.Client;
    _ = hibrow.protocol;
    _ = hibrow.gateway;
    _ = hibrow.browser;
    _ = hibrow.tab;
    _ = hibrow.cdp;
    _ = hibrow.websocket;
}
