const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

const TcpListener = @import("TcpListener.zig");

// TODO: Make a library for better logging/ tracing
pub const std_options: std.Options = .{
    .log_level = .debug,
};

fn echo(socket: std.posix.socket_t) !void {
    std.log.debug("Opened connection", .{});
    defer std.log.debug("Closed connection", .{});
    // TODO: change buffer strategy
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

fn server(scheduler: *coro.Scheduler) !void {
    std.log.debug("Starting server\n", .{});

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

    var listener = try TcpListener.bind(&address);
    defer listener.deinit();

    while (true) {
        const client_sock = try listener.accept();
        _ = try scheduler.spawn(echo, .{client_sock}, .{});
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    _ = try scheduler.spawn(server, .{&scheduler}, .{});

    try scheduler.run(.wait);
}
