const std = @import("std");
const coro = @import("coro");

const AnyService = @import("service.zig").AnyService;
const BoltContext = @import("BoltContext.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Self = @This();

services: []const AnyService,

const Options = struct {
    services: []const AnyService,
};

// Does not transfer ownership over services
pub fn init(options: Options) !Self {
    return .{
        .services = options.services,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
    std.log.debug("Deinit Http1", .{});
}

pub fn run(http: *Self, ctx: BoltContext, sock: std.posix.socket_t) !void {
    std.log.debug("Opened connection", .{});
    defer std.log.debug("Closed connection", .{});

    var buf: [1024]u8 = undefined;
    var len: usize = 0;

    try coro.io.single(.recv, .{ .socket = sock, .buffer = &buf, .out_read = &len });

    const request: Request = try .fromBuffer(ctx.allocator, buf[0..len]);
    std.debug.assert(http.services.len == 1);
    const service = http.services[0];

    const res: Response = try service.call(ctx, request);
    try coro.io.single(.send, .{ .socket = sock, .buffer = res.body });
    try coro.io.single(.close_socket, .{ .socket = sock });
    defer http.deinit();
}

pub fn spawn(self: *Self, ctx: BoltContext, sock: std.posix.socket_t) !void {
    std.log.debug("Started server", .{});
    _ = try ctx.scheduler.spawn(run, .{ self, ctx, sock }, .{});
}
