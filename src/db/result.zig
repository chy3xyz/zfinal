const std = @import("std");

/// A single SQL cell with typed payload.
///
/// Drivers populate `Cell` directly from binary query results when
/// available (PG `resultFormat=1`, MySQL `MYSQL_TYPE_LONGLONG`, etc.)
/// so consumers avoid the cost of `parseInt`/`parseFloat` on every read.
///
/// Storage ownership:
/// - `.text` and `.blob` slices are heap-allocated via `allocator.dupe`
///   and freed by `Row.deinit`.
/// - `.int`, `.float`, `.bool`, `.null` carry no heap payload.
/// - `Row.deinit` walks `.cells` and frees text/blob payloads only.
pub const Cell = union(enum) {
    null,
    text: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    blob: []const u8,
};

/// Row data — one record's worth of cells.
pub const Row = struct {
    cells: []Cell,
    allocator: std.mem.Allocator,
    /// Owned strings produced by `getText` for `.int` / `.float` cells.
    /// Freed in `deinit`. Keeps SUM/DECIMAL `getText` valid for the row
    /// lifetime (threadlocal scratch caused use-after-scope / UUUU symptoms).
    numeric_text: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Row) void {
        for (self.numeric_text.items) |t| self.allocator.free(t);
        self.numeric_text.deinit(self.allocator);
        for (self.cells) |cell| switch (cell) {
            .text => |t| self.allocator.free(t),
            .blob => |b| self.allocator.free(b),
            else => {},
        };
        self.allocator.free(self.cells);
    }

    /// Get cell value as a text view.
    ///
    /// - `.null` → returns `null`
    /// - `.text` / `.blob` → returns the row-owned slice (valid until `Row.deinit`)
    /// - `.int` / `.float` / `.bool` → formats into a **row-owned** buffer (also
    ///   valid until `deinit`). Prefer `getInt` / `getFloat` for typed reads;
    ///   do not `free` the returned slice yourself.
    pub fn getText(self: *Row, index: usize) ?[]const u8 {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .text => |t| t,
            .blob => |b| b,
            .bool => |b| if (b) "true" else "false",
            .int => |v| self.materializeNumericText(v),
            .float => |v| self.materializeNumericText(v),
        };
    }

    fn materializeNumericText(self: *Row, value: anytype) ?[]const u8 {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return null;
        const owned = self.allocator.dupe(u8, s) catch return null;
        self.numeric_text.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return null;
        };
        return owned;
    }

    /// Get cell value as i64.
    ///
    /// - `.null` → returns `null`
    /// - `.int` → returns the value directly (no parsing)
    /// - `.bool` → 0 or 1
    /// - `.text` / `.blob` → parseInt from text (legacy compat)
    /// - `.float` → only when the value is a finite **integral** float
    ///   (e.g. `30.0`); fractional values such as MySQL `SUM(varchar)` /
    ///   `DECIMAL` money (`30.80`) return `error.NotAnInteger` instead of
    ///   silently truncating. Use `getFloat` for amounts.
    pub fn getInt(self: *const Row, index: usize) !?i64 {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .int => |v| v,
            .bool => |b| if (b) 1 else 0,
            .float => |v| try floatToI64Exact(v),
            .text => |t| try std.fmt.parseInt(i64, t, 10),
            .blob => |t| try std.fmt.parseInt(i64, t, 10),
        };
    }

    /// Get cell value as f64.
    pub fn getFloat(self: *const Row, index: usize) !?f64 {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .bool => |b| if (b) 1.0 else 0.0,
            .text => |t| try std.fmt.parseFloat(f64, t),
            .blob => |t| try std.fmt.parseFloat(f64, t),
        };
    }

    /// Get cell value as bool. Booleans map to "t"/"f" (PG), "true"/"false"
    /// (MySQL), or 1/0 (SQLite).
    pub fn getBool(self: *const Row, index: usize) !?bool {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .bool => |b| b,
            .int => |v| v != 0,
            .float => |v| v != 0.0,
            .text => |t| try parseBoolText(t),
            .blob => null,
        };
    }

    /// Hot-loop helper: read a cell as i64 directly, without the error-union
    /// + optional wrapper of `getInt`. The caller is responsible for type
    /// safety — this panics on out-of-bounds, null, non-int, or **fractional
    /// float** cells (same rule as `getInt` — no silent money truncation).
    ///
    /// Use this in tight sum/filter/aggregate loops where you've already
    /// validated the schema and want the fastest possible per-row read.
    /// In our internal benchmark this beats the legacy `getText + parseInt`
    /// path because it skips the formatter + parser entirely.
    pub fn intAt(self: *const Row, index: usize) i64 {
        return switch (self.cells[index]) {
            .int => |v| v,
            .bool => |b| if (b) 1 else 0,
            .float => |v| floatToI64Exact(v) catch @panic("Row.intAt called on non-integral float"),
            .null => @panic("Row.intAt called on NULL cell"),
            .text, .blob => @panic("Row.intAt called on non-numeric cell"),
        };
    }

    /// Hot-loop helper: read a cell as f64 directly. Same caveats as
    /// `intAt` — panics on null or non-numeric cells.
    pub fn floatAt(self: *const Row, index: usize) f64 {
        return switch (self.cells[index]) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .bool => |b| if (b) 1.0 else 0.0,
            .null => @panic("Row.floatAt called on NULL cell"),
            .text, .blob => @panic("Row.floatAt called on non-numeric cell"),
        };
    }

    /// Hot-loop helper: read a cell as bool directly. Same caveats as
    /// `intAt` — panics on null cells.
    pub fn boolAt(self: *const Row, index: usize) bool {
        return switch (self.cells[index]) {
            .bool => |b| b,
            .int => |v| v != 0,
            .float => |v| v != 0.0,
            .null => @panic("Row.boolAt called on NULL cell"),
            .text, .blob => @panic("Row.boolAt called on non-bool cell"),
        };
    }
};

