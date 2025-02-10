const std = @import("std");

pub const Request = struct {
    allocator: std.mem.Allocator,
    body: []const u8,

    // No transfer of ownership, because of unclear lifetimes.
    pub fn fromBuffer(alloc: std.mem.Allocator, buf: []const u8) !Request {
        const buf_copy = try alloc.alloc(u8, buf.len);
        @memcpy(buf_copy, buf);

        return .{
            .allocator = alloc,
            .body = buf_copy,
        };
    }
};
