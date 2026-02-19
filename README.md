# Zig HTTP Server Template

A production-grade HTTP server template in Zig 0.15, designed for low-latency services that spawn child processes (command executors, build servers, task runners).

## Architecture

### Warm-One Pattern

Always one thread + one buffer block pre-created, ready for the next connection. When taken, replacements are spawned/allocated immediately. The hot path does **zero allocation** and **zero thread creation**.

```
Accept Loop (main thread)
    │
    ├─ connection arrives
    │   ├─ warm thread ready? → hand off (signal condvar) ← FAST PATH
    │   └─ not ready? → spawn direct handler             ← FALLBACK
    │
    └─ replenish: alloc new block + spawn new warm thread
        (races with next accept — off the hot path)
```

First connection per burst hits the warm thread (zero overhead). Subsequent concurrent connections fall back to direct spawn with fresh blocks. System re-warms automatically between bursts.

### Key Design Decisions

| Decision | Why |
|---|---|
| **Thread-per-connection** | Simple, correct at our scale (<64 concurrent). Kernel-blocked when idle (zero CPU). |
| **Non-inheritable sockets** | Prevents child process handle leaks on Windows. Standard practice (libuv, Go, Rust all do this). |
| **Contiguous buffer block** | Single alloc per connection (~344KB), sliced into 4 typed buffers. One alloc, one free, perfect cache locality. |
| **HTTP/1.1 keep-alive** | Client-controlled. Server loops on `receiveHead()` per connection. No forced `Connection: close`. |
| **Comptime route dispatch** | Route table is inlined at compile time. Zero runtime cost for dispatch. |
| **Condvar handoff** | `std.Thread.Condition` for warm thread wake. Kernel-level block, zero spin. |

### Buffer Layout (per connection)

```
┌──────────┬───────────┬──────────┬──────────────┐
│ header   │ write     │ body     │ response     │
│ 8KB      │ 16KB      │ 64KB*    │ 256KB        │
└──────────┴───────────┴──────────┴──────────────┘
  * body size configurable via maxBodySize
```

## Usage

### Build & Run

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/server [config.json]
```

### Configuration

Create `config.json` (all fields optional, defaults shown):

```json
{
  "host": "0.0.0.0",
  "port": 3001,
  "authToken": null,
  "maxBodySize": 65536,
  "socketTimeoutMs": 30000,
  "maxConnections": 64
}
```

### Adding Routes

Edit `Connection.routes` in `src/api.zig`:

```zig
const routes = [_]Route{
    .{ .method = .GET,  .path = "/health",  .handler = &handleHealth },
    .{ .method = .POST, .path = "/widgets", .handler = &handleCreateWidget },
};
```

Handler signature:

```zig
fn handleCreateWidget(self: *Connection, request: *Request) Status {
    const body = self.readBody(request) catch |err| { ... };
    // ... process, format response into self.response_buf
    sendJson(request, json, .ok);
    return .ok;
}
```

For path-parameter routes, add prefix matching in `Connection.route()`:

```zig
if (mem.startsWith(u8, target, "/widget/")) {
    if (method == .GET) return self.handleGetWidget(request, target[8..]);
    return sendMethodNotAllowed(request);
}
```

### Auth

Set `authToken` in config. Clients must send `Authorization: Bearer <token>`. Requests without valid auth get `401 Unauthorized`.

## Performance

Tested on Windows 11, Zig 0.15.2 ReleaseFast:

| Metric | Result |
|---|---|
| Health check (GET) | 0.01 - 0.03ms |
| Echo handler (POST + JSON parse) | 0.08 - 0.28ms |
| 20 concurrent burst | 100% success, 0.15 - 0.49ms each |
| 50 sequential requests | 1.2ms/req (including TCP handshake) |
| 3 waves × 10 concurrent | 30/30, no failures |

## Files

```
src/
  main.zig    — entry point, arg parsing, lifecycle
  api.zig     — server, warm-one pattern, routing, handlers
  config.zig  — JSON config loading with defaults
build.zig     — build system
```

## Adapting for Your Project

1. Copy this directory
2. Rename the executable in `build.zig`
3. Delete the example `/echo` handler
4. Add your routes and handlers in `api.zig`
5. Add your config fields in `config.zig`
6. Build with `zig build -Doptimize=ReleaseFast`

## Requirements

- Zig 0.15.x
- Windows or POSIX (Linux, macOS)

## License

MIT
