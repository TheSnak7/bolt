const std = @import("std");

const HeaderMap = std.AutoHashMapUnmanaged([]const u8, []const u8);

pub const Response = struct {
    allocator: std.mem.Allocator,
    // Owned by Response
    body: []const u8,
    headers: HeaderMap,

    pub fn fromBytes(alloc: std.mem.Allocator, bytes: []const u8) !Response {
        const buf = try alloc.alloc(u8, bytes.len);
        @memcpy(buf, bytes);
        return .{
            .body = buf,
            .allocator = alloc,
            .headers = .empty,
        };
    }
};
