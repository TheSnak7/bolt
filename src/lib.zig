const std = @import("std");

pub const HeaderMap = std.HashMapUnmanaged([]const u8, []const u8, HeaderContext, std.hash_map.default_max_load_percentage);

const HeaderContext = struct {
    pub fn hash(_: HeaderContext, name: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (name) |c| {
            const lower = std.ascii.toLower(c);
            hasher.update(std.mem.asBytes(&lower));
        }
        return hasher.final();
    }

    pub fn eql(_: HeaderContext, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

pub const Version = enum {
    http10,
    http11,

    pub fn string(version: Version) []const u8 {
        return switch (version) {
            .http10 => "HTTP/1.0",
            .http11 => "HTTP/1.1",
        };
    }
};

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

        const method: Method = switch (encoded) {
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
        if (!std.mem.eql(u8, str, @tagName(method))) return error.InvalidMethod;
        return method;
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
    UriTooLong = 414,
    RequestHeaderFieldsTooLarge = 431,
    InternalServerError = 500,
    NotImplemented = 501,
    HttpVersionNotSupported = 505,

    pub fn string(s: StatusCode) []const u8 {
        return switch (s) {
            .OK => "OK",
            .BadRequest => "Bad Request",
            .NotFound => "Not Found",
            .UriTooLong => "URI Too Long",
            .RequestHeaderFieldsTooLarge => "Request Header Fields Too Large",
            .InternalServerError => "Internal Server Error",
            .NotImplemented => "Not Implemented",
            .HttpVersionNotSupported => "HTTP Version Not Supported",
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

pub fn bmatch(method: Method, uri: []const u8) u128 {
    return Matcher.case(method, uri).val;
}
