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
                    error.RequestLineTooLong => .UriTooLong,
                    error.BodyTooLarge => .PayloadTooLarge,
                    error.HeadersTooLarge, error.TooManyHeaders => .RequestHeaderFieldsTooLarge,
                    error.UnsupportedMethod, error.UnsupportedTransferEncoding => .NotImplemented,
                    error.ExpectationFailed => .ExpectationFailed,
                    error.UnsupportedVersion => .HttpVersionNotSupported,
                    else => return err,
                };
                var response = try Response.full(alloc, status.string());
                defer response.deinit();
                response.status = status;
                try response.headers.put(alloc, "Connection", "close");
                try self.connection.write(alloc, response);
                break;
            } orelse break;

            std.log.info("request received: (method={s}, uri={s})", .{ @tagName(request.method), request.path() });

            const service_context = Btx.with(alloc, btx.scheduler);
            var response = try self.service.call(service_context, request);
            defer response.deinit();

            const connection = if (self.connection.state.keep_alive) request.connection else .Close;
            try response.headers.put(response.allocator, "Connection", connection.string());
            try self.connection.write(alloc, response);

            std.log.info("response generated (status={})", .{response.status});

            if (connection == .Close) break;
        }
    }
};
