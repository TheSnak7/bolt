const std = @import("std");

const lib = @import("../lib.zig");

pub const Request = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    headers: lib.HeaderMap,
    method: lib.Method,
    uri: std.Uri,
    connection: lib.Connection,
    version: lib.Version = .http11,
    target: []const u8 = "",
    content_length: ?u64 = null,

    pub fn path(self: *const Request) []const u8 {
        if (self.uri.path.isEmpty() and self.method != .CONNECT) return "/";
        return switch (self.uri.path) {
            .percent_encoded => |p| p,
            .raw => |r| r,
        };
    }

    // All request data belongs to the per-request arena.
    pub fn parseHead(alloc: std.mem.Allocator, head: []const u8, max_headers: usize) !Request {
        if (!std.mem.endsWith(u8, head, "\r\n\r\n")) return error.InvalidRequest;
        const bytes = try alloc.dupe(u8, head[0 .. head.len - 4]);
        var lines = std.mem.splitSequence(u8, bytes, "\r\n");
        var first_line = std.mem.splitScalar(u8, lines.next().?, ' ');
        const method_str = first_line.next().?;
        const target = first_line.next() orelse return error.InvalidRequest;
        const version_str = first_line.next() orelse return error.InvalidRequest;
        if (first_line.next() != null or !isToken(method_str)) return error.InvalidRequest;

        const version: lib.Version = if (std.mem.eql(u8, version_str, "HTTP/1.0"))
            .http10
        else if (std.mem.eql(u8, version_str, "HTTP/1.1"))
            .http11
        else {
            if (version_str.len != 8 or !std.mem.startsWith(u8, version_str, "HTTP/") or
                !std.ascii.isDigit(version_str[5]) or version_str[6] != '.' or
                !std.ascii.isDigit(version_str[7])) return error.InvalidRequest;
            return error.UnsupportedVersion;
        };

        const method = lib.Method.parse(method_str) catch return error.UnsupportedMethod;
        const uri = try parseTarget(alloc, method, target);
        var headers: lib.HeaderMap = .empty;
        var header_count: usize = 0;

        while (lines.next()) |line| {
            header_count += 1;
            if (header_count > max_headers) return error.TooManyHeaders;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (!isToken(name)) return error.InvalidRequest;
            for (value) |c| {
                if ((c < 32 and c != '\t') or c == 127) return error.InvalidRequest;
            }

            if (headers.getPtr(name)) |previous| {
                if (std.ascii.eqlIgnoreCase(name, "Host") or
                    std.ascii.eqlIgnoreCase(name, "Content-Length")) return error.InvalidRequest;
                const separator = if (std.ascii.eqlIgnoreCase(name, "Cookie")) "; " else ", ";
                previous.* = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ previous.*, separator, value });
            } else {
                try headers.put(alloc, name, value);
            }
        }

        if (headers.get("Host")) |host| {
            _ = try parseAuthority(alloc, host, false);
        } else if (version == .http11) {
            return error.InvalidRequest;
        }

        var content_length: ?u64 = null;
        if (headers.get("Content-Length")) |length| {
            if (length.len == 0 or headers.contains("Transfer-Encoding")) return error.InvalidRequest;
            for (length) |c| {
                if (!std.ascii.isDigit(c)) return error.InvalidRequest;
            }
            content_length = std.fmt.parseInt(u64, length, 10) catch return error.InvalidRequest;
        }

        var connection: lib.Connection = if (version == .http10) .Close else .KeepAlive;
        if (headers.get("Connection")) |value| {
            var tokens = std.mem.splitScalar(u8, value, ',');
            var close = false;
            while (tokens.next()) |part| {
                const token = std.mem.trim(u8, part, " \t");
                if (token.len == 0) continue;
                if (!isToken(token)) return error.InvalidRequest;
                if (std.ascii.eqlIgnoreCase(token, "close")) close = true;
                if (std.ascii.eqlIgnoreCase(token, "keep-alive")) connection = .KeepAlive;
            }
            if (close) connection = .Close;
        }

        return .{
            .allocator = alloc,
            .body = "",
            .headers = headers,
            .method = method,
            .uri = uri,
            .connection = connection,
            .version = version,
            .target = target,
            .content_length = content_length,
        };
    }

    // No transfer of ownership, because of unclear lifetimes.
    pub fn fromBuffer(alloc: std.mem.Allocator, method: lib.Method, uri: std.Uri, connection: lib.Connection, headers: lib.HeaderMap, buf: []const u8) !Request {
        const buf_copy = try alloc.alloc(u8, buf.len);
        @memcpy(buf_copy, buf);

        return .{
            .allocator = alloc,
            .body = buf_copy,
            .headers = headers,
            .method = method,
            .uri = uri,
            .connection = connection,
        };
    }
};

