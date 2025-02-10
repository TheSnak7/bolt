const std = @import("std");
const coro = @import("coro");
const aio = @import("aio");

const AnyService = @import("service.zig").AnyService;
const BoltContext = @import("BoltContext.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const lib = @import("lib.zig");

const Self = @This();

services: []const AnyService,

const Options = struct {
    services: []const AnyService,
};

// Does not transfer ownership over services
pub fn init(options: Options) !Self {
    return .{
        .services = options.services,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
    std.log.debug("Deinit Http1", .{});
}

pub fn run(http: *Self, ctx: BoltContext, sock: std.posix.socket_t) !void {
    std.log.debug("Opened connection", .{});
    defer std.log.debug("Closed connection", .{});

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    connection: while (true) {
        _ = arena.reset(.retain_capacity);
        const arena_alloc = arena.allocator();

        var buf = try arena_alloc.alloc(u8, 4096);
        var len: usize = 0;

        try coro.io.single(.recv, .{ .socket = sock, .buffer = buf, .out_read = &len });

        if (len == 0) {
            std.log.debug("Client closed connection", .{});
            break :connection;
        }

        var first_line_it = std.mem.splitScalar(u8, buf[0..@min(len, 10)], ' ');
        const method_str = first_line_it.next() orelse {
            std.log.err("No Method in: {s}", .{buf[0..len]});
            continue :connection;
        };

        const method = lib.Method.parse(method_str) catch {
            std.log.err("Invalid Method in: {s}", .{buf[0..len]});
            continue :connection;
        };

        std.log.debug("Method: {s}", .{@tagName(method)});

        const path = first_line_it.next() orelse {
            std.log.err("No Path in: {s}", .{buf[0..len]});
            continue :connection;
        };

        const uri = std.Uri.parseAfterScheme("", path) catch {
            std.log.err("Failed to decode path to uri: '{s}'", .{path});
            continue :connection;
        };

        var it = std.http.HeaderIterator.init(buf[0..len]);
        var header_map: lib.HeaderMap = .empty;

        while (it.next()) |h| {
            header_map.put(arena_alloc, h.name, h.value) catch |e| {
                std.log.err("Failed to put head in map: {s}", .{@errorName(e)});
                continue :connection;
            };
        }

        // Get connection preference from request
        const connection_str = header_map.get("Connection") orelse "keep-alive";
        const connection = lib.Connection.parse(connection_str);

        const request = try Request.fromBuffer(
            arena_alloc,
            method,
            uri,
            connection, // Pass connection preference
            header_map,
            buf[it.index..len],
        );

        std.log.info("request received: (method={s}, uri={s})", .{ @tagName(request.method), request.path() });

        std.debug.assert(http.services.len == 1);
        const service = http.services[0];

        const service_context = BoltContext.with(arena_alloc, ctx.scheduler);
        var response = try service.call(service_context, request);

        // Set response connection header based on request preference
        try response.headers.put(arena_alloc, "Connection", connection.string());

        var response_buf = std.ArrayList(u8).init(arena_alloc);
        defer response_buf.deinit();

        // Use status code from response
        try response_buf.writer().print("HTTP/1.1 {d} {s}\r\n", .{
            @intFromEnum(response.status),
            response.status.string(),
        });

        var header_it = response.headers.iterator();
        while (header_it.next()) |entry| {
            try response_buf.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try response_buf.appendSlice("\r\n");
        try response_buf.appendSlice(response.body);

        std.log.info("response generated (status={})", .{response.status});

        try coro.io.single(.send, .{ .socket = sock, .buffer = response_buf.items });

        // Use the connection preference we parsed
        if (connection == .Close) {
            std.log.debug("Connection: close requested", .{});
            break :connection;
        }
    }

    try coro.io.single(.close_socket, .{ .socket = sock });
    defer http.deinit();
}

pub fn spawn(self: *Self, ctx: BoltContext, sock: std.posix.socket_t) !void {
    _ = try ctx.scheduler.spawn(run, .{ self, ctx, sock }, .{});
}
