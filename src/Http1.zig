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
    h1_max_requests: usize,
    max_header_size: usize,
    max_request_line_size: usize,
    max_body_size: usize,
    date_header: bool,
    keep_alive_timeout: ?u64,
    read_timeout: ?u64,
    write_timeout: ?u64,
    shutdown_timeout: u64,
};

ctx: Context,

pub const Options = struct {
    h1_keep_alive: bool = true,
    h1_max_headers: usize = 100,
    h1_max_requests: usize = 1000,
    max_header_size: usize = 16 * 1024,
    max_request_line_size: usize = 8192,
    max_body_size: usize = 1024 * 1024,
    date_header: bool = true,
    // Timeouts are in nanoseconds. null disables the read/write deadlines.
    keep_alive_timeout: ?u64 = 5 * std.time.ns_per_s,
    read_timeout: ?u64 = 30 * std.time.ns_per_s,
    write_timeout: ?u64 = 30 * std.time.ns_per_s,
    shutdown_timeout: u64 = std.time.ns_per_s,
};

pub fn init(options: Options) !Self {
    if (options.max_header_size < 4 or options.max_request_line_size == 0) return error.InvalidOptions;
    return .{
        .ctx = .{
            .h1_keep_alive = options.h1_keep_alive,
            .h1_max_headers = options.h1_max_headers,
            .h1_max_requests = options.h1_max_requests,
            .max_header_size = options.max_header_size,
            .max_request_line_size = options.max_request_line_size,
            .max_body_size = options.max_body_size,
            .date_header = options.date_header,
            .keep_alive_timeout = options.keep_alive_timeout,
            .read_timeout = options.read_timeout,
            .write_timeout = options.write_timeout,
            .shutdown_timeout = options.shutdown_timeout,
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
        switch (err) {
            error.Canceled, error.Timeout, error.ConnectionResetByPeer, error.BrokenPipe, error.SocketNotConnected => {},
            else => std.log.err("Connection failed: {s}", .{@errorName(err)}),
        }
        return err;
    };
}

// The separation makes sense if we expand to HTTP2.
pub fn makeDispatcher(self: Self, allocator: std.mem.Allocator, stream: AnyStream, service: Service) !DispatchServer {
    var conn = try Connection.init(allocator, stream);
    conn.state.keep_alive = self.ctx.h1_keep_alive;
    conn.max_headers = self.ctx.h1_max_headers;
    conn.max_requests = self.ctx.h1_max_requests;
    conn.max_header_size = self.ctx.max_header_size;
    conn.max_request_line_size = self.ctx.max_request_line_size;
    conn.max_body_size = self.ctx.max_body_size;
    conn.date_header = self.ctx.date_header;
    conn.keep_alive_timeout = self.ctx.keep_alive_timeout;
    conn.read_timeout = self.ctx.read_timeout;
    conn.write_timeout = self.ctx.write_timeout;
    conn.shutdown_timeout = self.ctx.shutdown_timeout;
    return DispatchServer.init(conn, service);
}
