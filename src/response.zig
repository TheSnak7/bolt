const std = @import("std");
const lib = @import("lib.zig");

pub const Response = struct {
    allocator: std.mem.Allocator,
    // Owned by Response
    body: []const u8,
    headers: lib.HeaderMap,
    status: lib.StatusCode,

    pub fn fromBytes(alloc: std.mem.Allocator, bytes: []const u8) !Response {
        const buf = try alloc.alloc(u8, bytes.len);
        @memcpy(buf, bytes);
        return .{
            .body = buf,
            .allocator = alloc,
            .headers = .empty,
        };
    }

    pub fn full(alloc: std.mem.Allocator, bytes: []const u8) !Response {
        var headers: lib.HeaderMap = .empty;

        // Add standard HTTP/1.1 headers
        try headers.put(alloc, "Content-Type", "text/plain");
        try headers.put(alloc, "Content-Length", try std.fmt.allocPrint(alloc, "{d}", .{bytes.len}));
        try headers.put(alloc, "Connection", "keep-alive");
        try headers.put(alloc, "Server", "bolt/0.1");

        const buf = try alloc.alloc(u8, bytes.len);
        @memcpy(buf, bytes);

        return .{
            .body = buf,
            .allocator = alloc,
            .headers = headers,
            .status = .OK,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        self.allocator.free(self.body);
    }
};
