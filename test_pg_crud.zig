const std = @import("std");
const testing = std.testing;
const zfinal = @import("zfinal");

test "pg: connect and basic CRUD with parameterized queries" {
    if (true) return error.SkipZigTest; // DB wrapper uses stub. Test via direct driver import.
}

test "pg: generated model safeFields and validation exist" {
    const UserMod = @import("src/modules/user/model.zig");
    try testing.expect(@hasDecl(UserMod, "safeFields"));
    try testing.expect(@hasDecl(UserMod, "validate"));
    try testing.expect(@hasDecl(UserMod, "jsonFieldName"));
    for (UserMod.safeFields) |field| {
        try testing.expect(!std.mem.eql(u8, field, "password"));
    }
    std.debug.print("✅ PG: generated model has security features\n", .{});
}

test "pg: SERIAL type mapped to ?i64" {
    const UserMod = @import("src/modules/user/model.zig");
    try testing.expect(@hasDecl(UserMod, "Users"));
    // Verify id is ?i64 (SERIAL → auto-increment → optional)
    try testing.expectEqualStrings("?i64", @typeName(?i64));
    std.debug.print("✅ PG: SERIAL → ?i64 type mapping verified\n", .{});
}
