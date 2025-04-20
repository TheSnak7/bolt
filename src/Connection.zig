const std = @import("std");
const lib = @import("lib.zig");
const proto = @import("protocol.zig");
const AnyStream = @import("stream.zig").AnyStream;

const Connection = @This();

const State = struct {
    keep_alive: bool = true,
    reading: Reading = .Init,
    writing: Writing = .Init,
    version: lib.Version = .http11,

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
allocator: std.mem.Allocator,
read_buf: std.ArrayListUnmanaged(u8) = .empty,
read_pos: usize = 0,
max_header_size: usize = 16 * 1024,
max_request_line_size: usize = 8192,
max_headers: usize = 100,
max_body_size: usize = 1024 * 1024,
state: State = .{},
closed: bool = false,

// The stream storage must outlive the connection. deinit closes the stream.
pub fn init(allocator: std.mem.Allocator, stream: AnyStream) !Connection {
    return .{ .allocator = allocator, .stream = stream };
}

pub fn deinit(self: *Connection) void {
    if (self.closed) return;
    self.closed = true;
    self.state.reading = .Closed;
    self.state.writing = .Closed;
    self.read_buf.deinit(self.allocator);
    self.stream.deinit();
}

pub fn read(self: *Connection, alloc: std.mem.Allocator) !?proto.Request {
    if (self.closed or self.state.reading == .Closed) return null;
    self.state.reading = .Init;
    errdefer self.state.reading = .Closed;

    if (self.read_pos > 0) {
        const remaining = self.read_buf.items[self.read_pos..];
        std.mem.copyForwards(u8, self.read_buf.items[0..remaining.len], remaining);
        self.read_buf.items.len = remaining.len;
        self.read_pos = 0;
    }

    var scan: usize = 0;
    const head_end = while (true) {
        const buf = self.read_buf.items;
        const end = if (std.mem.indexOfPos(u8, buf, scan, "\r\n\r\n")) |i| i + 4 else null;
        const head = buf[0 .. end orelse buf.len];
        var i = scan;
        while (i < head.len) : (i += 1) {
            if (head[i] == '\n' and (i == 0 or head[i - 1] != '\r')) return error.InvalidRequest;
            if (head[i] == '\r' and i + 1 < head.len and head[i + 1] != '\n') return error.InvalidRequest;
        }
        const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse
            (head.len - @intFromBool(std.mem.endsWith(u8, head, "\r")));
        if (first_line_end > self.max_request_line_size) return error.RequestLineTooLong;
        if (end) |n| {
            if (n > self.max_header_size) return error.HeadersTooLarge;
            break n;
        }
        if (buf.len >= self.max_header_size) return error.HeadersTooLarge;

        scan = buf.len -| 3;
        const read_size = @min(4096, self.max_header_size - buf.len);
        try self.read_buf.ensureUnusedCapacity(self.allocator, read_size);
        const n = try self.stream.read(self.read_buf.unusedCapacitySlice()[0..read_size]);
        if (n == 0) {
            if (buf.len != 0) return error.IncompleteRequest;
            self.state.reading = .Closed;
            return null;
        }
        self.read_buf.items.len += n;
    };

    var request = try proto.Request.parseHead(alloc, self.read_buf.items[0..head_end], self.max_headers);
    self.state.version = request.version;
    self.read_pos = head_end;

    const length = request.content_length orelse 0;
    if (length > self.max_body_size) return error.BodyTooLarge;
    if (request.expect_continue and (length > 0 or request.chunked)) {
        try self.stream.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
    }
    if (request.chunked) {
        request.body = try self.readChunked(alloc, &request);
    } else if (length > 0) {
        const body = try alloc.alloc(u8, @intCast(length));
        try self.readBytes(body);
        request.body = body;
    }

    self.state.reading = .KeepAlive;
    return request;
}

fn fill(self: *Connection) !bool {
    const remaining = self.read_buf.items[self.read_pos..];
    std.mem.copyForwards(u8, self.read_buf.items[0..remaining.len], remaining);
    self.read_buf.items.len = remaining.len;
    self.read_pos = 0;
    try self.read_buf.ensureUnusedCapacity(self.allocator, 4096);
    const n = try self.stream.read(self.read_buf.unusedCapacitySlice()[0..4096]);
    self.read_buf.items.len += n;
    return n != 0;
}

fn readBytes(self: *Connection, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        if (self.read_pos == self.read_buf.items.len) {
            if (!try self.fill()) return error.IncompleteRequest;
        }
        const available = self.read_buf.items[self.read_pos..];
        const n = @min(available.len, buffer.len - offset);
        @memcpy(buffer[offset..][0..n], available[0..n]);
        self.read_pos += n;
        offset += n;
    }
}

fn readLine(self: *Connection, limit: usize) ![]const u8 {
    var scan: usize = 0;
    while (true) {
        const buf = self.read_buf.items[self.read_pos..];
        const end = std.mem.indexOfPos(u8, buf, scan, "\r\n");
        const line_end = if (end) |i| i + 2 else buf.len;
        var i = scan;
        while (i < line_end) : (i += 1) {
            if (buf[i] == '\n' and (i == 0 or buf[i - 1] != '\r')) return error.InvalidRequest;
            if (buf[i] == '\r' and i + 1 < line_end and buf[i + 1] != '\n') return error.InvalidRequest;
        }
        const len = end orelse (buf.len - @intFromBool(std.mem.endsWith(u8, buf, "\r")));
        if (len > limit) return error.BodyTooLarge;
        if (end) |n| {
            self.read_pos += n + 2;
            return buf[0..n];
        }
        scan = buf.len -| 1;
        if (!try self.fill()) return error.IncompleteRequest;
    }
}

fn readChunked(self: *Connection, alloc: std.mem.Allocator, request: *proto.Request) ![]const u8 {
    var body = std.ArrayList(u8).init(alloc);
    defer body.deinit();

    while (true) {
        const line = try self.readLine(self.max_header_size);
        const size = try proto.body.chunkSize(line);
        if (size > self.max_body_size - body.items.len) return error.BodyTooLarge;
        if (size == 0) break;
        const chunk = try body.addManyAsSlice(@intCast(size));
        try self.readBytes(chunk);
        var ending: [2]u8 = undefined;
        try self.readBytes(&ending);
        if (!std.mem.eql(u8, &ending, "\r\n")) return error.InvalidRequest;
    }

    var trailer_size: usize = 0;
    var trailer_count: usize = 0;
    while (true) {
        const line = self.readLine(self.max_header_size) catch |err| switch (err) {
            error.BodyTooLarge => return error.HeadersTooLarge,
            else => return err,
        };
        trailer_size = trailer_size +| line.len +| 2;
        if (trailer_size > self.max_header_size) return error.HeadersTooLarge;
        if (line.len == 0) break;
        trailer_count += 1;
        if (trailer_count > self.max_headers) return error.TooManyHeaders;
        try request.addTrailer(line);
    }
    return body.toOwnedSlice();
}

pub fn write(self: *Connection, alloc: std.mem.Allocator, response: proto.Response) !void {
    if (self.closed or self.state.writing == .Closed) return error.ConnectionClosed;
    self.state.writing = .Init;
    errdefer self.state.writing = .Closed;

    var response_buf = std.ArrayList(u8).init(alloc);
    defer response_buf.deinit();

    try response_buf.writer().print("{s} {d} {s}\r\n", .{
        self.state.version.string(),
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
