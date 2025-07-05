const std = @import("std");
const lib = @import("lib.zig");
const proto = @import("protocol.zig");
const AnyStream = @import("stream.zig").AnyStream;
const remainingTime = @import("stream.zig").remaining;

const Connection = @This();

const State = struct {
    keep_alive: bool = true,
    reading: Reading = .Init,
    writing: Writing = .Init,
    version: lib.Version = .http11,
    method: lib.Method = .GET,
    connection: lib.Connection = .KeepAlive,

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
max_requests: usize = 1000,
max_body_size: usize = 1024 * 1024,
date_header: bool = true,
keep_alive_timeout: ?u64 = 5 * std.time.ns_per_s,
read_timeout: ?u64 = 30 * std.time.ns_per_s,
write_timeout: ?u64 = 30 * std.time.ns_per_s,
shutdown_timeout: u64 = std.time.ns_per_s,
read_timer: std.time.Timer = undefined,
write_timer: std.time.Timer = undefined,
requests: usize = 0,
state: State = .{},
closed: bool = false,
shutting_down: bool = false,

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

pub fn shutdown(self: *Connection) !void {
    if (self.closed or self.shutting_down) return;
    self.shutting_down = true;
    self.state.reading = .Closed;
    self.state.writing = .Closed;
    try self.stream.shutdown(self.shutdown_timeout);
}

pub fn read(self: *Connection, alloc: std.mem.Allocator) !?proto.Request {
    if (self.closed or self.state.reading == .Closed or self.state.writing == .Closed) return null;
    self.state.reading = .Init;
    self.state.version = .http11;
    self.state.method = .GET;
    self.state.connection = .KeepAlive;
    errdefer self.state.reading = .Closed;
    self.read_timer = try std.time.Timer.start();

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
        const idle = self.requests > 0 and buf.len == 0;
        const n = self.readHead(self.read_buf.unusedCapacitySlice()[0..read_size], idle) catch |err| {
            if (err == error.Timeout) {
                if (buf.len != 0) return error.RequestTimeout;
                self.state.reading = .Closed;
                return null;
            }
            return err;
        };
        if (n == 0) {
            if (buf.len != 0) return error.IncompleteRequest;
            self.state.reading = .Closed;
            return null;
        }
        if (idle) self.read_timer.reset();
        self.read_buf.items.len += n;
    };

    var request = try proto.Request.parseHead(alloc, self.read_buf.items[0..head_end], self.max_headers);
    self.state.version = request.version;
    self.state.method = request.method;
    self.state.connection = request.connection;
    self.read_pos = head_end;

    const length = request.content_length orelse 0;
    if (length > self.max_body_size) return error.BodyTooLarge;
    if (request.expect_continue and (length > 0 or request.chunked)) {
        try self.stream.writeAllWithTimeout("HTTP/1.1 100 Continue\r\n\r\n", self.write_timeout);
    }
    if (request.chunked) {
        request.body = try self.readChunked(alloc, &request);
    } else if (length > 0) {
        const body = try alloc.alloc(u8, @intCast(length));
        try self.readBytes(body);
        request.body = body;
    }

    self.state.reading = .KeepAlive;
    self.requests +|= 1;
    if (self.max_requests != 0 and self.requests >= self.max_requests) self.state.keep_alive = false;
    return request;
}

fn readHead(self: *Connection, buffer: []u8, idle: bool) !usize {
    const idle_timout = if (idle) self.keep_alive_timeout else try remainingTime(&self.read_timer, self.read_timeout);
    return self.stream.readWithTimeout(buffer, idle_timout);
}

fn fill(self: *Connection) !bool {
    const remaining = self.read_buf.items[self.read_pos..];
    std.mem.copyForwards(u8, self.read_buf.items[0..remaining.len], remaining);
    self.read_buf.items.len = remaining.len;
    self.read_pos = 0;
    try self.read_buf.ensureUnusedCapacity(self.allocator, 4096);
    const n = self.readBody(self.read_buf.unusedCapacitySlice()[0..4096]) catch |err| switch (err) {
        error.Timeout => return error.RequestTimeout,
        else => return err,
    };
    self.read_buf.items.len += n;
    return n != 0;
}

