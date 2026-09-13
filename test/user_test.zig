const std = @import("std");
const zfinal = @import("zfinal");
const testing = std.testing;

test "Users CRUD" {
    const allocator = std.testing.allocator;
    const config = zfinal.DBConfig.sqliteMemory();
    var db = try zfinal.DB.init(allocator, config);
    defer db.deinit();
    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT)");
    try testing.expect(true);
}
