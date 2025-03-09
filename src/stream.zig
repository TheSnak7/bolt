const std = @import("std");
const coro = @import("coro");

pub const AnyStream = struct {
    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buffer: []u8) anyerror!usize,
        write: *const fn (ptr: *anyopaque, buffer: []const u8) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn read(self: AnyStream, buffer: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buffer);
    }

    pub fn write(self: AnyStream, buffer: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, buffer);
    }

    pub fn writeAll(self: AnyStream, buffer: []const u8) !void {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const n = try self.write(buffer[offset..]);
            if (n == 0) return error.WriteZero;
            offset += n;
        }
    }

    pub fn deinit(self: AnyStream) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const TcpStream = struct {
    sock: std.posix.socket_t,

    pub fn init(sock: std.posix.socket_t) TcpStream {
        return .{ .sock = sock };
    }

    // The TcpStream must stay alive while this interface is used.
    pub fn any(self: *TcpStream) AnyStream {
        return .{
            .ptr = @ptrCast(@alignCast(self)),
            .vtable = &.{
                .read = read_erased,
                .write = write_erased,
                .deinit = deinit_erased,
            },
        };
    }

    pub fn deinit(self: TcpStream) void {
        // Closing directly also works when the task has been canceled.
        const stream: std.net.Stream = .{ .handle = self.sock };
        stream.close();
    }

    pub fn read(self: TcpStream, buffer: []u8) anyerror!usize {
        var n: usize = 0;
        try coro.io.single(.recv, .{ .socket = self.sock, .buffer = buffer, .out_read = &n });
        return n;
    }

    fn read_erased(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return try self.read(buffer);
    }

    pub fn write(self: TcpStream, buffer: []const u8) anyerror!usize {
        var n: usize = 0;
        try coro.io.single(.send, .{ .socket = self.sock, .buffer = buffer, .out_written = &n });
        return n;
    }

    fn write_erased(ptr: *anyopaque, buffer: []const u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return try self.write(buffer);
    }

    fn deinit_erased(ptr: *anyopaque) void {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
