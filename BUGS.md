# hibrow bugs

## BUG-001: eval output truncated for large results (64KB WebSocket buffer)

**Date:** 04/13/2026
**Severity:** High — silently returns empty/corrupt data
**Affected command:** `hibrow eval <profile> <expression>`

### Symptom

When a JS expression returns a string longer than ~30-40KB, `hibrow eval` returns an empty string or garbage. No error is reported. This silently corrupts the output.

For example, extracting a base64-encoded image (~200KB) from a page variable returns nothing:

```bash
# This works (small string):
hibrow eval circuit "document.title"
# → "Generate Media | Circuit"

# This fails silently (large string):
hibrow eval circuit "window.__imageData"
# → (empty)
```

### Root cause

`websocket.zig:readFrame()` (line 350) reads CDP WebSocket responses into a **fixed 65,536-byte stack buffer**:

```zig
pub fn readFrame(self: *WebSocket) !ReadResult {
    const stream = self.stream orelse return error.NotConnected;

    var buf: [65536]u8 = undefined;   // ← hard limit
    var buf_len: usize = 0;

    while (true) {
        const n = try stream.read(buf[buf_len..]);
        // ...
    }
}
```

When Chrome sends a CDP `Runtime.evaluate` response, the actual value is wrapped in a JSON envelope:

```json
{"id":5,"result":{"result":{"type":"string","value":"...the actual data..."}}}
```

For a 40KB string value, the CDP response JSON is ~40KB + JSON escaping overhead + envelope, which exceeds the 64KB buffer. The `stream.read(buf[buf_len..])` call gets a zero-length slice and either errors or returns incomplete data.

Every other layer in the pipeline handles large data correctly:
- `gateway.zig readLine()` — uses dynamic `ArrayList`, 1MB limit
- `protocol.zig encoding` — uses `valueAlloc` (dynamic)
- `cdp.zig eval()` — uses allocator for cloning
- `main.zig printJsonValue()` — uses `valueAlloc` (dynamic)
- `main.zig writeStdout()` — 4KB buffered writer, auto-flushes (no limit)

The WebSocket read buffer is the only fixed-size bottleneck in the entire chain.

### Fix

Replace the fixed stack buffer in `readFrame()` with a dynamic `ArrayList(u8)` that grows as data arrives. This is the same pattern already used in `gateway.zig`'s `readLine()`:

```zig
pub fn readFrame(self: *WebSocket) !ReadResult {
    const stream = self.stream orelse return error.NotConnected;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(self.allocator);

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = try stream.read(&read_buf);
        if (n == 0) return error.ConnectionClosed;
        try buf.appendSlice(self.allocator, read_buf[0..n]);

        const result = decodeFrameAlloc(self.allocator, buf.items) catch |err| {
            if (err == error.Incomplete) continue;
            return err;
        };
        return .{ .frame = result.frame, .owned_payload = result.owned_payload };
    }
}
```

This removes the 64KB ceiling entirely. Memory usage is proportional to the actual response size, and the read loop uses a small 8KB stack buffer for individual `read()` calls — same as the gateway.

### Workaround

Callers can pre-chunk large data inside the browser before extracting it. For example, rothko splits base64 image data into 20KB chunks stored in a JS array and pulls each chunk individually:

```javascript
// In the browser:
var chunks = [];
for (var i = 0; i < bigString.length; i += 20000) {
    chunks.push(bigString.substring(i, i + 20000));
}
window.__chunks = chunks;

// From the CLI, pull one at a time:
// hibrow eval circuit "window.__chunks[0]"
// hibrow eval circuit "window.__chunks[1]"
// ...
```

This works but is slow (one subprocess + gateway round-trip per chunk) and fragile.
