const std = @import("std");
const bolt = @import("bolt");
const Btx = bolt.BoltContext;
const Request = bolt.Request;
const Response = bolt.Response;

pub fn hello(btx: Btx, req: Request) !Response {
    _ = req;
    return try Response.full(btx.allocator, "Hello World!");
}

pub fn helloMain(btx: Btx) !void {
    std.log.info("Starting server\n", .{});
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 3000);

    var server = try bolt.Server.bind(&address, .{});
    defer server.deinit();
    const hello_service = try bolt.service.createFnService(hello);
    try server.serve(btx, hello_service);
}

pub fn main() !void {
    try bolt.main(helloMain);
}
