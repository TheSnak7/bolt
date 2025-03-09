const std = @import("std");
const bolt = @import("bolt");
const Btx = bolt.BoltContext;
const Request = bolt.Request;
const Response = bolt.Response;
const bmatch = bolt.bmatch;

fn echo(ctx: Btx, req: Request) !Response {
    return switch (bmatch(req.method, req.path())) {
        bmatch(.GET, "/") => try Response.full(
            ctx.allocator,
            "Try POSTing data to /echo\n",
        ),
        bmatch(.POST, "/echo") => try Response.full(
            ctx.allocator,
            req.body,
        ),
        else => blk: {
            std.log.err("Illegal path: {any}", .{req.path()});
            var res = try Response.full(ctx.allocator, "404 Not Found\n");
            res.status = .NotFound;
            break :blk res;
        },
    };
}

fn echoMain(btx: Btx) !void {
    std.log.info("Starting server\n", .{});

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

    var listener = try bolt.TcpListener.bind(&address);
    defer listener.deinit();

    const echo_service = try bolt.service.createFnService(echo);
    const http = try bolt.Http1.init(.{});

    while (true) {
        const stream = try listener.accept();
        errdefer stream.deinit();

        _ = try btx.scheduler.spawn(bolt.Http1.call, .{ http, btx, stream, echo_service }, .{ .detached = true });
    }
}

pub fn main() !void {
    try bolt.main(echoMain);
}
