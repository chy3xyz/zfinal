//! Apply schema.sql DDL to an open DB.
const std = @import("std");
const zfinal = @import("zfinal");

pub const schema_sql = @embedFile("schema.sql");

/// Strip `--` line comments, then split on `;` and exec statements.
pub fn migrate(db: *zfinal.DB) !void {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(db.allocator);

    var lines = std.mem.splitScalar(u8, schema_sql, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        try cleaned.appendSlice(db.allocator, line);
        try cleaned.append(db.allocator, '\n');
    }

    var start: usize = 0;
    const sql = cleaned.items;
    while (start < sql.len) {
        const rest = sql[start..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse {
            const trimmed = std.mem.trim(u8, rest, " \t\r\n");
            if (trimmed.len > 0) {
                const z = try db.allocator.allocSentinel(u8, trimmed.len, 0);
                defer db.allocator.free(z);
                @memcpy(z, trimmed);
                try db.exec(z);
            }
            break;
        };
        const stmt = std.mem.trim(u8, rest[0..semi], " \t\r\n");
        start += semi + 1;
        if (stmt.len == 0) continue;
        const z = try db.allocator.allocSentinel(u8, stmt.len, 0);
        defer db.allocator.free(z);
        @memcpy(z, stmt);
        try db.exec(z);
    }
}
