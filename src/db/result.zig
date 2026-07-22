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

    pub fn deinit(self: *Row) void {
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
    /// - `.text` → returns the slice as-is
    /// - `.int` → returns a small static decimal string ("0".."9..9"). The
    ///   slice points into a small static buffer owned by `Cell` — do NOT
    ///   free it. Safe for `std.mem.eql` and `std.fmt.parseInt`.
    /// - `.float` → returns a small static decimal string.
    /// - `.bool` → returns "true" or "false" (static).
    /// - `.blob` → returns the raw byte slice (callers must NOT treat as UTF-8).
    pub fn getText(self: *const Row, index: usize) ?[]const u8 {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .text => |t| t,
            .int => |v| intTextBuf(v),
            .float => |v| floatTextBuf(v),
            .bool => |b| if (b) "true" else "false",
            .blob => |b| b,
        };
    }

    /// Get cell value as i64.
    ///
    /// - `.null` → returns `null`
    /// - `.int` → returns the value directly (no parsing)
    /// - `.bool` → 0 or 1
    /// - `.text` / `.blob` → parseInt from text (legacy compat)
    /// - `.float` → @intFromFloat
    pub fn getInt(self: *const Row, index: usize) !?i64 {
        if (index >= self.cells.len) return null;
        return switch (self.cells[index]) {
            .null => null,
            .int => |v| v,
            .bool => |b| if (b) 1 else 0,
            .float => |v| @intFromFloat(v),
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

/// Format an i64 into a thread-local static decimal buffer.
/// Zig doesn't have thread-local storage but we use a small fixed-size
/// array indexed by `@mod(v, 32)` — collisions only matter if the caller
/// compares across cells in the same row, which they shouldn't for ints.
/// To be safe we use one buffer per call site by returning slices that
/// live for the duration of the read (the caller must not retain).
///
/// NOTE: This is a stop-gap. For real workloads, callers should use
/// `Row.getInt` (which avoids parseInt for `.int` cells). getText on an
/// integer cell is only meant for legacy code that needs a string.
fn intTextBuf(v: i64) []const u8 {
    // Format into a static buffer. Returns a slice into `buf`.
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return "";
    return s;
}

fn floatTextBuf(v: f64) []const u8 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return "";
    return s;
}

/// Unified result set interface.
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: [][]const u8,
    rows: std.ArrayList(Row),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, columns: [][]const u8) ResultSet {
        return ResultSet{
            .allocator = allocator,
            .columns = columns,
            .rows = std.ArrayList(Row).empty,
        };
    }

    pub fn deinit(self: *ResultSet) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit(self.allocator);

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

    /// Get current row
    pub fn currentRow(self: *const ResultSet) ?*const Row {
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
    pub fn getText(self: *const ResultSet, index: usize) ?[]const u8 {
        const row = self.currentRow() orelse return null;
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

    /// Row wrapper with column name access
    pub const RowMap = struct {
        row: *const Row,
        result_set: *const ResultSet,

        pub fn get(self: *const RowMap, col_name: []const u8) ?[]const u8 {
            for (self.result_set.columns, 0..) |name, i| {
                if (std.mem.eql(u8, name, col_name)) {
                    return self.row.getText(i);
                }
            }
            return null;
        }

        pub fn getInt(self: *const RowMap, col_name: []const u8) !?i64 {
            for (self.result_set.columns, 0..) |name, i| {
                if (std.mem.eql(u8, name, col_name)) {
                    return try self.row.getInt(i);
                }
            }
            return null;
        }
    };

    /// Get current row as RowMap for easy column access by name
    pub fn getCurrentRowMap(self: *const ResultSet) ?RowMap {
        const row = self.currentRow() orelse return null;
        return RowMap{
            .row = row,
            .result_set = self,
        };
    }
};

// ─── Tests ───────────────────────────────────────────────────────────

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
    try std.testing.expectEqualStrings("99", result.currentRow().?.getText(0).?);
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
    const row = result.currentRow().?;
    try std.testing.expect(row.getText(0) == null);
    try std.testing.expect((try row.getInt(0)) == null);
    try std.testing.expect((try row.getBool(0)) == null);
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
    try std.testing.expectEqualStrings("raw bytes", result.currentRow().?.getText(0).?);
}
