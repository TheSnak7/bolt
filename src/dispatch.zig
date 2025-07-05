const std = @import("std");
const Connection = @import("Connection.zig");
const Service = @import("service.zig").Service;
const Btx = @import("BoltContext.zig");
const lib = @import("lib.zig");
const Response = @import("protocol.zig").Response;

pub const DispatchServer = struct {
    connection: Connection,
    service: Service,

    // The service is borrowed and must outlive the dispatcher.
    pub fn init(connection: Connection, service: Service) DispatchServer {
        return .{
            .connection = connection,
            .service = service,
        };
    }

    pub fn deinit(self: *DispatchServer) void {
        self.connection.deinit();
    }

    pub fn call(self: *DispatchServer, btx: Btx) !void {
        std.log.debug("Opened connection", .{});
        defer std.log.debug("Closed connection", .{});

        var arena = std.heap.ArenaAllocator.init(btx.allocator);
        defer arena.deinit();

        while (true) {
            _ = arena.reset(.retain_capacity);
            const alloc = arena.allocator();
            const request = self.connection.read(alloc) catch |err| {
                const status: lib.StatusCode = switch (err) {
                    error.InvalidRequest, error.IncompleteRequest => .BadRequest,
                    error.RequestTimeout => .RequestTimeout,
                    error.RequestLineTooLong => .UriTooLong,
                    error.BodyTooLarge => .PayloadTooLarge,
                    error.HeadersTooLarge, error.TooManyHeaders => .RequestHeaderFieldsTooLarge,
                    error.UnsupportedMethod, error.UnsupportedTransferEncoding => .NotImplemented,
                    error.ExpectationFailed => .ExpectationFailed,
                    error.UnsupportedVersion => .HttpVersionNotSupported,
                    else => return err,
                };
                try self.sendError(alloc, status);
                break;
            } orelse break;

            std.log.info("request received: (method={s}, uri={s})", .{ @tagName(request.method), request.path() });

            const service_context = Btx.with(alloc, btx.scheduler);
            var response = self.service.call(service_context, request) catch |err| {
                if (err == error.Canceled) return err;
                std.log.err("Service failed: {s}", .{@errorName(err)});
                try self.sendError(alloc, .InternalServerError);
                break;
            };
            defer response.deinit();

            if (@intFromEnum(response.status) < 200) {
                try self.sendError(alloc, .InternalServerError);
                break;
            }
            self.connection.write(alloc, response) catch |err| switch (err) {
                error.InvalidResponseHeader,
                error.InvalidContentLength,
                error.UnsupportedTransferEncoding,
                error.UnsupportedUpgrade,
                error.UnsupportedTunnel,
                => {
                    std.log.err("Invalid response: {s}", .{@errorName(err)});
                    try self.sendError(alloc, .InternalServerError);
                    break;
                },
                else => return err,
            };

            std.log.info("response generated (status={})", .{response.status});

            if (self.connection.state.writing == .Closed) break;
        }

        self.connection.shutdown() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.BrokenPipe, error.SocketNotConnected => {},
            else => return err,
        };
    }

    fn sendError(self: *DispatchServer, alloc: std.mem.Allocator, status: lib.StatusCode) !void {
        var response = try Response.full(alloc, status.string());
        defer response.deinit();
        response.status = status;
        try response.headers.put(alloc, "Connection", "close");
        try self.connection.write(alloc, response);
    }
};
