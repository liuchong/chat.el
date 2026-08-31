const std = @import("std");

pub const User = struct {
    id: u32,
    name: []const u8,
};

pub const Status = struct {
    state: []const u8,
};

const label_prefix = "item";

pub fn findUser(users: []const User, user_id: u32) ?User {
    for (users) |user| {
        if (user.id == user_id) return user;
    }
    return null;
}

pub fn divide(left: u32, right: u32) !u32 {
    if (right == 0) return error.DivisionByZero;
    return left / right;
}

pub fn label(name: []const u8, output: []u8) ![]const u8 {
    const length = label_prefix.len + 1 + name.len;
    if (output.len < length) return error.NoSpaceLeft;
    @memcpy(output[0..label_prefix.len], label_prefix);
    output[label_prefix.len] = ':';
    @memcpy(output[label_prefix.len + 1 .. length], name);
    return output[0..length];
}

pub fn normalizeName(name: []const u8, output: []u8) ![]const u8 {
    var length: usize = 0;
    var pending_space = false;
    for (std.mem.trim(u8, name, " \t\n\r")) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = length > 0;
        } else {
            if (pending_space) {
                if (length >= output.len) return error.NoSpaceLeft;
                output[length] = ' ';
                length += 1;
                pending_space = false;
            }
            if (length >= output.len) return error.NoSpaceLeft;
            output[length] = std.ascii.toLower(byte);
            length += 1;
        }
    }
    return output[0..length];
}

pub fn active(status: Status) bool {
    return std.mem.eql(u8, status.state, "enabled");
}

pub fn isAdmin(role: []const u8) bool {
    return std.mem.startsWith(u8, role, "admin");
}
