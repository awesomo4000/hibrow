#!/usr/bin/env python3
"""Minimal fake Chrome DevTools endpoint for reproducing the readFrame crash.

Run with Chrome-shaped argv so hibrow's process scan discovers it:

    python3 repro/mock_chrome.py --remote-debugging-port=9555 \
        --user-data-dir=/tmp/hibrow-repro/crashprof [--close-after=N] [--mode=eof|midframe]

Serves GET /json (one page target) and a WebSocket at /devtools/page/MOCK.
Answers Runtime.evaluate with a string result. After N answered commands
(across all WebSocket sessions) the server drops the TCP connection once;
later sessions are served normally so reconnect paths can be exercised:

  --mode=eof       close cleanly between messages (tab closed / browser quit
                   while the gateway holds a cached connection)
  --mode=midframe  send the header + first bytes of a large base64 text frame,
                   then close (response cut off mid-transfer)
"""
import base64, hashlib, json, socket, socketserver, struct, sys, threading

args = dict(a.lstrip("-").split("=", 1) for a in sys.argv[1:] if "=" in a)
PORT = int(args["remote-debugging-port"])
CLOSE_AFTER = int(args.get("close-after", "1"))
MODE = args.get("mode", "eof")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
answered = 0
dropped = False
lock = threading.Lock()


def log(*a):
    print("[mock]", *a, file=sys.stderr, flush=True)


def recv_exact(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            raise ConnectionError
        b += c
    return b


def read_frame(sock):
    h = recv_exact(sock, 2)
    op, ln, masked = h[0] & 0x0F, h[1] & 0x7F, h[1] & 0x80
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(sock, 8))[0]
    mask = recv_exact(sock, 4) if masked else b"\0\0\0\0"
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(sock, ln)))
    return op, data


def frame_header(op, ln):
    if ln < 126:
        return bytes([0x80 | op, ln])
    if ln < 65536:
        return bytes([0x80 | op, 126]) + struct.pack(">H", ln)
    return bytes([0x80 | op, 127]) + struct.pack(">Q", ln)


def send_text(sock, text):
    data = text.encode()
    sock.sendall(frame_header(1, len(data)) + data)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        global answered, dropped
        sock = self.request
        req = b""
        while b"\r\n\r\n" not in req:
            c = sock.recv(4096)
            if not c:
                return
            req += c
        head = req.split(b"\r\n\r\n", 1)[0].decode()
        line = head.split("\r\n")[0]
        hdrs = {k.lower(): v.strip() for k, v in (l.split(":", 1) for l in head.split("\r\n")[1:] if ":" in l)}
        path = line.split()[1]

        if hdrs.get("upgrade", "").lower() == "websocket":
            acc = base64.b64encode(hashlib.sha1((hdrs["sec-websocket-key"] + GUID).encode()).digest()).decode()
            sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
            log("ws session opened", path)
            while True:
                try:
                    op, data = read_frame(sock)
                except ConnectionError:
                    log("client went away")
                    return
                if op == 8:
                    return
                if op != 1:
                    continue
                msg = json.loads(data)
                log("<-", msg.get("method"), "id", msg.get("id"))
                with lock:
                    if answered >= CLOSE_AFTER and not dropped:
                        dropped = True
                        if MODE == "midframe":
                            # Claim 1 MiB of base64, deliver 3 bytes, hang up.
                            sock.sendall(frame_header(1, 1 << 20) + b'{"i')
                            log("sent partial 1MiB frame, closing")
                        else:
                            log("closing TCP connection (simulated tab close)")
                        sock.shutdown(socket.SHUT_RDWR)
                        sock.close()
                        return
                    answered += 1
                send_text(sock, json.dumps({"id": msg["id"], "result": {"result": {"type": "string", "value": "ok"}}}))
            return

        ws = "ws://127.0.0.1:%d/devtools/page/MOCK" % PORT
        if path.startswith("/json/version"):
            body = {"Browser": "MockChrome/1.0", "webSocketDebuggerUrl": "ws://127.0.0.1:%d/devtools/browser/MOCK" % PORT}
        else:
            body = [{"id": "MOCK", "title": "mock", "url": "about:blank", "type": "page", "webSocketDebuggerUrl": ws}]
        out = json.dumps(body).encode()
        sock.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                     b"Connection: close\r\n\r\n" % len(out) + out)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


log("listening on", PORT, "mode", MODE, "close-after", CLOSE_AFTER)
Server(("127.0.0.1", PORT), Handler).serve_forever()
