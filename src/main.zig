///! hibrow CLI — browser multiplexer command-line interface.
///!
///! For every command:
///! 1. Connect to gateway socket (/tmp/hibrow-{uid}/gateway.sock)
///! 2. If connection fails → fork gateway into background, wait, retry
///! 3. Send JSON-RPC request, print result
const std = @import("std");
const json = std.json;
const mem = std.mem;
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
    \\  gateway serve
    \\      Run the gateway daemon (internal, used by auto-start).
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

    if (mem.eql(u8, command, "--help") or mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    if (mem.eql(u8, command, "--version")) {
        printVersion();
        return;
    }

    // Dispatch to command handlers
    if (mem.eql(u8, command, "launch")) {
        cmdLaunch(allocator, &args);
    } else if (mem.eql(u8, command, "ls")) {
        cmdList(allocator, &args);
    } else if (mem.eql(u8, command, "nav")) {
        cmdNavigate(allocator, &args);
    } else if (mem.eql(u8, command, "eval")) {
        cmdEval(allocator, &args);
    } else if (mem.eql(u8, command, "url")) {
        cmdUrl(allocator, &args);
    } else if (mem.eql(u8, command, "console")) {
        cmdConsole(allocator, &args);
    } else if (mem.eql(u8, command, "tab")) {
        cmdTab(allocator, &args);
    } else if (mem.eql(u8, command, "gateway")) {
        cmdGateway(allocator, &args);
    } else {
        writeStderr("Unknown command: {s}\n\n", .{command});
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

/// Print a json.Value to stdout using the JSON serializer.
fn printJsonValue(allocator: mem.Allocator, value: json.Value) void {
    const bytes = json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }) catch {
        writeStdout("null\n", .{});
        return;
    };
    defer allocator.free(bytes);
    writeStdout("{s}\n", .{bytes});
}

// ---------------------------------------------------------------------------
// Command implementations
// ---------------------------------------------------------------------------

