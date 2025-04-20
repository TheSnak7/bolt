const std = @import("std");
const isToken = @import("request.zig").isToken;

pub fn chunkSize(line: []const u8) !u64 {
    var i: usize = 0;
    while (i < line.len and std.ascii.isHex(line[i])) : (i += 1) {}
    if (i == 0) return error.InvalidRequest;
    const size = std.fmt.parseInt(u64, line[0..i], 16) catch return error.BodyTooLarge;

    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i == line.len) break;
        if (line[i] != ';') return error.InvalidRequest;
        i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        const name_start = i;
        while (i < line.len and isToken(line[i..][0..1])) : (i += 1) {}
        if (i == name_start) return error.InvalidRequest;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i < line.len and line[i] == '=') {
            i += 1;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i == line.len) return error.InvalidRequest;
            if (line[i] == '"') {
                i += 1;
                while (true) {
                    if (i == line.len) return error.InvalidRequest;
                    const c = line[i];
                    i += 1;
                    if (c == '"') break;
                    if (c == '\\') {
                        if (i == line.len) return error.InvalidRequest;
                        if ((line[i] < 32 and line[i] != '\t') or line[i] == 127) return error.InvalidRequest;
                        i += 1;
                    } else if ((c < 32 and c != '\t') or c == 127) {
                        return error.InvalidRequest;
                    }
                }
            } else {
                const value_start = i;
                while (i < line.len and isToken(line[i..][0..1])) : (i += 1) {}
                if (i == value_start) return error.InvalidRequest;
            }
        }
    }
    return size;
}
