const Response = @import("protocol.zig").Response;
const BoltContext = @import("BoltContext.zig");
const Request = @import("protocol.zig").Request;

const std = @import("std");

// Services are borrowed. The caller owns their state and calls deinit if needed.
pub const Service = struct {
    pub const VTable = struct {
        call: *const fn (ptr: *anyopaque, ctx: BoltContext, req: Request) anyerror!Response,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub inline fn call(self: Service, ctx: BoltContext, req: Request) anyerror!Response {
        return try self.vtable.call(self.ptr, ctx, req);
    }

    pub inline fn deinit(self: Service) void {
        return self.vtable.deinit(self.ptr);
    }
};

pub fn ServiceFn(func: anytype) type {
    const FuncService = struct {
        const Self = @This();

        pub fn call(ptr: *anyopaque, ctx: BoltContext, req: Request) anyerror!Response {
            _ = ptr;
            return try func(ctx, req);
        }

        // Empty because function services have no state
        pub fn deinit(_: *anyopaque) void {}

        pub const ServiceVTable: Service.VTable = .{
            .call = &call,
            .deinit = &deinit,
        };

        pub fn service(self: *Self) Service {
            return .{
                .ptr = @ptrCast(@alignCast(self)),
                .vtable = &ServiceVTable,
            };
        }
    };
    return FuncService;
}

pub fn createService(allocator: std.mem.Allocator, serv: anytype) !Service {
    _ = allocator;
    const info = @typeInfo(@TypeOf(serv));

    return switch (info) {
        .@"fn" => createFnService(serv),
        .pointer => |pointer| blk: {
            if (pointer.size != .one or pointer.is_const or @typeInfo(pointer.child) != .@"struct") {
                @compileError("Expected a function or a mutable pointer to a service struct");
            }
            const Adapter = struct {
                fn call(ptr: *anyopaque, ctx: BoltContext, req: Request) anyerror!Response {
                    const self: @TypeOf(serv) = @ptrCast(@alignCast(ptr));
                    return self.call(ctx, req);
                }

                fn deinit(ptr: *anyopaque) void {
                    const self: @TypeOf(serv) = @ptrCast(@alignCast(ptr));
                    if (@hasDecl(pointer.child, "deinit")) self.deinit();
                }
            };
            break :blk .{
                .ptr = serv,
                .vtable = &.{ .call = Adapter.call, .deinit = Adapter.deinit },
            };
        },
        else => @compileError("Expected a function or a mutable pointer to a service struct"),
    };
}

pub fn createFnService(func: anytype) !Service {
    const Container = ServiceFn(func);

    // Create static instance - one per unique function
    const static = struct {
        var instance: Container = .{};
    };

    return static.instance.service();
}