/// Parse "t"/"true"/"1"/"f"/"false"/"0" (case-sensitive variants for
/// SQL convention). Returns error.InvalidBooleanValue otherwise.
fn parseBoolText(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "t") or std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) {
        return true;
    } else if (std.mem.eql(u8, text, "f") or std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) {
        return false;
    }
    return error.InvalidBooleanValue;
}

/// Convert a finite **integral** float to i64.
///
/// Used by `getInt` / `queryScalar(i64)` so MySQL `SUM(varchar)` /
/// `NEWDECIMAL` money values like `30.80` are not silently truncated to `30`.
pub fn floatToI64Exact(v: f64) !i64 {
    if (!std.math.isFinite(v)) return error.NotAnInteger;
    if (v != @trunc(v)) return error.NotAnInteger;
    const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_f: f64 = @floatFromInt(std.math.minInt(i64));
    if (v > max_f or v < min_f) return error.Overflow;
    return @intFromFloat(v);
}

/// Unified result set interface.
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: [][]const u8,
    /// `columns[i]` is owned by the ResultSet (freed in deinit).
    /// `columns_slice` is a non-owning view used for iteration.
    rows: std.ArrayList(Row),
    current_index: usize = 0,
    /// Cached O(1) name→index map for RowMap lookups. Built once at
    /// init time so the wide-table hot path (ORM scanning 30+ columns
    /// by name on every row) doesn't pay the O(n²) linear scan.
    name_index: ?std.StringHashMap(usize) = null,

    pub fn init(allocator: std.mem.Allocator, columns: [][]const u8) ResultSet {
        var rs = ResultSet{
            .allocator = allocator,
            .columns = columns,
            .rows = std.ArrayList(Row).empty,
        };
        // Eagerly build the name→index map. For wide tables (30+
        // columns) this turns the RowMap hot path from O(n) per cell
        // into O(1). Cost: O(n) at init, paid once per query.
        rs.name_index = std.StringHashMap(usize).init(allocator);
        for (columns, 0..) |col, i| {
            rs.name_index.?.put(col, i) catch {
                // OOM building the index — leave it null and fall
                // back to linear scan in RowMap.get.
                rs.name_index.?.deinit();
                rs.name_index = null;
                break;
            };
        }
        return rs;
    }

    pub fn deinit(self: *ResultSet) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit(self.allocator);

        if (self.name_index) |*idx| idx.deinit();

        for (self.columns) |col| {
            self.allocator.free(col);
        }
        self.allocator.free(self.columns);
    }

    /// Add a row to the result set. Each cell becomes the owner of any
    /// text/blob payload it carries (Row.deinit will free them).
    pub fn addRow(self: *ResultSet, cells: []Cell) !void {
        const row = Row{
            .cells = cells,
            .allocator = self.allocator,
        };
        try self.rows.append(self.allocator, row);
    }

    /// Get column count
    pub fn columnCount(self: *const ResultSet) usize {
        return self.columns.len;
    }

    /// Get row count
    pub fn rowCount(self: *const ResultSet) usize {
        return self.rows.items.len;
    }

    /// Get column name by index
    pub fn columnName(self: *const ResultSet, index: usize) ?[]const u8 {
        if (index >= self.columns.len) return null;
        return self.columns[index];
    }

    /// Move to next row
    pub fn next(self: *ResultSet) bool {
        if (self.current_index < self.rows.items.len) {
            self.current_index += 1;
            return true;
        }
        return false;
    }

    /// Get current row (immutable view — typed getters only).
    pub fn currentRow(self: *const ResultSet) ?*const Row {
        if (self.current_index == 0 or self.current_index > self.rows.items.len) {
            return null;
        }
        return &self.rows.items[self.current_index - 1];
    }

    /// Mutable current row — required for `getText` numeric materialization.
    pub fn currentRowMut(self: *ResultSet) ?*Row {
        if (self.current_index == 0 or self.current_index > self.rows.items.len) {
            return null;
        }
        return &self.rows.items[self.current_index - 1];
    }

    /// Reset iterator
    pub fn reset(self: *ResultSet) void {
        self.current_index = 0;
    }

    /// Get row by index
    pub fn getRow(self: *const ResultSet, index: usize) ?*const Row {
        if (index >= self.rows.items.len) return null;
        return &self.rows.items[index];
    }

    /// Convenience methods for current row
    pub fn getText(self: *ResultSet, index: usize) ?[]const u8 {
        const row = self.currentRowMut() orelse return null;
        return row.getText(index);
    }

    pub fn getInt(self: *const ResultSet, index: usize) !?i64 {
        const row = self.currentRow() orelse return null;
        return try row.getInt(index);
    }

    pub fn getFloat(self: *const ResultSet, index: usize) !?f64 {
        const row = self.currentRow() orelse return null;
        return try row.getFloat(index);
    }

    pub fn getBool(self: *const ResultSet, index: usize) !?bool {
        const row = self.currentRow() orelse return null;
        return try row.getBool(index);
    }

    /// Row wrapper with column name access.
    /// `get` / `getInt` use the ResultSet's pre-built name_index for
    /// O(1) lookup. If the index wasn't built (e.g. OOM during init),
    /// falls back to a single linear scan over `columns`.
    pub const RowMap = struct {
        row: *Row,
        result_set: *const ResultSet,

        pub fn get(self: *const RowMap, col_name: []const u8) ?[]const u8 {
            const idx = self.lookupIndex(col_name) orelse return null;
            return self.row.getText(idx);
        }

        pub fn getInt(self: *const RowMap, col_name: []const u8) !?i64 {
            const idx = self.lookupIndex(col_name) orelse return null;
            return try self.row.getInt(idx);
        }

        fn lookupIndex(self: *const RowMap, col_name: []const u8) ?usize {
            if (self.result_set.name_index) |*idx| {
                return idx.get(col_name);
            }
            // Fallback: linear scan if index wasn't built.
            for (self.result_set.columns, 0..) |name, i| {
                if (std.mem.eql(u8, name, col_name)) return i;
            }
            return null;
        }
    };

    /// Get current row as RowMap for easy column access by name
    pub fn getCurrentRowMap(self: *ResultSet) ?RowMap {
        const row = self.currentRowMut() orelse return null;
        return RowMap{
            .row = row,
            .result_set = self,
        };
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

test "getText on float is row-stable until deinit (SUM/money)" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "total");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    // MySQL SUM / NEWDECIMAL → .float; CAST AS CHAR stays .text (owned dupe).
    cells[0] = .{ .float = 21667.0 };
    try result.addRow(cells);

    _ = result.next();
    const first = result.getText(0).?;
    const second = result.getText(0).?;
    // Each call materializes a new owned buffer; both stay valid until deinit.
    try std.testing.expectEqualStrings("21667", first);
    try std.testing.expectEqualStrings("21667", second);
    try std.testing.expect(first.ptr != second.ptr);
}