fn isToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return false;
    }
    return true;
}

fn parseTarget(alloc: std.mem.Allocator, method: lib.Method, target: []const u8) !std.Uri {
    if (target.len == 0) return error.InvalidRequest;
    for (target, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~:/?[]@!$&'()*+,;=%", c) == null) return error.InvalidRequest;
        if (c == '%' and (i + 2 >= target.len or
            !std.ascii.isHex(target[i + 1]) or !std.ascii.isHex(target[i + 2]))) return error.InvalidRequest;
    }

    if (method == .CONNECT) return parseAuthority(alloc, target, true);
    if (std.mem.eql(u8, target, "*")) {
        if (method != .OPTIONS) return error.InvalidRequest;
        return .{ .scheme = "", .path = .{ .percent_encoded = "*" } };
    }
    if (target[0] == '/') {
        if (std.mem.indexOfAny(u8, target, "[]") != null) return error.InvalidRequest;
        const query = std.mem.indexOfScalar(u8, target, '?');
        return .{
            .scheme = "",
            .path = .{ .percent_encoded = target[0 .. query orelse target.len] },
            .query = if (query) |i| .{ .percent_encoded = target[i + 1 ..] } else null,
        };
    }

    const scheme_end = std.mem.indexOf(u8, target, "://") orelse return error.InvalidRequest;
    const scheme = target[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return error.InvalidRequest;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, target, authority_start, "/?") orelse target.len;
    _ = try parseAuthority(alloc, target[authority_start..authority_end], false);
    if (std.mem.indexOfAny(u8, target[authority_end..], "[]") != null) return error.InvalidRequest;
    return std.Uri.parse(target) catch return error.InvalidRequest;
}

fn parseAuthority(alloc: std.mem.Allocator, authority: []const u8, require_port: bool) !std.Uri {
    if (authority.len == 0) return error.InvalidRequest;
    var port_start: ?usize = null;
    if (authority[0] == '[') {
        const end = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidRequest;
        _ = std.net.Address.parseIp6(authority[1..end], 0) catch return error.InvalidRequest;
        if (end + 1 < authority.len) {
            if (authority[end + 1] != ':') return error.InvalidRequest;
            port_start = end + 2;
        }
    } else {
        const end = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        if (end == 0) return error.InvalidRequest;
        for (authority[0..end], 0..) |c, i| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=%", c) == null) return error.InvalidRequest;
            if (c == '%' and (i + 2 >= end or !std.ascii.isHex(authority[i + 1]) or
                !std.ascii.isHex(authority[i + 2]))) return error.InvalidRequest;
        }
        if (end < authority.len) port_start = end + 1;
    }
    if (port_start) |start| {
        if (start == authority.len) return error.InvalidRequest;
        for (authority[start..]) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidRequest;
        }
        _ = std.fmt.parseInt(u16, authority[start..], 10) catch return error.InvalidRequest;
    } else if (require_port) {
        return error.InvalidRequest;
    }
    const uri = try std.fmt.allocPrint(alloc, "//{s}", .{authority});
    return std.Uri.parseAfterScheme("", uri) catch return error.InvalidRequest;
}
