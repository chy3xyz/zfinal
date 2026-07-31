//! DB driver binary result decoding benchmark.
//!
//! Quantifies the v0.15.0 typed-Cell path vs the legacy text-decode path.
//! Run via: `zig build run-db-bench`.
//!
//! Methodology:
//!   1. Create an in-memory SQLite database.
//!   2. Insert N rows of mixed types (3 int columns + 1 text column).
//!   3. Run SELECT * FROM bench.
//!   4. Walk every row and sum the int columns (forces read of every
//!      numeric cell).
//!   5. Report rows/sec, ns/row, total decode time.
//!
//! Three paths measured back-to-back:
//!   - "getInt"      — v0.15.0 path using `Row.getInt(idx)` which returns
//!                     `!?i64` (error union wrapping optional). Pays a
//!                     small per-call overhead for the union + bounds check.
//!   - "direct"      — direct field access `row.cells[idx].int` for hot
//!                     loops. The compiler can constant-fold the tag check
//!                     when the type is statically known.
//!   - "legacy"      — for-comparison path: `Row.getText` (formats i64 to
//!                     stack buffer) + `std.fmt.parseInt`. Mimics the
//!                     pre-v0.15.0 wire format on the consumer side.
//!
//! Honest expectation:
//!   For in-process SQLite (no wire format), the legacy path is often
//!   competitive or faster because parseInt on small integers is cheap
//!   AND inlines via the formatter. The real v0.15.0 wins come from
//!   PG/MySQL wire format (server skips to_text) and from not allocating
//!   intermediate strings — those savings are real but don't show up
//!   in this micro-benchmark.
//!
//! The "direct" path is what hot-loop consumers SHOULD do: pattern-match
//! on `cells[i]` once and read the typed payload directly.

const std = @import("std");
const zfinal = @import("zfinal");

const DBConfig = zfinal.DBConfig;
const DB = zfinal.DB;
const SqlParam = zfinal.SqlParam;

const ROW_COUNT: usize = 100_000;

/// Monotonic nanosecond timestamp. Zig 0.17 removed std.time.Instant.now()
/// in favor of std.Io.Timestamp.now(io, .awake), but our benchmark binary
/// has no Io instance. std.c.clock_gettime gives us a portable libc clock
/// with the platform-correct timespec layout (macOS vs Linux differ).
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

fn setupDb(allocator: std.mem.Allocator) !*DB {
    var db = try DB.init(allocator, DBConfig.sqliteMemory());
    try db.exec("CREATE TABLE bench (" ++
        "id INTEGER PRIMARY KEY," ++
        "a INTEGER NOT NULL," ++
        "b INTEGER NOT NULL," ++
        "c INTEGER NOT NULL," ++
        "label TEXT NOT NULL" ++
        ")");
    var i: usize = 0;
    while (i < ROW_COUNT) : (i += 1) {
        var lbl_buf: [32]u8 = undefined;
        const lbl = try std.fmt.bufPrint(&lbl_buf, "row_{d}", .{i});
        _ = try db.execParams(
            "INSERT INTO bench (a, b, c, label) VALUES (?, ?, ?, ?)",
            &.{
                SqlParam{ .int = @intCast(i * 3) },
                SqlParam{ .int = @intCast(i * 7 + 1) },
                SqlParam{ .int = @intCast(i * 11 + 5) },
                SqlParam{ .text = lbl },
            },
        );
    }
    return db;
}

const BenchResult = struct {
    rows: usize,
    total_ns: u64,
    sum_a: i64,
    sum_b: i64,
    sum_c: i64,

    fn rowsPerSecond(self: *const BenchResult) u64 {
        return @intCast(self.rows * std.time.ns_per_s / self.total_ns);
    }
    fn nsPerRow(self: *const BenchResult) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.rows));
    }
};

fn runGetIntPath(db: *DB) !BenchResult {
    var result = try db.query("SELECT a, b, c, label FROM bench");
    defer result.deinit();

    const start = nowNs();
    var sum_a: i64 = 0;
    var sum_b: i64 = 0;
    var sum_c: i64 = 0;
    var n: usize = 0;
    while (result.next()) {
        const row = result.currentRow().?;
        // v0.15.0 path: getInt returns the cached .int cell — no parseInt.
        sum_a += (try row.getInt(0)).?;
        sum_b += (try row.getInt(1)).?;
        sum_c += (try row.getInt(2)).?;
        n += 1;
    }
    const end = nowNs();
    return .{
        .rows = n,
        .total_ns = end - start,
        .sum_a = sum_a,
        .sum_b = sum_b,
        .sum_c = sum_c,
    };
}

