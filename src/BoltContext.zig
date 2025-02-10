const std = @import("std");
const coro = @import("coro");

const Self = @This();

allocator: std.mem.Allocator,
scheduler: *coro.Scheduler,

pub fn with(allocator: std.mem.Allocator, scheduler: *coro.Scheduler) Self {
    return .{
        .allocator = allocator,
        .scheduler = scheduler,
    };
}