test "Cell: getInt rejects fractional float (SUM/money)" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "sum_money");
    columns[1] = try allocator.dupe(u8, "sum_whole");
    columns[2] = try allocator.dupe(u8, "neg_frac");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 3);
    // MySQL SUM(varchar amount) / NEWDECIMAL typically lands as .float
    cells[0] = .{ .float = 30.80 };
    cells[1] = .{ .float = 30.0 };
    cells[2] = .{ .float = -1.5 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectError(error.NotAnInteger, row.getInt(0));
    try std.testing.expectEqual(@as(i64, 30), (try row.getInt(1)).?);
    try std.testing.expectError(error.NotAnInteger, row.getInt(2));
    try std.testing.expectApproxEqAbs(@as(f64, 30.80), (try row.getFloat(0)).?, 1e-9);
}

test "Cell: getInt on decimal text fails; getFloat works" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "sum_as_varchar");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    cells[0] = .{ .text = try allocator.dupe(u8, "1234.56") };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectError(error.InvalidCharacter, row.getInt(0));
    try std.testing.expectApproxEqAbs(@as(f64, 1234.56), (try row.getFloat(0)).?, 1e-9);
}

test "floatToI64Exact rejects fractional money" {
    try std.testing.expectEqual(@as(i64, 30), try floatToI64Exact(30.0));
    try std.testing.expectEqual(@as(i64, -7), try floatToI64Exact(-7.0));
    try std.testing.expectError(error.NotAnInteger, floatToI64Exact(30.80));
    try std.testing.expectError(error.NotAnInteger, floatToI64Exact(std.math.nan(f64)));
    try std.testing.expectError(error.NotAnInteger, floatToI64Exact(std.math.inf(f64)));
}

