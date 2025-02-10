const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

const TcpListener = @import("TcpListener.zig");
const Http1 = @import("Http1.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const BoltContext = @import("BoltContext.zig");
const service = @import("service.zig");

// TODO: Make a library for better logging/ tracing
pub const std_options: std.Options = .{
    .log_level = .debug,
};

fn echo(ctx: BoltContext, req: Request) !Response {
    std.log.info("Request was: {s}", .{req.body});
    return try Response.fromBytes(ctx.allocator, req.body);
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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    const context = BoltContext.with(gpa.allocator(), &scheduler);

    _ = try scheduler.spawn(server, .{context}, .{});

    try scheduler.run(.wait);
}
