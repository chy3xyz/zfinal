const std = @import("std");

/// Database type enumeration
pub const DBType = enum {
    postgres,
    mysql,
    sqlite,
};

/// TLS / SSL mode for the connection. Maps to libpq's `sslmode` for
/// PostgreSQL and to MySQL's `enum mysql_ssl_mode` for MySQL.
///
/// - `disable`: refuse SSL. Useful for local dev.
/// - `prefer`:  try SSL first, fall back to plaintext if unavailable.
///              This is the libpq default; not recommended for cloud.
/// - `require`: require SSL, do not verify the server certificate.
/// - `verify_ca`: require SSL + verify CA chain.
/// - `verify_full`: require SSL + verify CA chain AND hostname.
pub const SSLMode = enum {
    disable,
    prefer,
    require,
    verify_ca,
    verify_full,
};

/// Database configuration
pub const DBConfig = struct {
    db_type: DBType,

    // Connection parameters (for Postgres/MySQL)
    host: ?[]const u8 = null,
    port: ?u16 = null,
    /// Unix domain socket path. When set, the driver connects via the
    /// local socket instead of TCP. For PostgreSQL this becomes
    /// `host=/path` in conninfo (port is ignored). For MySQL the path
    /// is passed as the 7th arg to `mysql_real_connect`. Leave null for
    /// the default TCP behavior.
    unix_socket: ?[]const u8 = null,

    // Database name or file path
    database: []const u8,

    // Authentication (for Postgres/MySQL)
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    // Additional options
    max_connections: u32 = 10,
    /// Connect timeout in seconds. Applies to PG (`connect_timeout=N` in
    /// conninfo) and MySQL (`MYSQL_OPT_CONNECT_TIMEOUT`). Was previously
    /// declared but not honored — wired through in v0.14.0.
    timeout: u32 = 30,
    /// TLS mode. Defaults to `.prefer` for dev convenience, but production
    /// users on cloud DBs should explicitly set `.require` or stronger.
    ssl_mode: SSLMode = .prefer,

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

test "config ssl_mode defaults to prefer" {
    const cfg = DBConfig.postgres("mydb", "user", "pass");
    try std.testing.expectEqual(SSLMode.prefer, cfg.ssl_mode);
}
