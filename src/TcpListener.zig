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
    try std.posix.setsockopt(listener, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 128);
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
