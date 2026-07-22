//! Cross-driver SQL error diagnostics.
//!
//! Maps driver-specific error signals (PG SQLSTATE / MySQL errno / SQLite
//! message text) to a unified set of typed errors and an extracted
//! `{table, column}` for AI-friendly reporting.
//!
//! AI-friendly goal: `error.UniqueViolation` with `table = "users"`,
//! `column = "email"` — instead of the driver-default
//! `"UNIQUE constraint failed: users.email (code 19)"`.
//!
//! Reference: SQLSTATE class 23 (integrity constraint violation) is
//! ISO/ANSI standard; see also PostgreSQL appendix A and MySQL
//! `mysqld_error.h`.

const std = @import("std");

/// Unified error categories across SQLite / PostgreSQL / MySQL.
pub const ErrorCode = enum {
    /// INSERT/UPDATE would violate a UNIQUE constraint.
    /// PG SQLSTATE 23505, MySQL errno 1062, SQLite message "UNIQUE constraint failed".
    unique_violation,
    /// FK constraint fails (parent missing or child rows still reference).
    /// PG 23503, MySQL 1452 / 1451, SQLite "FOREIGN KEY constraint failed".
    foreign_key_violation,
    /// CHECK constraint rejection.
    /// PG 23514, MySQL 3819, SQLite "CHECK constraint failed".
    check_violation,
    /// NOT NULL column received NULL.
    /// PG 23502, MySQL 1048, SQLite "NOT NULL constraint failed".
    not_null_violation,
    /// InnoDB row/table lock wait timeout.
    /// PG 55P03, MySQL 1205.
    lock_timeout,
    /// InnoDB deadlock found when trying to get lock.
    /// PG 40P01, MySQL 1213.
    deadlock,
    /// Other integrity violation (any 23xxx other than above).
    integrity_violation,
    /// SQL syntax error.
    /// PG 42601, MySQL 1064, SQLite "syntax error".
    parse_error,
    /// Unknown table / relation.
    /// PG 42P01, MySQL 1146.
    unknown_table,
    /// Driver / connection-level failure (transient or permanent).
    /// Use `error.ConnectionFailed` for the latter; this is for
    /// in-progress operations where the server went away.
    connection_lost,
    /// Anything we did not classify.
    other,
};

/// Diagnostic payload returned alongside a typed error. The `table` and
/// `column` slices are owned by the caller (or borrowed from the driver
/// result — see driver notes). For SQLite they are parsed from the
/// error message; for PG from `PQresultErrorField`; for MySQL from
/// `mysql_error()` and best-effort column hint.
pub const Diag = struct {
    code: ErrorCode,
    message: []const u8,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
    /// Raw signal — SQLSTATE for PG, errno number as ASCII for MySQL, etc.
    raw: []const u8 = "",
};

/// Convert a SQLSTATE class 23 (integrity) into the more specific
/// ErrorCode. Returns `integrity_violation` for any other 23xxx we do
/// not list explicitly.
///
/// Caller must guarantee `sqlstate.len >= 2`.
pub fn pgIntegrityCode(sqlstate: []const u8) ErrorCode {
    if (sqlstate.len < 2) return .integrity_violation;
    // 23xxx: integrity constraint violation
    if (!std.mem.eql(u8, sqlstate[0..2], "23")) return .other;
    if (sqlstate.len < 5) return .integrity_violation;
    // Last 3 chars identify the specific constraint violation.
    if (std.mem.eql(u8, sqlstate[2..5], "505")) return .unique_violation;
    if (std.mem.eql(u8, sqlstate[2..5], "503")) return .foreign_key_violation;
    if (std.mem.eql(u8, sqlstate[2..5], "514")) return .check_violation;
    if (std.mem.eql(u8, sqlstate[2..5], "502")) return .not_null_violation;
    return .integrity_violation;
}

