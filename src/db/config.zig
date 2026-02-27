const std = @import("std");

/// Database type enumeration
pub const DBType = enum {
    postgres,
    mysql,
    sqlite,
};

/// Database configuration
pub const DBConfig = struct {
    db_type: DBType,

    // Connection parameters (for Postgres/MySQL)
    host: ?[]const u8 = null,
    port: ?u16 = null,

    // Database name or file path
    database: []const u8,

    // Authentication (for Postgres/MySQL)
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    // Additional options
    max_connections: u32 = 10,
    timeout: u32 = 30, // seconds

    /// Create PostgreSQL configuration
    pub fn postgres(database: []const u8, username: []const u8, password: []const u8) DBConfig {
        return DBConfig{
            .db_type = .postgres,
            .host = "localhost",
            .port = 5432,
            .database = database,
            .username = username,
            .password = password,
        };
    }

    /// Create MySQL configuration
    pub fn mysql(database: []const u8, username: []const u8, password: []const u8) DBConfig {
        return DBConfig{
            .db_type = .mysql,
            .host = "localhost",
            .port = 3306,
            .database = database,
            .username = username,
            .password = password,
        };
    }

    /// Create SQLite configuration
    pub fn sqlite(path: []const u8) DBConfig {
        return DBConfig{
            .db_type = .sqlite,
            .database = path,
        };
    }

    /// Create in-memory SQLite configuration
    pub fn sqliteMemory() DBConfig {
        return DBConfig{
            .db_type = .sqlite,
            .database = ":memory:",
        };
    }
};

test "config creation" {
    const pg_config = DBConfig.postgres("mydb", "user", "pass");
    try std.testing.expectEqual(DBType.postgres, pg_config.db_type);
    try std.testing.expectEqualStrings("mydb", pg_config.database);

    const sqlite_config = DBConfig.sqlite("test.db");
    try std.testing.expectEqual(DBType.sqlite, sqlite_config.db_type);
    try std.testing.expectEqualStrings("test.db", sqlite_config.database);
}
