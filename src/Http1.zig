const std = @import("std");
const Service = @import("service.zig").Service;
const Btx = @import("BoltContext.zig");
const Connection = @import("Connection.zig");
const DispatchServer = @import("dispatch.zig").DispatchServer;
const AnyStream = @import("stream.zig").AnyStream;

const Self = @This();

const Context = struct {
    h1_keep_alive: bool,
};

ctx: Context,

const Options = struct {
    h1_keep_alive: bool = true,
};

pub fn init(options: Options) !Self {
    return .{
        .ctx = .{
            .h1_keep_alive = options.h1_keep_alive,
        },
    };
}

// Takes ownership of the stream. The service is borrowed.
pub fn call(self: Self, btx: Btx, stream: anytype, service: Service) !void {
    var owned_stream = stream;
    var dispatcher = self.makeDispatcher(owned_stream.any(), service) catch |err| {
        owned_stream.deinit();
        return err;
    };
    defer dispatcher.deinit();

    dispatcher.call(btx) catch |err| {
        if (err != error.Canceled) std.log.err("Connection failed: {s}", .{@errorName(err)});
        return err;
    };
}

// The separation makes sense if we expand to HTTP2.
pub fn makeDispatcher(self: Self, stream: AnyStream, service: Service) !DispatchServer {
    var conn = try Connection.init(stream);
    conn.state.keep_alive = self.ctx.h1_keep_alive;
    return DispatchServer.init(conn, service);
}
