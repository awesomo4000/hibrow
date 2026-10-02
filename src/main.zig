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

/// Don't dump a stack trace for "unexpected" errnos. hibrow handles its own
/// errors (e.g. connecting to a stale/absent gateway socket returns
/// ECONNREFUSED, which Zig 0.16 does not map to a named error — without this it
/// would print an alarming trace on a normal `gateway status` / auto-start).
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };

const usage =
    \\Usage: hibrow <command> [options]
    \\
    \\Commands:
    \\  launch <profile> [--browser chrome|firefox|ff] [--headless] [--proxy <url>] [--proxy-dns]
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
    \\  kill <profile>
    \\      Gracefully close a browser (profile is preserved).
    \\
    \\  url <profile[:tab]>
    \\      Print the current URL of a browser tab.
    \\
    \\  console <profile[:tab]>
    \\      Stream console output from a browser tab.
    \\
    \\  frame list <profile>
    \\      List nested frames (path, url, name) for use with eval --frame.
    \\
    \\  eval <profile> --frame <path|selector> "<js>"
    \\      Evaluate JavaScript inside a nested frame. Path is comma/slash-
    \\      separated frame indices and/or CSS selectors, e.g. 1,0,0 or #inner.
    \\
    \\  click <profile[:tab]> <selector> [--frame <path>]
    \\      Natively click an element (scrolls into view; real trusted click on
    \\      Firefox). Works inside a frame with --frame.
    \\
    \\  wait <profile[:tab]> <selector> [--frame <path>] [--timeout <secs>] [--gone]
    \\      Poll until a selector appears (or disappears with --gone). Default
    \\      timeout 10s.
    \\
    \\  tab list|new|close|switch <profile[:tab]>
    \\      Manage tabs within a browser profile.
    \\
    \\  grab <profile> <url-or-js-expr> -o <file>
    \\      Grab binary data from browser and save to file.
    \\      URL mode: fetches the URL through the browser (with cookies/auth).
    \\      JS mode: evaluates expression that returns base64 or a URL to fetch.
    \\
    \\  push <profile[:tab]> <target> <text> | -f <file> | -f-
    \\      Push text into the browser. Target is a CSS selector (sets .value)
    \\      or a window.* variable name (assigns directly).
    \\
    \\  screenshot <profile[:tab]> -o <file>
    \\      Capture a screenshot of the browser tab and save as PNG.
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
    \\  --skill       Print the hibrow skill: a guide teaching agents to use
    \\                hibrow well (common ops, React gotchas, page instrumentation).
    \\                Tip: hibrow --skill > .claude/skills/hibrow/SKILL.md
    \\
;

const version = "0.1.0";

/// The hibrow skill — a self-contained guide that teaches any agent how to use
/// hibrow well. Printed by `hibrow --skill`. Pipe it into a skills directory
/// (e.g. `hibrow --skill > .claude/skills/hibrow/SKILL.md`) to install it.
const skill = @embedFile("skill.md");

/// Process-wide Io backend, set once in main(). Zig 0.16 routes all socket and
/// file operations through an `Io` instance; the output helpers below use this,
/// and it is passed explicitly into the hibrow library constructors.
var g_io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    g_io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    // Skip argv[0] (program name)
    _ = args.skip();

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

    if (mem.eql(u8, command, "--skill")) {
        printSkill();
        return;
    }

    // Dispatch to command handlers
    const Handler = *const fn (mem.Allocator, *std.process.Args.Iterator) void;
    const commands = std.StaticStringMap(Handler).initComptime(.{
        .{ "launch", cmdLaunch },
        .{ "ls", cmdList },
        .{ "nav", cmdNavigate },
        .{ "eval", cmdEval },
        .{ "frame", cmdFrame },
        .{ "click", cmdClick },
        .{ "wait", cmdWait },
        .{ "kill", cmdKill },
        .{ "url", cmdUrl },
        .{ "console", cmdConsole },
        .{ "tab", cmdTab },
        .{ "grab", cmdGrab },
        .{ "push", cmdPush },
        .{ "screenshot", cmdScreenshot },
        .{ "gateway", cmdGateway },
    });

    if (commands.get(command)) |handler| {
        handler(allocator, &args);
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
    // Use streaming mode: `writer()` defaults to positional writes (pwrite at
    // pos=0), which overwrite from the start of the file when stdout is
    // redirected to a regular file. Streaming uses write()/writev(), which
    // respects the kernel file offset and O_APPEND so output appends correctly.
    var stdout_writer = std.Io.File.stdout().writerStreaming(g_io, &buf);
    const stdout = &stdout_writer.interface;
    stdout.print(fmt, fmt_args) catch {};
    stdout.flush() catch {};
}

