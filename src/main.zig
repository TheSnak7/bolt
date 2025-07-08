const std = @import("std");
const coro = @import("coro");

pub const Server = @import("Server.zig");
pub const TcpListener = @import("TcpListener.zig");
pub const Http1 = @import("Http1.zig");
pub const Request = @import("protocol.zig").Request;
pub const Response = @import("protocol.zig").Response;
pub const BoltContext = @import("BoltContext.zig");
pub const service = @import("service.zig");
pub const Service = service.Service;
pub const DispatchServer = @import("dispatch.zig").DispatchServer;
pub const Connection = @import("Connection.zig");
pub const stream = @import("stream.zig");
const lib = @import("lib.zig");
pub const bmatch = lib.bmatch;

pub fn main(run: anytype) !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var scheduler = try coro.Scheduler.init(gpa.allocator(), .{});
    defer scheduler.deinit();

    const context = BoltContext.with(gpa.allocator(), &scheduler);

    const task = try scheduler.spawn(run, .{context}, .{});

    try scheduler.run(.wait);
    try task.complete(.wait);
}
