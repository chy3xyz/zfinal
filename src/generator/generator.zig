const std = @import("std");
const DB = @import("../db/db.zig").DB;

/// 表信息
pub const TableInfo = struct {
    name: []const u8,
    columns: []ColumnInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TableInfo) void {
        self.allocator.free(self.name);
        for (self.columns) |*col| {
            col.deinit();
        }
        self.allocator.free(self.columns);
    }
};

/// 列信息
pub const ColumnInfo = struct {
    name: []const u8,
    type_name: []const u8,
    is_nullable: bool,
    is_primary_key: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ColumnInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.type_name);
    }

    /// 映射数据库类型到 Zig 类型
    pub fn toZigType(self: *const ColumnInfo) []const u8 {
        const lower_type = std.ascii.lowerString(self.allocator, self.type_name) catch return "[]const u8";
        defer self.allocator.free(lower_type);

        // SQLite 类型
        if (std.mem.indexOf(u8, lower_type, "int") != null) return "i64";
        if (std.mem.indexOf(u8, lower_type, "real") != null or
            std.mem.indexOf(u8, lower_type, "float") != null or
            std.mem.indexOf(u8, lower_type, "double") != null) return "f64";
        if (std.mem.indexOf(u8, lower_type, "bool") != null) return "bool";

        // 默认为字符串
        return "[]const u8";
    }
};

/// Model 代码生成器
pub const Generator = struct {
    db: *DB,
    allocator: std.mem.Allocator,
    output_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, db: *DB, output_dir: []const u8) Generator {
        return Generator{
            .db = db,
            .allocator = allocator,
            .output_dir = output_dir,
        };
    }

    /// 获取所有表信息
    pub fn getTables(self: *Generator) ![]TableInfo {
        var tables = std.ArrayList(TableInfo).init(self.allocator);
        errdefer tables.deinit();

        // SQLite: 查询所有表
        const sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'";
        var sql_buf: [512]u8 = undefined;
        const sql_z = try std.fmt.bufPrintZ(&sql_buf, "{s}", .{sql});

        var result = try self.db.query(sql_z);
        defer result.deinit();

        while (result.next()) {
            const table_name = result.getText(0) orelse continue;
            const columns = try self.getTableColumns(table_name);

            const table = TableInfo{
                .name = try self.allocator.dupe(u8, table_name),
                .columns = columns,
                .allocator = self.allocator,
            };

            try tables.append(table);
        }

        return tables.toOwnedSlice();
    }

    /// 获取表的列信息
    pub fn getTableColumns(self: *Generator, table_name: []const u8) ![]ColumnInfo {
        var columns = std.ArrayList(ColumnInfo).init(self.allocator);
        errdefer columns.deinit();

        // SQLite: PRAGMA table_info
        var sql_buf: [512]u8 = undefined;
        const sql = try std.fmt.bufPrintZ(&sql_buf, "PRAGMA table_info({s})", .{table_name});

        var result = try self.db.query(sql);
        defer result.deinit();

        // PRAGMA table_info 返回: cid, name, type, notnull, dflt_value, pk
        while (result.next()) {
            const col_name = result.getText(1) orelse continue;
            const col_type = result.getText(2) orelse "TEXT";
            const not_null = (try result.getInt(3)) orelse 0;
            const is_pk = (try result.getInt(5)) orelse 0;

            const column = ColumnInfo{
                .name = try self.allocator.dupe(u8, col_name),
                .type_name = try self.allocator.dupe(u8, col_type),
                .is_nullable = not_null == 0,
                .is_primary_key = is_pk > 0,
                .allocator = self.allocator,
            };

            try columns.append(column);
        }

        return columns.toOwnedSlice();
    }

    /// 生成 Model 代码
    pub fn generateModel(self: *Generator, table: *const TableInfo) ![]const u8 {
        var code = std.ArrayList(u8).init(self.allocator);
        defer code.deinit();

        const writer = code.writer();

        // 生成文件头
        try writer.writeAll("const std = @import(\"std\");\n");
        try writer.writeAll("const zfinal = @import(\"zfinal\");\n\n");

        // 生成结构体名（首字母大写）
        const struct_name = try self.toPascalCase(table.name);
        defer self.allocator.free(struct_name);

        // 生成结构体
        try writer.print("/// {s} Model\n", .{struct_name});
        try writer.print("pub const {s} = struct {{\n", .{struct_name});

        // 生成字段
        for (table.columns) |col| {
            if (col.is_primary_key and std.mem.eql(u8, col.name, "id")) {
                // 主键 ID 由 Model 管理
                continue;
            }

            const field_name = try self.toCamelCase(col.name);
            defer self.allocator.free(field_name);

            const zig_type = col.toZigType();

            if (col.is_nullable) {
                try writer.print("    {s}: ?{s} = null,\n", .{ field_name, zig_type });
            } else {
                try writer.print("    {s}: {s},\n", .{ field_name, zig_type });
            }
        }

        try writer.writeAll("};\n\n");

        // 生成 Model 类型
        try writer.print("pub const {s}Model = zfinal.Model({s}, \"{s}\");\n", .{ struct_name, struct_name, table.name });

        return code.toOwnedSlice();
    }

    /// 生成所有表的 Model
    pub fn generateAll(self: *Generator) !void {
        const tables = try self.getTables();
        defer {
            for (tables) |*table| {
                table.deinit();
            }
            self.allocator.free(tables);
        }

        // 创建输出目录
        std.fs.cwd().makePath(self.output_dir) catch {};

        for (tables) |*table| {
            const code = try self.generateModel(table);
            defer self.allocator.free(code);

            // 生成文件名
            var filename_buf: [256]u8 = undefined;
            const filename = try std.fmt.bufPrint(&filename_buf, "{s}/{s}.zig", .{ self.output_dir, table.name });

            // 写入文件
            const file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();
            try file.writeAll(code);

            std.debug.print("Generated: {s}\n", .{filename});
        }
    }

    /// 转换为 PascalCase
    fn toPascalCase(self: *Generator, name: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var capitalize_next = true;
        for (name) |c| {
            if (c == '_') {
                capitalize_next = true;
                continue;
            }

            if (capitalize_next) {
                try result.append(std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(c);
            }
        }

        return result.toOwnedSlice();
    }

    /// 转换为 camelCase
    fn toCamelCase(self: *Generator, name: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var capitalize_next = false;
        var first = true;

        for (name) |c| {
            if (c == '_') {
                capitalize_next = true;
                continue;
            }

            if (first) {
                try result.append(std.ascii.toLower(c));
                first = false;
            } else if (capitalize_next) {
                try result.append(std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(c);
            }
        }

        return result.toOwnedSlice();
    }
};

test "case conversion" {
    const allocator = std.testing.allocator;

    var gen = Generator{
        .db = undefined,
        .allocator = allocator,
        .output_dir = "models",
    };

    const pascal = try gen.toPascalCase("user_profile");
    defer allocator.free(pascal);
    try std.testing.expectEqualStrings("UserProfile", pascal);

    const camel = try gen.toCamelCase("user_name");
    defer allocator.free(camel);
    try std.testing.expectEqualStrings("userName", camel);
}
