const std = @import("std");
const zfinal = @import("zfinal");

/// User Model
pub const User = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
    created_at: ?[]const u8 = null,
};

pub const UserModel = zfinal.Model(User, "users");
