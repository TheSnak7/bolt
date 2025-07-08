# Bolt

Bolt is an http server on top of zig-aio.
It builds with Zig 0.14.0.

## Goals

I'm building Bolt to really grok zig-aio and web servers.
Hyper is a huge inspiration for implementation and API design.
Once we've got HTTP sorted, I'm planning to add gRPC support,
which is kinda crucial for my Pegasus project.

## Usage

Add Bolt as a dependency in your `build.zig.zon` through zig fetch:

```bash
zig fetch --save git+https://github.com/TheSnak7/bolt
```

Then in your `build.zig`, add it as a module:

```zig
const bolt_dep = b.dependency("bolt", .{
    .target = target,
    .optimize = optimize,
});
const bolt = bolt_dep.module("bolt");
// Add to your executable
exe.root_module.addImport("bolt", bolt);
```

## Examples

### Hello World Server

A basic HTTP server that responds with "Hello World!":

```zig
const std = @import("std");
const bolt = @import("bolt");
const Btx = bolt.BoltContext;

pub fn hello(btx: Btx, req: bolt.Request) !bolt.Response {
    _ = req;
    return try bolt.Response.full(btx.allocator, "Hello World!");
}

pub fn main() !void {
    try bolt.main(struct {
        pub fn run(btx: Btx) !void {
            const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);
            var server = try bolt.Server.bind(&address, .{});
            defer server.deinit();
            const hello_service = try bolt.service.createFnService(hello);
            try server.serve(btx, hello_service);
        }
    }.run);
}
```

To run the examples:

```bash
# Build all examples
zig build example

# Run a specific example
zig build example-run -- hello_world
```

Available examples:

- `hello_world` - A basic HTTP server that responds with "Hello World!"
- `echo` - GET `/` for instructions, POST `/echo` to echo a request body
- `graceful` - Counts requests in a stateful service; POST `/shutdown` to stop

```bash
zig build example-run -- echo
curl --data 'hello' http://127.0.0.1:3000/echo

zig build example-run -- graceful
curl -X POST http://127.0.0.1:3000/shutdown
```

`zig build` and `zig build example` link all three executables into `zig-out/bin`.

For more examples, check out the [examples/](examples/) directory.

## Server API

`Server.bind` opens the listener. `serve` accepts connections and borrows the
service until it returns. A server is used once; keep its storage and the service
alive for the whole call. `localAddress()` returns the bound address, including
the assigned port when binding to port `0`.

```zig
var server = try bolt.Server.bind(&address, .{
    .max_connections = 128,
    .shutdown_timeout = 5 * std.time.ns_per_s,
    .http1 = .{ .max_body_size = 2 * 1024 * 1024 },
});
defer server.deinit();
try server.serve(btx, service);
```

Call `server.stop()` from a handler or another task on the same scheduler thread.
It stops accepting connections, closes idle and unfinished requests, and lets
parsed requests finish with `Connection: close`. The shutdown timeout bounds that
wait; remaining connection tasks are canceled and collected before `serve`
returns. Canceling the serving task closes all its connections immediately.
Wait for `serve` to return before calling `deinit`.

The default connection limit is 256. At the limit, the server waits for a slot
before accepting again. `0` is rejected. Connection errors stay local to the
connection; listener and allocation errors return from `serve`.

For a stateful service, pass a mutable struct pointer to
`bolt.service.createService(allocator, &handler)`. The struct supplies
`pub fn call(self: *Handler, ctx: bolt.BoltContext, req: bolt.Request) !bolt.Response`.
Its optional `deinit()` runs only when the caller calls `service.deinit()`;
the server borrows the service. See `graceful.zig` for an example.

## HTTP/1 options

HTTP/1 connections allow up to 1000 requests by default. Set `h1_max_requests`
to `0` to remove that limit, or `h1_keep_alive` to `false` to close after each
response. A request or response asking for `Connection: close` always wins.

`Http1.init`, or the server's `http1` options, also accepts
`keep_alive_timeout` (5 seconds), `read_timeout`
(30 seconds for the whole request), `write_timeout` (30 seconds for the whole
response), and `shutdown_timeout` (1 second). Values are in nanoseconds; `null`
disables a read/write timeout. Idle connections close silently, while an
unfinished request gets a 408. Closing sends FIN and drains incoming bytes
until EOF or the shutdown timeout. Custom streams can implement the optional
timeout and shutdown hooks in `AnyStream.VTable`.
