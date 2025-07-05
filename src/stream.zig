const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

pub const AnyStream = struct {
    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, buffer: []u8) anyerror!usize,
        write: *const fn (ptr: *anyopaque, buffer: []const u8) anyerror!usize,
        deinit: *const fn (ptr: *anyopaque) void,
        read_timeout: ?*const fn (ptr: *anyopaque, buffer: []u8, timeout: ?u64) anyerror!usize = null,
        write_timeout: ?*const fn (ptr: *anyopaque, buffer: []const u8, timeout: ?u64) anyerror!usize = null,
        shutdown: ?*const fn (ptr: *anyopaque, timeout: u64) anyerror!void = null,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn read(self: AnyStream, buffer: []u8) anyerror!usize {
        return self.vtable.read(self.ptr, buffer);
    }

    pub fn write(self: AnyStream, buffer: []const u8) anyerror!usize {
        return self.vtable.write(self.ptr, buffer);
    }

    // Custom streams can provide their own deadline handling.
    pub fn readWithTimeout(self: AnyStream, buffer: []u8, timeout: ?u64) anyerror!usize {
        if (self.vtable.read_timeout) |read_timeout| return read_timeout(self.ptr, buffer, timeout);
        return self.read(buffer);
    }

    pub fn writeWithTimeout(self: AnyStream, buffer: []const u8, timeout: ?u64) anyerror!usize {
        if (self.vtable.write_timeout) |write_timeout| return write_timeout(self.ptr, buffer, timeout);
        return self.write(buffer);
    }

    pub fn writeAll(self: AnyStream, buffer: []const u8) !void {
        return self.writeAllWithTimeout(buffer, null);
    }

    pub fn writeAllWithTimeout(self: AnyStream, buffer: []const u8, timeout: ?u64) !void {
        var timer = try std.time.Timer.start();
        var offset: usize = 0;
        while (offset < buffer.len) {
            const n = try self.writeWithTimeout(buffer[offset..], try remaining(&timer, timeout));
            if (n == 0) return error.WriteZero;
            offset += n;
        }
    }

    pub fn shutdown(self: AnyStream, timeout: u64) !void {
        if (self.vtable.shutdown) |shutdown_fn| try shutdown_fn(self.ptr, timeout);
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
                .read_timeout = read_timeout_erased,
                .write_timeout = write_timeout_erased,
                .shutdown = shutdown_erased,
            },
        };
    }

    pub fn deinit(self: TcpStream) void {
        // Closing directly also works when the task has been canceled.
        const stream: std.net.Stream = .{ .handle = self.sock };
        stream.close();
    }

    pub fn read(self: TcpStream, buffer: []u8) anyerror!usize {
        return self.readWithTimeout(buffer, null);
    }

    pub fn readWithTimeout(self: TcpStream, buffer: []u8, timeout: ?u64) anyerror!usize {
        var n: usize = 0;
        try timed(.recv, .{ .socket = self.sock, .buffer = buffer, .out_read = &n }, timeout);
        return n;
    }

    fn read_erased(ptr: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return try self.read(buffer);
    }

    pub fn write(self: TcpStream, buffer: []const u8) anyerror!usize {
        return self.writeWithTimeout(buffer, null);
    }

    pub fn writeWithTimeout(self: TcpStream, buffer: []const u8, timeout: ?u64) anyerror!usize {
        var n: usize = 0;
        try timed(.send, .{ .socket = self.sock, .buffer = buffer, .out_written = &n }, timeout);
        return n;
    }

    // Send FIN first, then drain input so unread bytes do not reset the response.
    pub fn shutdown(self: TcpStream, timeout: u64) !void {
        try coro.io.single(.shutdown, .{ .socket = self.sock, .how = .send });
        var timer = try std.time.Timer.start();
        var buffer: [4096]u8 = undefined;
        while (true) {
            const left = remaining(&timer, timeout) catch return;
            const n = self.readWithTimeout(&buffer, left) catch |err| switch (err) {
                error.Timeout => return,
                else => return err,
            };
            if (n == 0) return;
        }
    }

    fn read_timeout_erased(ptr: *anyopaque, buffer: []u8, timeout: ?u64) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return self.readWithTimeout(buffer, timeout);
    }

    fn write_timeout_erased(ptr: *anyopaque, buffer: []const u8, timeout: ?u64) anyerror!usize {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        return self.writeWithTimeout(buffer, timeout);
    }

    fn shutdown_erased(ptr: *anyopaque, timeout: u64) anyerror!void {
        const self: *TcpStream = @ptrCast(@alignCast(ptr));
        try self.shutdown(timeout);
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

pub fn remaining(timer: *std.time.Timer, timeout: ?u64) !?u64 {
    const limit = timeout orelse return null;
    const elapsed = timer.read();
    if (elapsed >= limit) return error.Timeout;
    return limit - elapsed;
}

fn timed(comptime op: aio.Operation, values: aio.Operation.map.getAssertContains(op), timeout: ?u64) !void {
    const limit = timeout orelse return coro.io.single(op, values);
    if (limit == 0) return error.Timeout;
    var operation = values;
    var operation_error: @TypeOf(values).Error = error.Success;
    var timeout_error: aio.LinkTimeout.Error = error.Success;
    operation.out_error = &operation_error;
    _ = try coro.io.complete(.{
        aio.op(op, operation, .soft),
        aio.op(.link_timeout, .{ .ns = limit, .out_error = &timeout_error }, .unlinked),
    });
    // A successful operation wins if completion raced with the timer.
    if (operation_error == error.Success) return;
    if (timeout_error == error.Expired) return error.Timeout;
    return operation_error;
}