fn readBody(self: *Connection, buffer: []u8) !usize {
    return self.stream.readWithTimeout(buffer, try remainingTime(&self.read_timer, self.read_timeout));
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

    const status = @intFromEnum(response.status);
    if (response.status == .SwitchingProtocols) return error.UnsupportedUpgrade;
    if (self.state.method == .CONNECT and status >= 200 and status < 300) return error.UnsupportedTunnel;
    const informational = status < 200;
    const no_framing = informational or response.status == .NoContent;
    const empty_content = response.status == .ResetContent;
    const no_body = no_framing or empty_content or response.status == .NotModified or self.state.method == .HEAD;
    var content_length: ?u64 = null;
    var requested_chunked = response.chunked;
    var close = !self.state.keep_alive or self.state.connection == .Close or self.state.reading == .Closed;

    var header_it = response.headers.iterator();
    while (header_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        try proto.Response.validateHeader(name, value);
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (value.len == 0) return error.InvalidContentLength;
            for (value) |c| {
                if (!std.ascii.isDigit(c)) return error.InvalidContentLength;
            }
            content_length = std.fmt.parseInt(u64, value, 10) catch return error.InvalidContentLength;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), "chunked")) return error.UnsupportedTransferEncoding;
            requested_chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            var tokens = std.mem.splitScalar(u8, value, ',');
            while (tokens.next()) |part| {
                const token = std.mem.trim(u8, part, " \t");
                if (token.len != 0 and !proto.request.isToken(token)) return error.InvalidResponseHeader;
            }
            close = close or lib.Connection.parse(value) == .Close;
        }
    }
    if (content_length != null and response.headers.contains("Transfer-Encoding")) return error.InvalidContentLength;
    if (content_length) |length| {
        if (!no_body and !response.chunked and length != response.body.len) return error.InvalidContentLength;
    }
    const chunked = requested_chunked and self.state.version == .http11 and !no_framing and !empty_content;

    var response_buf = std.ArrayList(u8).init(alloc);
    defer response_buf.deinit();

    try response_buf.writer().print("{s} {d} {s}\r\n", .{
        self.state.version.string(),
        @intFromEnum(response.status),
        response.status.string(),
    });

    header_it = response.headers.iterator();
    while (header_it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Content-Length") or
            std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Connection")) continue;
        try response_buf.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    if (self.date_header and !response.headers.contains("Date")) {
        var date_buf: [29]u8 = undefined;
        try response_buf.writer().print("Date: {s}\r\n", .{try proto.Response.formatDate(&date_buf, std.time.timestamp())});
    }
    if (chunked) {
        try response_buf.appendSlice("Transfer-Encoding: chunked\r\n");
    } else if (!no_framing) {
        const length: ?u64 = if (empty_content) 0 else if (self.state.method == .HEAD or response.status == .NotModified)
            content_length orelse (if (response.status == .NotModified) @as(?u64, null) else response.body.len)
        else
            response.body.len;
        if (length) |n| try response_buf.writer().print("Content-Length: {d}\r\n", .{n});
    }
    try response_buf.writer().print("Connection: {s}", .{if (close) @as([]const u8, "close") else "keep-alive"});
    if (response.headers.get("Connection")) |value| {
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |part| {
            const token = std.mem.trim(u8, part, " \t");
            if (token.len != 0 and !std.ascii.eqlIgnoreCase(token, "close") and
                !std.ascii.eqlIgnoreCase(token, "keep-alive")) try response_buf.writer().print(", {s}", .{token});
        }
    }
    try response_buf.appendSlice("\r\n");

    try response_buf.appendSlice("\r\n");
    self.state.writing = .Init;
    errdefer self.state.writing = .Closed;
    self.write_timer = try std.time.Timer.start();
    try self.writeBytes(response_buf.items);

    if (!no_body) {
        if (chunked) {
            if (response.body.len != 0) {
                var size_buf: [32]u8 = undefined;
                try self.writeBytes(try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{response.body.len}));
                try self.writeBytes(response.body);
                try self.writeBytes("\r\n");
            }
            try self.writeBytes("0\r\n\r\n");
        } else {
            try self.writeBytes(response.body);
        }
    }

    self.state.writing = if (close and !informational) .Closed else .KeepAlive;
}

fn writeBytes(self: *Connection, buffer: []const u8) !void {
    try self.stream.writeAllWithTimeout(buffer, try remainingTime(&self.write_timer, self.write_timeout));
}