/// Convert a non-integrity SQLSTATE into a coarse ErrorCode.
pub fn pgCodeFromSqlstate(sqlstate: []const u8) ErrorCode {
    if (sqlstate.len < 2) return .other;
    // 40P01: deadlock_detected, 55P03: lock_not_available
    if (std.mem.eql(u8, sqlstate[0..5], "40P01")) return .deadlock;
    if (std.mem.eql(u8, sqlstate[0..5], "55P03")) return .lock_timeout;
    // 42xxx: syntax error or access rule violation
    if (std.mem.eql(u8, sqlstate[0..2], "42")) {
        if (sqlstate.len >= 5 and std.mem.eql(u8, sqlstate[2..5], "601")) return .parse_error;
        if (sqlstate.len >= 5 and std.mem.eql(u8, sqlstate[2..5], "P01")) return .unknown_table;
    }
    return .other;
}

/// Top-level dispatcher: returns the unified ErrorCode for any SQLSTATE.
pub fn pgCode(sqlstate: []const u8) ErrorCode {
    if (sqlstate.len < 2) return .other;
    if (std.mem.eql(u8, sqlstate[0..2], "23")) return pgIntegrityCode(sqlstate);
    return pgCodeFromSqlstate(sqlstate);
}

/// Map a MySQL errno to ErrorCode. We only handle the ~15 codes we
/// expect to encounter; everything else returns `.other`.
pub fn mysqlCode(errno_val: u16) ErrorCode {
    return switch (errno_val) {
        1062 => .unique_violation,
        1451, 1452 => .foreign_key_violation,
        3819 => .check_violation,
        1048, 1364, 1366 => .not_null_violation,
        1205 => .lock_timeout,
        1213 => .deadlock,
        1064 => .parse_error,
        1146 => .unknown_table,
        else => .other,
    };
}

/// Map an ErrorCode to the corresponding Zig error variant. Use this
/// when returning from a driver function so callers get typed errors.
pub fn toError(code: ErrorCode) DbError {
    return switch (code) {
        .unique_violation => error.UniqueViolation,
        .foreign_key_violation => error.ForeignKeyViolation,
        .check_violation => error.CheckViolation,
        .not_null_violation => error.NotNullViolation,
        .lock_timeout => error.LockTimeout,
        .deadlock => error.Deadlock,
        .integrity_violation => error.IntegrityViolation,
        .parse_error => error.ParseError,
        .unknown_table => error.UnknownTable,
        .connection_lost => error.ConnectionLost,
        .other => error.ExecFailed,
    };
}

/// Unified DB error set. Driver functions may return any subset of
/// these (compatibility with `error{ExecFailed,QueryFailed,...}`).
pub const DbError = error{
    DataTruncated,
    ExecFailed,
    QueryFailed,
    StmtInitFailed,
    PrepareFailed,
    BindFailed,
    FetchFailed,
    BinlogOpenFailed,
    BinlogFetchFailed,
    UniqueViolation,
    ForeignKeyViolation,
    CheckViolation,
    NotNullViolation,
    LockTimeout,
    Deadlock,
    IntegrityViolation,
    ParseError,
    UnknownTable,
    ConnectionLost,
    InitFailed,
    ConnectionFailed,
};

