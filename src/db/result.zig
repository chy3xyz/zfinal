const std = @import("std");

/// Row data
pub const Row = struct {
    cells: []?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Row) void {
        for (self.cells) |cell| {
            if (cell) |c| self.allocator.free(c);
        }
        self.allocator.free(self.cells);
    }

    /// Get cell value as text
    pub fn getText(self: *const Row, index: usize) ?[]const u8 {
        if (index >= self.cells.len) return null;
        return self.cells[index];
    }

    /// Get cell value as integer
    pub fn getInt(self: *const Row, index: usize) !?i64 {
        const text = self.getText(index) orelse return null;
        return try std.fmt.parseInt(i64, text, 10);
    }

    /// Get cell value as boolean
    pub fn getBool(self: *const Row, index: usize) !?bool {
        const text = self.getText(index) orelse return null;

        if (std.mem.eql(u8, text, "t") or
            std.mem.eql(u8, text, "true") or
            std.mem.eql(u8, text, "1"))
        {
            return true;
        } else if (std.mem.eql(u8, text, "f") or
            std.mem.eql(u8, text, "false") or
            std.mem.eql(u8, text, "0"))
        {
            return false;
        }

        return error.InvalidBooleanValue;
    }
};

/// Unified result set interface
pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: [][]const u8,
    rows: std.ArrayList(Row),
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, columns: [][]const u8) ResultSet {
        return ResultSet{
            .allocator = allocator,
            .columns = columns,
            .rows = std.ArrayList(Row).init(allocator),
        };
    }

    pub fn deinit(self: *ResultSet) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();

        for (self.columns) |col| {
            self.allocator.free(col);
        }
        self.allocator.free(self.columns);
    }

    /// Add a row to the result set
    pub fn addRow(self: *ResultSet, cells: []?[]const u8) !void {
        const row = Row{
            .cells = cells,
            .allocator = self.allocator,
        };
        try self.rows.append(row);
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

    pub fn getBool(self: *const ResultSet, index: usize) !?bool {
        const row = self.currentRow() orelse return null;
        return try row.getBool(index);
    }

    /// Row wrapper with column name access
    pub const RowMap = struct {
        row: *const Row,
        result_set: *const ResultSet,

        pub fn get(self: *const RowMap, col_name: []const u8) ?[]const u8 {
            // Find column index
            for (self.result_set.columns, 0..) |name, i| {
                if (std.mem.eql(u8, name, col_name)) {
                    return self.row.getText(i);
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

test "result set iteration" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "id");
    columns[1] = try allocator.dupe(u8, "name");

    var result = ResultSet.init(allocator, columns);
    defer result.deinit();

    // Add rows
    var row1 = try allocator.alloc(?[]const u8, 2);
    row1[0] = try allocator.dupe(u8, "1");
    row1[1] = try allocator.dupe(u8, "Alice");
    try result.addRow(row1);

    var row2 = try allocator.alloc(?[]const u8, 2);
    row2[0] = try allocator.dupe(u8, "2");
    row2[1] = try allocator.dupe(u8, "Bob");
    try result.addRow(row2);

    // Test iteration
    try std.testing.expectEqual(@as(usize, 2), result.rowCount());

    var count: usize = 0;
    while (result.next()) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
