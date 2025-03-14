const std = @import("std");
const Service = @import("service.zig").Service;
const Btx = @import("BoltContext.zig");
const Connection = @import("Connection.zig");
const DispatchServer = @import("dispatch.zig").DispatchServer;
const AnyStream = @import("stream.zig").AnyStream;

const Self = @This();

const Context = struct {
    h1_keep_alive: bool,
    h1_max_headers: usize,
    max_header_size: usize,
    max_request_line_size: usize,
};

ctx: Context,

const Options = struct {
    h1_keep_alive: bool = true,
    h1_max_headers: usize = 100,
    max_header_size: usize = 16 * 1024,
    max_request_line_size: usize = 8192,
};

pub fn init(options: Options) !Self {
    if (options.max_header_size < 4 or options.max_request_line_size == 0) return error.InvalidOptions;
    return .{
        .ctx = .{
            .h1_keep_alive = options.h1_keep_alive,
            .h1_max_headers = options.h1_max_headers,
            .max_header_size = options.max_header_size,
            .max_request_line_size = options.max_request_line_size,
        },
    };
}

// Takes ownership of the stream. The service is borrowed.
pub fn call(self: Self, btx: Btx, stream: anytype, service: Service) !void {
    var owned_stream = stream;
    var dispatcher = self.makeDispatcher(btx.allocator, owned_stream.any(), service) catch |err| {
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
pub fn makeDispatcher(self: Self, allocator: std.mem.Allocator, stream: AnyStream, service: Service) !DispatchServer {
    var conn = try Connection.init(allocator, stream);
    conn.state.keep_alive = self.ctx.h1_keep_alive;
    conn.max_headers = self.ctx.h1_max_headers;
    conn.max_header_size = self.ctx.max_header_size;
    conn.max_request_line_size = self.ctx.max_request_line_size;
    return DispatchServer.init(conn, service);
}