fn cmdLaunch(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const profile = args.next() orelse {
        writeStderr("Error: launch requires a profile name\n", .{});
        std.process.exit(1);
    };

    // Parse optional flags
    var proxy: ?[]const u8 = null;
    var proxy_dns = false;
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--proxy")) {
            proxy = args.next() orelse {
                writeStderr("Error: --proxy requires a URL argument\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, arg, "--proxy-dns")) {
            proxy_dns = true;
        } else {
            writeStderr("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    var client = hibrow.Client.connect(allocator) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.launch(profile, .{
        .proxy = proxy,
        .proxy_dns = proxy_dns,
    }) catch |err| {
        writeStderr("Error: launch failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }

    printJsonValue(allocator, resp.result);
}

fn cmdList(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const profile = args.next();

    var client = hibrow.Client.connect(allocator) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    if (profile) |p| {
        // Get specific browser
        var resp = client.get(p) catch |err| {
            writeStderr("Error: browser.get failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    } else {
        // List all browsers
        var resp = client.list() catch |err| {
            writeStderr("Error: browser.list failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    }
}

fn cmdNavigate(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: nav requires a profile[:tab] and URL\n", .{});
        std.process.exit(1);
    };
    const url = args.next() orelse {
        writeStderr("Error: nav requires a URL\n", .{});
        std.process.exit(1);
    };

    // Parse profile from target (ignore :tab for now)
    const profile = parseProfile(target);

    var client = hibrow.Client.connect(allocator) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.navigate(profile, url) catch |err| {
        writeStderr("Error: navigate failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdEval(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: eval requires a profile[:tab] and expression\n", .{});
        std.process.exit(1);
    };

    const profile = parseProfile(target);

    // Get expression: positional arg, -f <file>, or -f- (stdin)
    const next_arg = args.next() orelse {
        writeStderr("Error: eval requires a JavaScript expression\n", .{});
        std.process.exit(1);
    };

    var expression: []const u8 = undefined;
    var owned_expr: ?[]u8 = null;

    if (mem.eql(u8, next_arg, "-f")) {
        const filename = args.next() orelse {
            writeStderr("Error: -f requires a filename\n", .{});
            std.process.exit(1);
        };
        owned_expr = std.fs.cwd().readFileAlloc(allocator, filename, 1 << 20) catch |err| {
            writeStderr("Error: could not read file: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        expression = owned_expr.?;
    } else if (mem.eql(u8, next_arg, "-f-")) {
        // Read from stdin
        owned_expr = std.fs.File.stdin().readToEndAlloc(allocator, 1 << 20) catch |err| {
            writeStderr("Error: could not read stdin: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        expression = owned_expr.?;
    } else {
        expression = next_arg;
    }
    defer if (owned_expr) |e| allocator.free(e);

    var client = hibrow.Client.connect(allocator) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.eval(profile, expression) catch |err| {
        writeStderr("Error: eval failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdUrl(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: url requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };
    _ = allocator;
    writeStdout("TODO: print URL for {s}\n", .{target});
}

fn cmdConsole(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const target = args.next() orelse {
        writeStderr("Error: console requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };
    _ = allocator;
    writeStdout("TODO: stream console for {s}\n", .{target});
}

fn cmdTab(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const action = args.next() orelse {
        writeStderr("Error: tab requires an action (list|new|close|switch)\n", .{});
        std.process.exit(1);
    };
    _ = allocator;
    writeStdout("TODO: tab {s}\n", .{action});
}

fn cmdGateway(allocator: mem.Allocator, args: *std.process.ArgIterator) void {
    const action = args.next() orelse {
        writeStderr("Error: gateway requires an action (status|stop|serve)\n", .{});
        std.process.exit(1);
    };

    if (mem.eql(u8, action, "serve")) {
        // Run the gateway daemon (this is the entry point for auto-start)
        var server = hibrow.gateway.Server.init(allocator);
        defer server.deinit();
        server.serve() catch |err| {
            writeStderr("Error: gateway serve failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    if (mem.eql(u8, action, "status")) {
        var client = hibrow.gateway.Client.connectNoAutoStart(allocator) catch {
            writeStdout("{s}\n", .{"{\"status\": \"not running\"}"});
            return;
        };
        defer client.disconnect();

        var resp = client.call("gateway.status", null) catch |err| {
            writeStderr("Error: gateway.status failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();
        printJsonValue(allocator, resp.result);
    } else if (mem.eql(u8, action, "stop")) {
        var client = hibrow.gateway.Client.connectNoAutoStart(allocator) catch {
            writeStderr("Gateway is not running.\n", .{});
            return;
        };
        defer client.disconnect();

        var resp = client.call("gateway.shutdown", null) catch |err| {
            writeStderr("Error: gateway.shutdown failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();
        printJsonValue(allocator, resp.result);
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

/// Parse profile from "profile" or "profile:tab" format.
/// Returns just the profile part.
fn parseProfile(target: []const u8) []const u8 {
    if (mem.indexOfScalar(u8, target, ':')) |colon| {
        return target[0..colon];
    }
    return target;
}

/// Print a JSON-RPC error response to stderr.
fn printError(allocator: mem.Allocator, err_val: json.Value) void {
    if (err_val == .object) {
        const msg = err_val.object.get("message") orelse .null;
        if (msg == .string) {
            writeStderr("Error: {s}\n", .{msg.string});
            return;
        }
    }
    // Fall back to printing the raw error JSON
    const bytes = json.Stringify.valueAlloc(allocator, err_val, .{}) catch {
        writeStderr("Error: unknown error\n", .{});
        return;
    };
    defer allocator.free(bytes);
    writeStderr("Error: {s}\n", .{bytes});
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

test "parseProfile extracts profile from bare name" {
    try std.testing.expectEqualStrings("work", parseProfile("work"));
}

test "parseProfile extracts profile from profile:tab" {
    try std.testing.expectEqualStrings("work", parseProfile("work:1"));
    try std.testing.expectEqualStrings("personal", parseProfile("personal:3"));
}