test "Cell: getInt returns int directly without parseInt" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "n");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    // Pre-typed int cell — no allocation for text payload
    var cells = try allocator.alloc(Cell, 1);
    cells[0] = .{ .int = 42 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectEqual(@as(i64, 42), (try row.getInt(0)).?);
}

test "Cell: getInt on text cell uses parseInt (legacy)" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "n");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    const txt = try allocator.dupe(u8, "123");
    cells[0] = .{ .text = txt };
    try result.addRow(cells);

    _ = result.next();
    try std.testing.expectEqual(@as(i64, 123), (try result.currentRow().?.getInt(0)).?);
}

test "Cell: getText on int cell formats to decimal" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "n");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    cells[0] = .{ .int = 99 };
    try result.addRow(cells);

    _ = result.next();
    try std.testing.expectEqualStrings("99", result.getText(0).?);
}

test "RowMap: cached name lookup preserves formatted numeric text" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "id");
    columns[1] = try allocator.dupe(u8, "score");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 2);
    cells[0] = .{ .int = 123456789 };
    cells[1] = .{ .float = 42.5 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.getCurrentRowMap().?;
    try std.testing.expectEqualStrings("123456789", row.get("id").?);
    try std.testing.expectEqualStrings("42.5", row.get("score").?);
}

test "Cell: getBool maps common forms" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "a");
    columns[1] = try allocator.dupe(u8, "b");
    columns[2] = try allocator.dupe(u8, "c");
    columns[3] = try allocator.dupe(u8, "d");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 4);
    cells[0] = .{ .bool = true };
    cells[1] = .{ .int = 0 };
    const t = try allocator.dupe(u8, "true");
    cells[2] = .{ .text = t };
    const f = try allocator.dupe(u8, "false");
    cells[3] = .{ .text = f };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectEqual(true, (try row.getBool(0)).?);
    try std.testing.expectEqual(false, (try row.getBool(1)).?);
    try std.testing.expectEqual(true, (try row.getBool(2)).?);
    try std.testing.expectEqual(false, (try row.getBool(3)).?);
}

test "Cell: getFloat" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "f");
    columns[1] = try allocator.dupe(u8, "i");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 2);
    cells[0] = .{ .float = 3.14 };
    cells[1] = .{ .int = 7 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), (try row.getFloat(0)).?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), (try row.getFloat(1)).?, 1e-9);
}

test "Cell: null cell returns null on every getter" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "x");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    cells[0] = .null;
    try result.addRow(cells);

    _ = result.next();
    try std.testing.expect(result.getText(0) == null);
    try std.testing.expect((try result.getInt(0)) == null);
    try std.testing.expect((try result.getBool(0)) == null);
}

test "Cell: blob payload freed by Row.deinit (no leak)" {
    // Use std.testing.allocator which would fail on leak.
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "b");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 1);
    const b = try allocator.dupe(u8, "raw bytes");
    cells[0] = .{ .blob = b };
    try result.addRow(cells);

    _ = result.next();
    try std.testing.expectEqualStrings("raw bytes", result.getText(0).?);
}

test "Cell: intAt returns i64 directly without error-union overhead" {
    const allocator = std.testing.allocator;
    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "n");
    columns[1] = try allocator.dupe(u8, "b");
    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 2);
    cells[0] = .{ .int = 99 };
    cells[1] = .{ .bool = true };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectEqual(@as(i64, 99), row.intAt(0));
    try std.testing.expectEqual(@as(i64, 1), row.intAt(1)); // bool→int
}

test "Cell: floatAt returns f64 directly" {
    const allocator = std.testing.allocator;
    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "f");
    columns[1] = try allocator.dupe(u8, "i");
    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 2);
    cells[0] = .{ .float = 2.5 };
    cells[1] = .{ .int = 4 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), row.floatAt(0), 1e-9);
    try std.testing.expectEqual(@as(f64, 4.0), row.floatAt(1));
}

test "Cell: boolAt returns bool directly" {
    const allocator = std.testing.allocator;
    var columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "a");
    columns[1] = try allocator.dupe(u8, "b");
    columns[2] = try allocator.dupe(u8, "c");
    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    var cells = try allocator.alloc(Cell, 3);
    cells[0] = .{ .bool = true };
    cells[1] = .{ .int = 0 };
    cells[2] = .{ .int = 1 };
    try result.addRow(cells);

    _ = result.next();
    const row = result.currentRow().?;
    try std.testing.expectEqual(true, row.boolAt(0));
    try std.testing.expectEqual(false, row.boolAt(1));
    try std.testing.expectEqual(true, row.boolAt(2));
}