/// Extract `table` and `column` from a SQLite-style error message of
/// the form:
///   "UNIQUE constraint failed: users.email"
///   "FOREIGN KEY constraint failed: posts.user_id"
///   "CHECK constraint failed: ck_positive_age"
///   "NOT NULL constraint failed: users.email"
///
/// Returns `null` slices when the parse fails. The returned slices are
/// owned by the caller (do NOT free them).
pub fn parseSqliteTableColumn(message: []const u8) struct { table: ?[]const u8, column: ?[]const u8 } {
    const colon = std.mem.indexOfScalar(u8, message, ':') orelse return .{ .table = null, .column = null };
    var rest = std.mem.trim(u8, message[colon + 1..], " ");
    // For FK errors SQLite uses "FOREIGN KEY constraint failed: table.column"
    // or just "FOREIGN KEY constraint failed" without target.
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    if (dot) |d| {
        return .{
            .table = rest[0..d],
            .column = rest[d + 1 ..],
        };
    }
    return .{ .table = rest, .column = null };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "pgCode: 23xxx integrity class" {
    try std.testing.expectEqual(ErrorCode.unique_violation, pgCode("23505"));
    try std.testing.expectEqual(ErrorCode.foreign_key_violation, pgCode("23503"));
    try std.testing.expectEqual(ErrorCode.check_violation, pgCode("23514"));
    try std.testing.expectEqual(ErrorCode.not_null_violation, pgCode("23502"));
    try std.testing.expectEqual(ErrorCode.integrity_violation, pgCode("23999")); // generic 23xxx
}

test "pgCode: 40P01 deadlock / 55P03 lock_timeout" {
    try std.testing.expectEqual(ErrorCode.deadlock, pgCode("40P01"));
    try std.testing.expectEqual(ErrorCode.lock_timeout, pgCode("55P03"));
}

test "pgCode: 42xxx syntax/table" {
    try std.testing.expectEqual(ErrorCode.parse_error, pgCode("42601"));
    try std.testing.expectEqual(ErrorCode.unknown_table, pgCode("42P01"));
}

test "pgCode: empty/short" {
    try std.testing.expectEqual(ErrorCode.other, pgCode(""));
    try std.testing.expectEqual(ErrorCode.other, pgCode("2"));
    try std.testing.expectEqual(ErrorCode.other, pgCode("99999"));
}

test "mysqlCode: known errnos" {
    try std.testing.expectEqual(ErrorCode.unique_violation, mysqlCode(1062));
    try std.testing.expectEqual(ErrorCode.foreign_key_violation, mysqlCode(1451));
    try std.testing.expectEqual(ErrorCode.foreign_key_violation, mysqlCode(1452));
    try std.testing.expectEqual(ErrorCode.check_violation, mysqlCode(3819));
    try std.testing.expectEqual(ErrorCode.not_null_violation, mysqlCode(1048));
    try std.testing.expectEqual(ErrorCode.lock_timeout, mysqlCode(1205));
    try std.testing.expectEqual(ErrorCode.deadlock, mysqlCode(1213));
    try std.testing.expectEqual(ErrorCode.parse_error, mysqlCode(1064));
    try std.testing.expectEqual(ErrorCode.unknown_table, mysqlCode(1146));
    try std.testing.expectEqual(ErrorCode.other, mysqlCode(9999));
}

test "toError: maps every ErrorCode to a typed error" {
    // expectError requires an error union, so wrap toError() in a helper.
    const Fail = struct {
        fn go(code: ErrorCode) DbError!void {
            return toError(code);
        }
    };
    try std.testing.expectError(error.UniqueViolation, Fail.go(.unique_violation));
    try std.testing.expectError(error.ForeignKeyViolation, Fail.go(.foreign_key_violation));
    try std.testing.expectError(error.CheckViolation, Fail.go(.check_violation));
    try std.testing.expectError(error.NotNullViolation, Fail.go(.not_null_violation));
    try std.testing.expectError(error.LockTimeout, Fail.go(.lock_timeout));
    try std.testing.expectError(error.Deadlock, Fail.go(.deadlock));
    try std.testing.expectError(error.IntegrityViolation, Fail.go(.integrity_violation));
    try std.testing.expectError(error.ParseError, Fail.go(.parse_error));
    try std.testing.expectError(error.UnknownTable, Fail.go(.unknown_table));
    try std.testing.expectError(error.ConnectionLost, Fail.go(.connection_lost));
    try std.testing.expectError(error.ExecFailed, Fail.go(.other));
}

test "parseSqliteTableColumn: UNIQUE constraint format" {
    const r = parseSqliteTableColumn("UNIQUE constraint failed: users.email");
    try std.testing.expectEqualStrings("users", r.table.?);
    try std.testing.expectEqualStrings("email", r.column.?);
}

test "parseSqliteTableColumn: FK format with table.column" {
    const r = parseSqliteTableColumn("FOREIGN KEY constraint failed: posts.user_id");
    try std.testing.expectEqualStrings("posts", r.table.?);
    try std.testing.expectEqualStrings("user_id", r.column.?);
}

test "parseSqliteTableColumn: no colon returns nulls" {
    const r = parseSqliteTableColumn("something else");
    try std.testing.expect(r.table == null);
    try std.testing.expect(r.column == null);
}

test "parseSqliteTableColumn: FK with no target" {
    const r = parseSqliteTableColumn("FOREIGN KEY constraint failed");
    try std.testing.expect(r.table == null);
    try std.testing.expect(r.column == null);
}
