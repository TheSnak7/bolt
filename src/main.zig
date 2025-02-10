const std = @import("std");
const aio = @import("aio");
const coro = @import("coro");

pub const TcpListener = @import("TcpListener.zig");
pub const Http1 = @import("Http1.zig");
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const BoltContext = @import("BoltContext.zig");
pub const service = @import("service.zig");
const lib = @import("lib.zig");
pub const bmatch = lib.bmatch;

pub fn main(run: anytype) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    const context = BoltContext.with(gpa.allocator(), &scheduler);

    _ = try scheduler.spawn(run, .{context}, .{});

    try scheduler.run(.wait);
}
