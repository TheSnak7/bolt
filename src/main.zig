const std = @import("std");
const coro = @import("coro");
const aio = @import("aio");

// TODO: Make a library for better logging/ tracing
pub const std_options: std.Options = .{
    .log_level = .err,
};

fn echo(socket: std.posix.socket_t) !void {
    std.log.debug("Opened connection", .{});
    defer std.log.debug("Closed connection", .{});
    var buf: [1024]u8 = undefined;

    while (true) {
        var len: usize = 0;
        try coro.io.single(.recv, .{ .socket = socket, .buffer = &buf, .out_read = &len });

        if (len == 0) {
            std.log.debug("Client disconnected", .{});
            break;
        }

        std.log.debug("Received: {s}", .{buf[0..len]});

        try coro.io.single(.send, .{ .socket = socket, .buffer = buf[0..len] });
    }

    try coro.io.single(.close_socket, .{ .socket = socket });
}

fn server(startup: *coro.ResetEvent, scheduler: *coro.Scheduler) !void {
    std.log.debug("Starting server\n", .{});

    var listener: std.posix.socket_t = undefined;
    try coro.io.single(.socket, .{
        .domain = std.posix.AF.INET,
        .flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        .protocol = std.posix.IPPROTO.TCP,
        .out_socket = &listener,
    });
    defer coro.io.single(.close_socket, .{ .socket = listener }) catch {};

    try std.posix.setsockopt(listener, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);
    try std.posix.bind(listener, &address.any, address.getOsSockLen());
    try std.posix.listen(listener, 128);

    startup.set();

    while (true) {
        var client_sock: std.posix.socket_t = undefined;
        try coro.io.single(.accept, .{ .socket = listener, .out_socket = &client_sock });

        _ = try scheduler.spawn(echo, .{client_sock}, .{});
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    var startup: coro.ResetEvent = .{};

    _ = try scheduler.spawn(server, .{ &startup, &scheduler }, .{});

    try scheduler.run(.wait);
}
