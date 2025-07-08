const std = @import("std");
const bolt = @import("bolt");

const Handler = struct {
    server: *bolt.Server,
    requests: usize = 0,

    pub fn call(self: *Handler, ctx: bolt.BoltContext, req: bolt.Request) !bolt.Response {
        self.requests += 1;
        if (req.method == .POST and std.mem.eql(u8, req.path(), "/shutdown")) {
            const response = try bolt.Response.full(ctx.allocator, "Shutting down\n");
            self.server.stop();
            return response;
        }

        var response = try bolt.Response.full(ctx.allocator, "POST /shutdown to stop the server\n");
        errdefer response.deinit();
        var buffer: [20]u8 = undefined;
        try response.setHeader("X-Requests", try std.fmt.bufPrint(&buffer, "{d}", .{self.requests}));
        return response;
    }
};

fn run(ctx: bolt.BoltContext) !void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);
    var server = try bolt.Server.bind(&address, .{ .max_connections = 128 });
    defer server.deinit();
    var handler: Handler = .{ .server = &server };
    const service = try bolt.service.createService(ctx.allocator, &handler);
    try server.serve(ctx, service);
    std.log.info("Handled {d} requests", .{handler.requests});
}

pub fn main() !void {
    try bolt.main(run);
}
