const std = @import("std");
const bolt = @import("bolt");
const Btx = bolt.BoltContext;
const TcpListener = bolt.TcpListener;
const Http1 = bolt.Http1;
const Request = bolt.Request;
const Response = bolt.Response;

pub fn hello(btx: Btx, req: Request) !Response {
    _ = req;
    return try Response.full(btx.allocator, "Hello World!");
}

pub fn helloMain(btx: Btx) !void {
    std.log.info("Starting server\n", .{});
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

    var listener = try TcpListener.bind(&address);
    defer listener.deinit();

    const hello_service = try bolt.service.createFnService(hello);
    const http = try Http1.init(.{});

    while (true) {
        const stream = try listener.accept();
        errdefer stream.deinit();

        _ = try btx.scheduler.spawn(Http1.call, .{ http, btx, stream, hello_service }, .{ .detached = true });
    }
}

pub fn main() !void {
    try bolt.main(helloMain);
}