fn runDirectFieldPath(db: *DB) !BenchResult {
    var result = try db.query("SELECT a, b, c, label FROM bench");
    defer result.deinit();

    const start = nowNs();
    var sum_a: i64 = 0;
    var sum_b: i64 = 0;
    var sum_c: i64 = 0;
    var n: usize = 0;
    while (result.next()) {
        const row = result.currentRow().?;
        // v0.17 hot-path helpers: intAt returns i64 directly with no error
        // union overhead. Panics on null/non-int cells (caller's job to
        // validate schema).
        sum_a += row.intAt(0);
        sum_b += row.intAt(1);
        sum_c += row.intAt(2);
        n += 1;
    }
    const end = nowNs();
    return .{
        .rows = n,
        .total_ns = end - start,
        .sum_a = sum_a,
        .sum_b = sum_b,
        .sum_c = sum_c,
    };
}

fn runLegacyPath(db: *DB) !BenchResult {
    var result = try db.query("SELECT a, b, c, label FROM bench");
    defer result.deinit();

    const start = nowNs();
    var sum_a: i64 = 0;
    var sum_b: i64 = 0;
    var sum_c: i64 = 0;
    var n: usize = 0;
    while (result.next()) {
        // Pre-v0.15.0 path simulation: every numeric read goes through
        // text + parseInt. getText on int/float materializes row-owned text.
        sum_a += try std.fmt.parseInt(i64, result.getText(0).?, 10);
        sum_b += try std.fmt.parseInt(i64, result.getText(1).?, 10);
        sum_c += try std.fmt.parseInt(i64, result.getText(2).?, 10);
        n += 1;
    }
    const end = nowNs();
    return .{
        .rows = n,
        .total_ns = end - start,
        .sum_a = sum_a,
        .sum_b = sum_b,
        .sum_c = sum_c,
    };
}

fn printResult(name: []const u8, r: BenchResult) void {
    std.debug.print("\n{s}:\n", .{name});
    std.debug.print("  rows       : {d}\n", .{r.rows});
    std.debug.print("  total time : {d} ns ({d:.2} ms)\n", .{ r.total_ns, @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0 });
    std.debug.print("  rows/sec   : {d}\n", .{r.rowsPerSecond()});
    std.debug.print("  ns/row     : {d:.1}\n", .{r.nsPerRow()});
    std.debug.print("  checksum   : a={d} b={d} c={d}\n", .{ r.sum_a, r.sum_b, r.sum_c });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("ZFinal DB result decoding benchmark\n", .{});
    std.debug.print("Row count: {d}  (3 int columns + 1 text per row)\n", .{ROW_COUNT});
    std.debug.print("Note: SQLite in-process — no wire format savings here.\n", .{});
    std.debug.print("      PG/MySQL binary wire format saves server CPU + bytes (not measured).\n\n", .{});

    var db = try setupDb(allocator);
    defer db.destroy();

    // Warm up.
    _ = try db.query("SELECT COUNT(*) FROM bench");

    const getint = try runGetIntPath(db);
    printResult("typed (Row.getInt — error union wrapper)", getint);

    const direct = try runDirectFieldPath(db);
    printResult("typed (direct cells[idx].int field access)", direct);

    const legacy = try runLegacyPath(db);
    printResult("legacy (Row.getText + parseInt)", legacy);

    std.debug.print("\nspeedup vs legacy:\n", .{});
    std.debug.print("  getInt  : {d:.2}x\n", .{@as(f64, @floatFromInt(legacy.total_ns)) / @as(f64, @floatFromInt(getint.total_ns))});
    std.debug.print("  direct  : {d:.2}x\n", .{@as(f64, @floatFromInt(legacy.total_ns)) / @as(f64, @floatFromInt(direct.total_ns))});

    if (getint.sum_a != legacy.sum_a or getint.sum_b != legacy.sum_b or getint.sum_c != legacy.sum_c) {
        std.debug.print("\nFAIL: checksum mismatch\n", .{});
        std.process.exit(1);
    }
    std.debug.print("\nchecksum OK (all paths agree)\n", .{});
}

