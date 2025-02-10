const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

pub const TcpListener = @import("TcpListener.zig");
pub const Http1 = @import("Http1.zig");
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const BoltContext = @import("BoltContext.zig");
pub const service = @import("service.zig");
const lib = @import("lib.zig");

// TODO: Make a library for better logging/ tracing
pub const std_options: std.Options = .{
    .log_level = .info,
};

fn echo(ctx: BoltContext, req: Request) !Response {
    return switch (lib.match(req.method, req.path())) {
        lib.match(.GET, "/") => try Response.full(
            ctx.allocator,
            "Try POSTing data to /echo\n",
        ),
        lib.match(.POST, "/echo") => try Response.full(
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

fn server(ctx: BoltContext) !void {
    std.log.debug("Starting server\n", .{});

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

    var listener = try TcpListener.bind(&address);
    defer listener.deinit();

    while (true) {
        const client_sock = try listener.accept();

        const echo_service = try service.createFnService(echo);

        var http = try Http1.init(.{ .services = &.{
            echo_service,
        } });
        try http.spawn(ctx, client_sock);
    }
}

pub fn main(run: anytype) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    const context = BoltContext.with(gpa.allocator(), &scheduler);

    _ = try scheduler.spawn(run, .{context}, .{});

    try scheduler.run(.wait);
}
