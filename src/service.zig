const Response = @import("response.zig").Response;
const BoltContext = @import("BoltContext.zig");
const Request = @import("request.zig").Request;

const std = @import("std");

pub const AnyService = struct {
    pub const VTable = struct {
        call: *const fn (ptr: *anyopaque, ctx: BoltContext, req: Request) anyerror!Response,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub inline fn call(self: AnyService, ctx: BoltContext, req: Request) anyerror!Response {
        return try self.vtable.call(self.ptr, ctx, req);
    }

    pub inline fn deinit(self: AnyService) void {
        return self.vtable.deinit(self.ptr);
    }
};

pub fn ServiceFn(func: anytype) type {
    const FuncService = struct {
        const Self = @This();

        pub fn call(ptr: *anyopaque, ctx: BoltContext, req: Request) anyerror!Response {
            //TODO: Arenas for memory management
            // An arena can be used per request and cleared when the response is written
            // ptr for future state
            _ = ptr;
            return try func(ctx, req);
        }

        // Empty because function services have no state
        pub fn deinit(_: *anyopaque) void {}

        pub const ServiceVTable: AnyService.VTable = .{
            .call = &call,
            .deinit = &deinit,
        };

        pub fn service(self: *Self) AnyService {
            return .{
                .ptr = @ptrCast(@alignCast(self)),
                .vtable = &ServiceVTable,
            };
        }
    };
    return FuncService;
}

pub fn createService(allocator: std.mem.Allocator, serv: anytype) !AnyService {
    _ = allocator; // Unused for now need for stateful services
    const info = @typeInfo(@TypeOf(serv));

    return switch (info) {
        .@"fn" => createFnService(serv),
        else => @panic("todo"),
    };
}

pub fn createFnService(func: anytype) !AnyService {
    const Container = ServiceFn(func);

    // Create static instance - one per unique function
    const static = struct {
        var instance: Container = .{};
    };

    return static.instance.service();
}
