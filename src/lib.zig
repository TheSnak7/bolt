const std = @import("std");

pub const HeaderMap = std.StringHashMapUnmanaged([]const u8);

// More convenient type than std.http.Method
pub const Method = enum(u8) {
    GET = 0,
    HEAD = 1,
    POST = 2,
    PUT = 3,
    DELETE = 4,
    CONNECT = 5,
    OPTIONS = 6,
    TRACE = 7,
    PATCH = 8,

    pub fn encode(str: []const u8) u64 {
        // Taken from std.http.Method
        // TODO: Investigate whether optimal
        var x: u64 = 0;
        const len = @min(str.len, @sizeOf(@TypeOf(x)));
        @memcpy(std.mem.asBytes(&x)[0..len], str[0..len]);
        return x;
    }

    pub fn parse(str: []const u8) !Method {
        const encoded = encode(str);

        return switch (encoded) {
            encode("GET") => .GET,
            encode("HEAD") => .HEAD,
            encode("POST") => .POST,
            encode("PUT") => .PUT,
            encode("DELETE") => .DELETE,
            encode("CONNECT") => .CONNECT,
            encode("OPTIONS") => .OPTIONS,
            encode("TRACE") => .TRACE,
            encode("PATCH") => .PATCH,
            else => return error.InvalidMethod,
        };
    }
};

pub const Connection = enum {
    KeepAlive,
    Close,

    pub fn parse(str: []const u8) Connection {
        if (std.ascii.eqlIgnoreCase(str, "close")) {
            return .Close;
        }

        return .KeepAlive;
    }

    pub fn string(c: Connection) []const u8 {
        return switch (c) {
            .KeepAlive => "keep-alive",
            .Close => "close",
        };
    }
};

pub const StatusCode = enum(u16) {
    OK = 200,
    BadRequest = 400,
    NotFound = 404,
    InternalServerError = 500,

    pub fn string(s: StatusCode) []const u8 {
        return switch (s) {
            .OK => "OK",
            .BadRequest => "Bad Request",
            .NotFound => "Not Found",
            .InternalServerError => "Internal Server Error",
        };
    }
};

// wait for #22214
pub const Matcher = packed struct(u128) {
    val: u128,

    pub fn case(method: Method, uri: []const u8) Matcher {
        var val: u128 = 0;
        val |= @intFromEnum(method);
        val <<= 64;
        val |= std.hash.Wyhash.hash(789789789, uri);
        return .{ .val = val };
    }
};

pub fn match(method: Method, uri: []const u8) u128 {
    return Matcher.case(method, uri).val;
}
