# Bolt

Bolt is an http server on top of zig-aio.

## Usage

Add Bolt as a dependency in your `build.zig.zon` through zig fetch.
Then in your `build.zig`, add it as a module:

```zig
const bolt_dep = b.dependency("bolt", .{});
const bolt = bolt_dep.module("bolt");
// Add to your executable
exe.addModule("bolt", bolt);
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

            while (true) {
                const client_sock = try listener.accept();
                const hello_service = try bolt.service.createFnService(hello);
                const http = try bolt.Http1.init(.{ .services = &.{hello_service} });
                _ = try btx.scheduler.spawn(bolt.Http1.call, .{ http.ctx, btx, client_sock }, .{});
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
