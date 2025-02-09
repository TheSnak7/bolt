const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

const Self = @This();

listener: std.posix.socket_t,

pub fn bind(address: *const std.net.Address) !Self {
    var listener: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &listener,
    });
    errdefer coro.io.single(.close_socket, .{ .socket = listener }) catch {};

    std.posix.setsockopt(listener, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
        std.log.err("Could not set socket options: {s}", .{@errorName(err)});
    };

    std.posix.bind(listener, &address.any, address.getOsSockLen()) catch |err| {
        switch (err) {
            error.AddressInUse => {
                std.log.err("Failed to bind: Address already in use (port {})", .{address.getPort()});
                return error.AddressAlreadyInUse;
            },
            else => |e| {
                std.log.err("Failed to bind: {s}", .{@errorName(err)});
                return e;
            },
        }
    };

    std.posix.listen(listener, 128) catch |err| {
        std.log.err("Failed to listen: {s}", .{@errorName(err)});
    };
    std.log.info("Listening on {}", .{address});

    return .{
        .listener = listener,
    };
}

pub fn accept(self: *Self) !std.posix.socket_t {
    var client_sock: std.posix.socket_t = undefined;
    try coro.io.single(.accept, .{ .socket = self.listener, .out_socket = &client_sock });
    return client_sock;
}

pub fn deinit(self: *Self) void {
    coro.io.single(.close_socket, .{ .socket = self.listener }) catch {
        std.log.err("Failed to close socket", .{});
    };
}
