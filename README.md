# Bolt

Bolt is an http server on top of zig-aio.

## Goals

I'm building Bolt to really grok zig-aio and web servers.
Hyper is a huge inspiration for implementation and API design.
Once we've got HTTP sorted, I'm planning to add gRPC support,
which is kinda crucial for my Pegasus project.

## Usage

Add Bolt as a dependency in your `build.zig.zon` through zig fetch:

```bash
zig fetch --save git+https://github.com/TheSnak7/bolt#bdadc5c
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
            std.log.debug("Starting server on http://127.0.0.1:3000\n", .{});
            const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

            var listener = try bolt.TcpListener.bind(&address);
            defer listener.deinit();

            const hello_service = try bolt.service.createFnService(hello);
            const http = try bolt.Http1.init(.{});

            while (true) {
                const stream = try listener.accept();
                errdefer stream.deinit();
                _ = try btx.scheduler.spawn(bolt.Http1.call, .{ http, btx, stream, hello_service }, .{ .detached = true });
            }
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

For more examples, check out the [examples/](examples/) directory.

HTTP/1 connections allow up to 1000 requests by default. Set `h1_max_requests`
to `0` to remove that limit, or `h1_keep_alive` to `false` to close after each
response. A request or response asking for `Connection: close` always wins.

`Http1.init` also accepts `keep_alive_timeout` (5 seconds), `read_timeout`
(30 seconds for the whole request), `write_timeout` (30 seconds for the whole
response), and `shutdown_timeout` (1 second). Values are in nanoseconds; `null`
disables a read/write timeout. Idle connections close silently, while an
unfinished request gets a 408. Closing sends FIN and drains incoming bytes
until EOF or the shutdown timeout. Custom streams can implement the optional
timeout and shutdown hooks in `AnyStream.VTable`.
