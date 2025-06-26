const std = @import("std");
const lib = @import("../lib.zig");
const isToken = @import("request.zig").isToken;

pub const Response = struct {
    allocator: std.mem.Allocator,
    // Owned by Response
    body: []const u8,
    headers: lib.HeaderMap,
    status: lib.StatusCode,
    chunked: bool = false,
    owned_headers: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn fromBytes(alloc: std.mem.Allocator, bytes: []const u8) !Response {
        const buf = try alloc.alloc(u8, bytes.len);
        @memcpy(buf, bytes);
        return .{
            .body = buf,
            .allocator = alloc,
            .headers = .empty,
            .status = .OK,
        };
    }

    pub fn full(alloc: std.mem.Allocator, bytes: []const u8) !Response {
        var response = try fromBytes(alloc, bytes);
        errdefer response.deinit();

        try response.headers.put(alloc, "Content-Type", "text/plain");
        try response.headers.put(alloc, "Connection", "keep-alive");
        try response.headers.put(alloc, "Server", "bolt/0.1");
        var length_buf: [20]u8 = undefined;
        try response.setHeader("Content-Length", try std.fmt.bufPrint(&length_buf, "{d}", .{bytes.len}));
        return response;
    }

    // Copies the name and value. Direct inserts into headers are borrowed.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try validateHeader(name, value);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        try self.owned_headers.ensureUnusedCapacity(self.allocator, 2);
        const entry = try self.headers.getOrPut(self.allocator, owned_name);
        entry.key_ptr.* = owned_name;
        entry.value_ptr.* = owned_value;
        self.owned_headers.appendAssumeCapacity(owned_name);
        self.owned_headers.appendAssumeCapacity(owned_value);
    }

    pub fn validateHeader(name: []const u8, value: []const u8) !void {
        if (!isToken(name)) return error.InvalidResponseHeader;
        for (value) |c| {
            if ((c < 32 and c != '\t') or c == 127) return error.InvalidResponseHeader;
        }
    }

    pub fn formatDate(buffer: []u8, timestamp: i64) ![]const u8 {
        if (timestamp < 0 or timestamp > 253402300799) return error.InvalidTimestamp;
        const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
        const day = seconds.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = seconds.getDaySeconds();
        const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        return std.fmt.bufPrint(buffer, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            weekdays[(day.day + 4) % 7],
            @as(u8, month_day.day_index) + 1,
            months[@intFromEnum(month_day.month) - 1],
            year_day.year,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        });
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        for (self.owned_headers.items) |bytes| self.allocator.free(bytes);
        self.owned_headers.deinit(self.allocator);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};
