///! Windows-specific browser discovery and executable lookup.
///!
///! This file is the single home for the heavy Win32 code, so the rest of the
///! codebase stays platform-neutral. Every public function is reached only from
///! a `builtin.os.tag == .windows` branch elsewhere (which is pruned at compile
///! time on other platforms), and additionally guards its body with a
///! non-Windows fallback, so the module compiles cleanly on macOS and Linux too.
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const process = @import("process.zig");

const is_windows = builtin.os.tag == .windows;

/// Find the Chrome/Chromium executable via the App Paths registry key.
/// Returns an allocated absolute path, or null if not installed.
pub fn findChrome(allocator: mem.Allocator) !?[]u8 {
    if (!is_windows) return null;
    return appPathsLookup(allocator, "chrome.exe");
}

/// Find the Firefox executable via the App Paths registry key.
pub fn findFirefox(allocator: mem.Allocator) !?[]u8 {
    if (!is_windows) return null;
    return appPathsLookup(allocator, "firefox.exe");
}

/// Discover running browsers by reading each process's command line and
/// matching --remote-debugging-port / --marionette, mirroring the POSIX scan.
/// Caller owns the slice; free with process.freeDiscovered().
pub fn findBrowsers(allocator: mem.Allocator, io: std.Io) ![]process.DiscoveredProcess {
    _ = io;
    if (!is_windows) return &[_]process.DiscoveredProcess{};
    // TODO(windows-discovery): enumerate processes and parse their command
    // lines. Stubbed to empty for now so the refactor compiles end to end.
    _ = allocator;
    return &[_]process.DiscoveredProcess{};
}

/// Look up an executable path under
/// HKLM/HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<exe>.
/// Stubbed until the Windows build compiles; real implementation follows.
fn appPathsLookup(allocator: mem.Allocator, exe: []const u8) !?[]u8 {
    _ = allocator;
    _ = exe;
    return null;
}
