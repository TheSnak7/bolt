const std = @import("std");

const lib = @import("lib.zig");

pub const Request = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    headers: lib.HeaderMap,
    method: lib.Method,
    uri: std.Uri,
    connection: lib.Connection,

    pub fn path(self: *const Request) []const u8 {
        return switch (self.uri.path) {
            .percent_encoded => |p| p,
            .raw => |r| r,
        };
    }

    // No transfer of ownership, because of unclear lifetimes.
    pub fn fromBuffer(alloc: std.mem.Allocator, method: lib.Method, uri: std.Uri, connection: lib.Connection, headers: lib.HeaderMap, buf: []const u8) !Request {
        const buf_copy = try alloc.alloc(u8, buf.len);
        @memcpy(buf_copy, buf);

        return .{
            .allocator = alloc,
            .body = buf_copy,
            .headers = headers,
            .method = method,
            .uri = uri,
            .connection = connection,
        };
    }
};
