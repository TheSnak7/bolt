const std = @import("std");
const lib = @import("lib.zig");
const proto = @import("protocol.zig");
const AnyStream = @import("stream.zig").AnyStream;

const Connection = @This();

const State = struct {
    keep_alive: bool = true,
    reading: Reading = .Init,
    writing: Writing = .Init,

    const Reading = enum {
        Init,
        KeepAlive,
        Closed,
    };

    const Writing = enum {
        Init,
        KeepAlive,
        Closed,
    };
};

stream: AnyStream,
state: State = .{},
closed: bool = false,

// The stream storage must outlive the connection. deinit closes the stream.
pub fn init(stream: AnyStream) !Connection {
    return .{ .stream = stream };
}

pub fn deinit(self: *Connection) void {
    if (self.closed) return;
    self.closed = true;
    self.state.reading = .Closed;
    self.state.writing = .Closed;
    self.stream.deinit();
}

pub fn read(self: *Connection, alloc: std.mem.Allocator) !?proto.Request {
    if (self.closed or self.state.reading == .Closed) return null;
    self.state.reading = .Init;
    errdefer self.state.reading = .Closed;

    const buf = try alloc.alloc(u8, 4096);
    const len = try self.stream.read(buf);

    if (len == 0) {
        self.state.reading = .Closed;
        return null;
    }

    var first_line_it = std.mem.splitScalar(u8, buf[0..@min(len, 10)], ' ');
    const method_str = first_line_it.next() orelse return error.InvalidRequest;
    const method = try lib.Method.parse(method_str);
    const path = first_line_it.next() orelse return error.InvalidRequest;
    const uri = try std.Uri.parseAfterScheme("", path);

    var it = std.http.HeaderIterator.init(buf[0..len]);
    var header_map: lib.HeaderMap = .empty;

    while (it.next()) |h| {
        try header_map.put(alloc, h.name, h.value);
    }

    const connection_str = header_map.get("Connection") orelse "keep-alive";
    const connection = lib.Connection.parse(connection_str);

    const request = try proto.Request.fromBuffer(
        alloc,
        method,
        uri,
        connection,
        header_map,
        buf[it.index..len],
    );

    self.state.reading = .KeepAlive;
    return request;
}

pub fn write(self: *Connection, alloc: std.mem.Allocator, response: proto.Response) !void {
    if (self.closed or self.state.writing == .Closed) return error.ConnectionClosed;
    self.state.writing = .Init;
    errdefer self.state.writing = .Closed;

    var response_buf = std.ArrayList(u8).init(alloc);
    defer response_buf.deinit();

    try response_buf.writer().print("HTTP/1.1 {d} {s}\r\n", .{
        @intFromEnum(response.status),
        response.status.string(),
    });

    var header_it = response.headers.iterator();
    while (header_it.next()) |entry| {
        try response_buf.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    try response_buf.appendSlice("\r\n");
    try response_buf.appendSlice(response.body);
    try self.stream.writeAll(response_buf.items);

    self.state.writing = .KeepAlive;
}