fn writeStderr(comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    // Streaming mode for the same reason as writeStdout: avoid positional
    // pwrite-at-pos=0 clobbering when stderr is redirected to a file.
    var stderr_writer = std.Io.File.stderr().writerStreaming(g_io, &buf);
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

fn cmdLaunch(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const profile = args.next() orelse {
        writeStderr("Error: launch requires a profile name\n", .{});
        std.process.exit(1);
    };

    // Parse optional flags
    var proxy: ?[]const u8 = null;
    var proxy_dns = false;
    var headless = false;
    var browser_type: hibrow.browser.BrowserType = .chrome;
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--proxy")) {
            proxy = args.next() orelse {
                writeStderr("Error: --proxy requires a URL argument\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, arg, "--proxy-dns")) {
            proxy_dns = true;
        } else if (mem.eql(u8, arg, "--headless")) {
            headless = true;
        } else if (mem.eql(u8, arg, "--browser")) {
            const bt_str = args.next() orelse {
                writeStderr("Error: --browser requires an argument (chrome, firefox, ff)\n", .{});
                std.process.exit(1);
            };
            browser_type = hibrow.browser.BrowserType.fromString(bt_str) orelse {
                writeStderr("Error: unknown browser type: {s}\n", .{bt_str});
                std.process.exit(1);
            };
        } else {
            writeStderr("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.launch(profile, .{
        .proxy = proxy,
        .proxy_dns = proxy_dns,
        .headless = headless,
        .browser_type = browser_type,
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

fn cmdList(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const profile = args.next();

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
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

fn cmdNavigate(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
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

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
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

fn cmdClick(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: click requires a profile[:tab] and selector\n", .{});
        std.process.exit(1);
    };
    const profile = parseProfile(target);

    var selector: ?[]const u8 = null;
    var frame: ?[]const u8 = null;
    while (args.next()) |a| {
        if (mem.eql(u8, a, "--frame")) {
            frame = args.next() orelse {
                writeStderr("Error: --frame requires a selector or path\n", .{});
                std.process.exit(1);
            };
        } else {
            selector = a;
        }
    }
    const sel = selector orelse {
        writeStderr("Error: click requires a CSS selector\n", .{});
        std.process.exit(1);
    };

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.click(profile, sel, frame) catch |err| {
        writeStderr("Error: click failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();
    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdWait(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: wait requires a profile[:tab] and --selector\n", .{});
        std.process.exit(1);
    };
    const profile = parseProfile(target);

    var selector: ?[]const u8 = null;
    var frame: ?[]const u8 = null;
    var timeout_ms: ?i64 = null;
    var gone = false;
    while (args.next()) |a| {
        if (mem.eql(u8, a, "--frame")) {
            frame = args.next() orelse {
                writeStderr("Error: --frame requires a selector or path\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, a, "--selector")) {
            selector = args.next() orelse {
                writeStderr("Error: --selector requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, a, "--timeout")) {
            const secs = args.next() orelse {
                writeStderr("Error: --timeout requires seconds\n", .{});
                std.process.exit(1);
            };
            const s = std.fmt.parseFloat(f64, secs) catch {
                writeStderr("Error: --timeout must be a number of seconds\n", .{});
                std.process.exit(1);
            };
            timeout_ms = @intFromFloat(s * 1000.0);
        } else if (mem.eql(u8, a, "--gone")) {
            gone = true;
        } else {
            selector = a;
        }
    }
    const sel = selector orelse {
        writeStderr("Error: wait requires a CSS selector (positional or --selector)\n", .{});
        std.process.exit(1);
    };

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.wait(profile, sel, frame, timeout_ms, gone) catch |err| {
        writeStderr("Error: wait failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();
    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdFrame(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const sub = args.next() orelse {
        writeStderr("Error: frame requires a subcommand (list)\n", .{});
        std.process.exit(1);
    };
    if (!mem.eql(u8, sub, "list")) {
        writeStderr("Error: unknown frame subcommand: {s} (expected 'list')\n", .{sub});
        std.process.exit(1);
    }
    const target = args.next() orelse {
        writeStderr("Error: frame list requires a profile\n", .{});
        std.process.exit(1);
    };
    const profile = parseProfile(target);

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.frames(profile) catch |err| {
        writeStderr("Error: frame list failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdEval(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: eval requires a profile[:tab] and expression\n", .{});
        std.process.exit(1);
    };

    const profile = parseProfile(target);

    // Parse remaining args: the expression (positional, -f <file>, or -f-),
    // plus an optional --frame <selector-or-path> that may appear anywhere.
    var expression: []const u8 = undefined;
    var owned_expr: ?[]u8 = null;
    var frame: ?[]const u8 = null;
    var expr_arg: ?[]const u8 = null;
    var from_file: ?[]const u8 = null;
    var from_stdin = false;

    while (args.next()) |a| {
        if (mem.eql(u8, a, "--frame")) {
            frame = args.next() orelse {
                writeStderr("Error: --frame requires a selector or path (e.g. 0/0 or #inner)\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, a, "-f")) {
            from_file = args.next() orelse {
                writeStderr("Error: -f requires a filename\n", .{});
                std.process.exit(1);
            };
        } else if (mem.eql(u8, a, "-f-")) {
            from_stdin = true;
        } else {
            expr_arg = a;
        }
    }

    if (from_file) |filename| {
        owned_expr = std.Io.Dir.cwd().readFileAlloc(g_io, filename, allocator, .limited(1 << 20)) catch |err| {
            writeStderr("Error: could not read file: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        expression = owned_expr.?;
    } else if (from_stdin) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(g_io, &stdin_buf);
        owned_expr = stdin_reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch |err| {
            writeStderr("Error: could not read stdin: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        expression = owned_expr.?;
    } else if (expr_arg) |e| {
        expression = e;
    } else {
        writeStderr("Error: eval requires a JavaScript expression\n", .{});
        std.process.exit(1);
    }
    defer if (owned_expr) |e| allocator.free(e);

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.eval(profile, expression, frame) catch |err| {
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

fn cmdKill(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const profile = args.next() orelse {
        writeStderr("Error: kill requires a profile name\n", .{});
        std.process.exit(1);
    };

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.kill(profile) catch |err| {
        writeStderr("Error: kill failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }
    printJsonValue(allocator, resp.result);
}

fn cmdUrl(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: url requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };

    const profile = parseProfile(target);

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.getUrl(profile) catch |err| {
        writeStderr("Error: url failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }

    // Print raw URL string for clean piping (strip JSON quotes)
    if (resp.result == .string) {
        writeStdout("{s}\n", .{resp.result.string});
    } else {
        printJsonValue(allocator, resp.result);
    }
}

fn cmdConsole(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: console requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };
    _ = allocator;
    writeStdout("TODO: stream console for {s}\n", .{target});
}

fn cmdTab(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const action = args.next() orelse {
        writeStderr("Error: tab requires an action (list|new|close|switch)\n", .{});
        std.process.exit(1);
    };

    if (mem.eql(u8, action, "list")) {
        const profile = args.next() orelse {
            writeStderr("Error: tab list requires a profile name\n", .{});
            std.process.exit(1);
        };

        var client = hibrow.Client.connect(allocator, g_io) catch |err| {
            writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer client.disconnect();

        var resp = client.tabList(profile) catch |err| {
            writeStderr("Error: tab list failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    } else if (mem.eql(u8, action, "new")) {
        const target = args.next() orelse {
            writeStderr("Error: tab new requires a profile name\n", .{});
            std.process.exit(1);
        };

        const profile = parseProfile(target);
        const url = args.next(); // optional URL

        var client = hibrow.Client.connect(allocator, g_io) catch |err| {
            writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer client.disconnect();

        var resp = client.tabNew(profile, url) catch |err| {
            writeStderr("Error: tab new failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    } else if (mem.eql(u8, action, "close")) {
        const target = args.next() orelse {
            writeStderr("Error: tab close requires profile:tab\n", .{});
            std.process.exit(1);
        };

        const tab_ref = hibrow.tab.parseTabRef(target) catch {
            writeStderr("Error: invalid tab reference: {s}\n", .{target});
            std.process.exit(1);
        };
        const tab_index = tab_ref.tab orelse {
            writeStderr("Error: tab close requires a tab index (profile:N)\n", .{});
            std.process.exit(1);
        };

        var client = hibrow.Client.connect(allocator, g_io) catch |err| {
            writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer client.disconnect();

        var resp = client.tabClose(tab_ref.profile, tab_index) catch |err| {
            writeStderr("Error: tab close failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    } else if (mem.eql(u8, action, "switch")) {
        const target = args.next() orelse {
            writeStderr("Error: tab switch requires profile:tab\n", .{});
            std.process.exit(1);
        };

        const tab_ref = hibrow.tab.parseTabRef(target) catch {
            writeStderr("Error: invalid tab reference: {s}\n", .{target});
            std.process.exit(1);
        };
        const tab_index = tab_ref.tab orelse {
            writeStderr("Error: tab switch requires a tab index (profile:N)\n", .{});
            std.process.exit(1);
        };

        var client = hibrow.Client.connect(allocator, g_io) catch |err| {
            writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer client.disconnect();

        var resp = client.tabSwitch(tab_ref.profile, tab_index) catch |err| {
            writeStderr("Error: tab switch failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer resp.deinit();

        if (resp.is_error) {
            printError(allocator, resp.result);
            std.process.exit(1);
        }
        printJsonValue(allocator, resp.result);
    } else {
        writeStderr("Unknown tab action: {s}\n", .{action});
        writeStderr("Usage: hibrow tab list|new|close|switch <profile[:tab]>\n", .{});
        std.process.exit(1);
    }
}

fn cmdGrab(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const profile_arg = args.next() orelse {
        writeStderr("Error: grab requires a profile and source (URL or JS expression)\n", .{});
        std.process.exit(1);
    };
    const profile = parseProfile(profile_arg);

    var source: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    // Parse remaining args: <source> -o <file>
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-o")) {
            output = args.next() orelse {
                writeStderr("Error: -o requires a filename\n", .{});
                std.process.exit(1);
            };
        } else if (source == null) {
            source = arg;
        } else {
            writeStderr("Error: unexpected argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const src = source orelse {
        writeStderr("Error: grab requires a source (URL or JS expression)\n", .{});
        std.process.exit(1);
    };
    const out_path = output orelse {
        writeStderr("Error: grab requires -o <output-file>\n", .{});
        std.process.exit(1);
    };

    const grab_mod = hibrow.grab;
    var result = grab_mod.grab(allocator, g_io, profile, src) catch |err| {
        writeStderr("Error: grab failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(allocator);

    // Write to file
    const file = std.Io.Dir.cwd().createFile(g_io, out_path, .{}) catch |err| {
        writeStderr("Error: could not create file: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer file.close(g_io);

    file.writeStreamingAll(g_io, result.data) catch |err| {
        writeStderr("Error: could not write file: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Print result
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Saved {s} ({d} bytes)\n", .{ out_path, result.data.len }) catch return;
    writeStderr("{s}", .{msg});
}

fn cmdPush(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target_arg = args.next() orelse {
        writeStderr("Error: push requires a profile[:tab] and target\n", .{});
        std.process.exit(1);
    };
    const profile = parseProfile(target_arg);

    const target = args.next() orelse {
        writeStderr("Error: push requires a target (CSS selector or window.* variable)\n", .{});
        std.process.exit(1);
    };

    // Get content: positional arg, -f <file>, or -f- (stdin)
    const next_arg = args.next() orelse {
        writeStderr("Error: push requires content (text, -f <file>, or -f-)\n", .{});
        std.process.exit(1);
    };

    var content: []const u8 = undefined;
    var owned_content: ?[]u8 = null;

    if (mem.eql(u8, next_arg, "-f")) {
        const filename = args.next() orelse {
            writeStderr("Error: -f requires a filename\n", .{});
            std.process.exit(1);
        };
        owned_content = std.Io.Dir.cwd().readFileAlloc(g_io, filename, allocator, .limited(10 << 20)) catch |err| {
            writeStderr("Error: could not read file: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        content = owned_content.?;
    } else if (mem.eql(u8, next_arg, "-f-")) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(g_io, &stdin_buf);
        owned_content = stdin_reader.interface.allocRemaining(allocator, .limited(10 << 20)) catch |err| {
            writeStderr("Error: could not read stdin: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        content = owned_content.?;
    } else {
        content = next_arg;
    }
    defer if (owned_content) |c| allocator.free(c);

    const push_mod = hibrow.push;
    push_mod.push(allocator, g_io, profile, target, content) catch |err| {
        writeStderr("Error: push failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    writeStderr("ok\n", .{});
}

fn cmdScreenshot(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const target = args.next() orelse {
        writeStderr("Error: screenshot requires a profile[:tab]\n", .{});
        std.process.exit(1);
    };

    var output: ?[]const u8 = null;

    // Parse remaining args: -o <file>
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-o")) {
            output = args.next() orelse {
                writeStderr("Error: -o requires a filename\n", .{});
                std.process.exit(1);
            };
        } else {
            writeStderr("Error: unexpected argument: {s}\n", .{arg});
            std.process.exit(1);
        }
    }

    const out_path = output orelse {
        writeStderr("Error: screenshot requires -o <output-file>\n", .{});
        std.process.exit(1);
    };

    const profile = parseProfile(target);
    const tab: ?i64 = blk: {
        if (mem.indexOfScalar(u8, target, ':')) |colon| {
            const tab_str = target[colon + 1 ..];
            break :blk std.fmt.parseInt(i64, tab_str, 10) catch null;
        }
        break :blk null;
    };

    var client = hibrow.Client.connect(allocator, g_io) catch |err| {
        writeStderr("Error: could not connect to gateway: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer client.disconnect();

    var resp = client.screenshot(profile, tab) catch |err| {
        writeStderr("Error: screenshot failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer resp.deinit();

    if (resp.is_error) {
        printError(allocator, resp.result);
        std.process.exit(1);
    }

    // Result is base64 PNG string
    if (resp.result != .string) {
        writeStderr("Error: unexpected response format\n", .{});
        std.process.exit(1);
    }

    // Decode base64
    const b64 = resp.result.string;
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64) catch {
        writeStderr("Error: invalid base64 data\n", .{});
        std.process.exit(1);
    };
    const decoded = allocator.alloc(u8, decoded_size) catch {
        writeStderr("Error: out of memory\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, b64) catch {
        writeStderr("Error: base64 decode failed\n", .{});
        std.process.exit(1);
    };

    // Write to file
    const file = std.Io.Dir.cwd().createFile(g_io, out_path, .{}) catch |err| {
        writeStderr("Error: could not create file: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer file.close(g_io);

    file.writeStreamingAll(g_io, decoded) catch |err| {
        writeStderr("Error: could not write file: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Saved {s} ({d} bytes)\n", .{ out_path, decoded.len }) catch return;
    writeStderr("{s}", .{msg});
}

fn cmdGateway(allocator: mem.Allocator, args: *std.process.Args.Iterator) void {
    const action = args.next() orelse {
        writeStderr("Error: gateway requires an action (status|stop|serve)\n", .{});
        std.process.exit(1);
    };

    if (mem.eql(u8, action, "serve")) {
        // Run the gateway daemon (this is the entry point for auto-start)
        var server = hibrow.gateway.Server.init(allocator, g_io);
        defer server.deinit();
        server.serve() catch |err| {
            writeStderr("Error: gateway serve failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    if (mem.eql(u8, action, "status")) {
        var client = hibrow.gateway.Client.connectNoAutoStart(allocator, g_io) catch {
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
        var client = hibrow.gateway.Client.connectNoAutoStart(allocator, g_io) catch {
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

fn printSkill() void {
    writeStdout("{s}", .{skill});
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
