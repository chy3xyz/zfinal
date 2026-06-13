const std = @import("std");

/// CSV 工具类（RFC 4180 compliant）
pub const CsvKit = struct {
    /// 是否需要对字段进行转义（包含逗号/引号/换行时需要）
    pub fn needsEscape(field: []const u8) bool {
        for (field) |c| {
            if (c == ',' or c == '"' or c == '\n' or c == '\r') return true;
        }
        return false;
    }

    /// 转义单个 CSV 字段（RFC 4180）
    /// - 如果字段包含逗号、引号或换行，用双引号包裹
    /// - 字段内的双引号替换为两个双引号
    pub fn escapeField(allocator: std.mem.Allocator, field: []const u8) ![]u8 {
        if (!needsEscape(field)) {
            return try allocator.dupe(u8, field);
        }
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        try result.append(allocator, '"');
        var i: usize = 0;
        while (i < field.len) : (i += 1) {
            if (field[i] == '"') {
                try result.append(allocator, '"');
                try result.append(allocator, '"');
            } else {
                try result.append(allocator, field[i]);
            }
        }
        try result.append(allocator, '"');
        return try result.toOwnedSlice(allocator);
    }

    /// 将转义后的字段追加到 ArrayList（末尾自动加逗号）
    pub fn appendEscapedField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), field: []const u8) !void {
        const escaped = try escapeField(allocator, field);
        defer allocator.free(escaped);
        try out.appendSlice(allocator, escaped);
        try out.append(allocator, ',');
    }

    /// 追加一整行（field_names 末尾无逗号，换行符由调用方添加）
    pub fn appendRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), fields: []const []const u8) !void {
        for (fields, 0..) |field, idx| {
            const escaped = try escapeField(allocator, field);
            defer allocator.free(escaped);
            try out.appendSlice(allocator, escaped);
            if (idx < fields.len - 1) try out.append(allocator, ',');
        }
    }

    /// 追加带字段值的一行（field_names 提供列名，field_values 提供对应值）
    pub fn appendRowWithValues(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        field_names: []const []const u8,
        field_values: []const ?[]const u8,
    ) !void {
        for (field_names) |name| {
            const escaped_name = try escapeField(allocator, name);
            defer allocator.free(escaped_name);
            try out.appendSlice(allocator, escaped_name);
            try out.append(allocator, ',');
        }
        for (field_values, 0..) |value, idx| {
            const escaped_value = try escapeField(allocator, value orelse "");
            defer allocator.free(escaped_value);
            try out.appendSlice(allocator, escaped_value);
            if (idx < field_values.len - 1) try out.append(allocator, ',');
        }
    }

    /// 将 NULL 值转换为空字符串
    pub fn nullToEmpty(v: ?[]const u8) []const u8 {
        return v orelse "";
    }

    /// 追加 CSV 换行符（LF，仅 Linux/macOS；Windows 应在外层处理 CRLF）
    pub fn appendNewline(out: *std.ArrayList(u8)) !void {
        try out.append(out.items.len, '\n');
    }

    /// 将 CSV 内容写入文件（chunked write, 4KB chunks）
    pub fn writeFile(path: []const u8, content: []const u8) !void {
        const io_instance = @import("../io_instance.zig");
        const file = try std.Io.Dir.cwd().createFile(io_instance.io, path, .{ .truncate = true });
        defer file.close(io_instance.io);
        var buf: [4096]u8 = undefined;
        var wr = file.writer(io_instance.io, &buf);
        var pos: usize = 0;
        while (pos < content.len) {
            const chunk = content[pos..@min(pos + 4096, content.len)];
            try wr.interface.writeAll(chunk);
            pos += chunk.len;
        }
    }

    /// 读取 CSV 文件内容
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const io_instance = @import("../io_instance.zig");
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);
        const stat = try file.stat(io_instance.io);
        const buf = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        const bytes_read = try std.Io.File.readPositionalAll(file, io_instance.io, buf, 0);
        return buf[0..bytes_read];
    }

    /// 解析一行 CSV 内容（RFC 4180）
    /// 注意事项：
    /// - 字段内双引号 "" 解析为单个 "
    /// - 前后空格会被 trim
    pub fn parseLine(line: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        var fields = std.ArrayList([]const u8).empty;
        errdefer {
            for (fields.items) |f| allocator.free(f);
            fields.deinit(allocator);
        }

        var in_quote = false;
        var field_start: usize = 0;
        var i: usize = 0;

        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '"') {
                if (in_quote and i + 1 < line.len and line[i + 1] == '"') {
                    i += 1;
                } else {
                    in_quote = !in_quote;
                }
            } else if (c == ',' and !in_quote) {
                try fields.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, line[field_start..i], " \t")));
                field_start = i + 1;
            }
        }
        try fields.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, line[field_start..], " \t")));

        for (fields.items, 0..) |f, j| {
            if (f.len >= 2 and f[0] == '"' and f[f.len - 1] == '"') {
                const inner = f[1 .. f.len - 1];
                var buf = std.ArrayList(u8).empty;
                errdefer buf.deinit(allocator);
                var k: usize = 0;
                while (k < inner.len) : (k += 1) {
                    if (inner[k] == '"' and k + 1 < inner.len and inner[k + 1] == '"') {
                        try buf.append(allocator, '"');
                        k += 1;
                    } else {
                        try buf.append(allocator, inner[k]);
                    }
                }
                const new_f = try buf.toOwnedSlice(allocator);
                allocator.free(f);
                fields.items[j] = new_f;
            }
        }

        const result = try allocator.dupe([]const u8, fields.items);
        fields.deinit(allocator);
        return result;
    }

    /// 解析 CSV 内容，返回所有行（排除空行，自动检测 BOM 和 header）
    /// - header_idx: 返回 header 行所在的行号（从 1 开始），-1 表示未找到
    /// - caller 负责释放返回的每一行字符串
    pub fn parseContent(
        content: []const u8,
        allocator: std.mem.Allocator,
    ) !struct {
        lines: [][]const u8,
        header_idx: i64,
    } {
        var lines_out = std.ArrayList([]const u8).empty;
        errdefer {
            for (lines_out.items) |l| allocator.free(l);
            lines_out.deinit(allocator);
        }

        var clean_content = content;
        if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            clean_content = content[3..];
        }

        var line_it = std.mem.splitScalar(u8, clean_content, '\n');
        var line_idx: i64 = 0;
        var header_idx: i64 = -1;

        while (line_it.next()) |raw_line| {
            var line = raw_line;
            while (line.len > 0 and (line[0] == '\r' or line[0] == '\n')) line = line[1..];
            if (line.len == 0) continue;
            line_idx += 1;
            const l = try allocator.dupe(u8, line);
            errdefer allocator.free(l);
            try lines_out.append(l);
            if (header_idx < 0 and std.mem.indexOf(u8, l, "公司名称") != null) {
                header_idx = line_idx;
            }
        }

        return .{
            .lines = try lines_out.toOwnedSlice(allocator),
            .header_idx = header_idx,
        };
    }
};

test "CsvKit needsEscape" {
    try std.testing.expect(!CsvKit.needsEscape("hello"));
    try std.testing.expect(!CsvKit.needsEscape(""));
    try std.testing.expect(CsvKit.needsEscape("hello,world"));
    try std.testing.expect(CsvKit.needsEscape("hello\"world"));
    try std.testing.expect(CsvKit.needsEscape("hello\nworld"));
}

test "CsvKit escapeField" {
    const allocator = std.testing.allocator;
    const a = try CsvKit.escapeField(allocator, "hello");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("hello", a);

    const b = try CsvKit.escapeField(allocator, "hello,world");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("\"hello,world\"", b);

    const c = try CsvKit.escapeField(allocator, "say \"hello\"");
    defer allocator.free(c);
    try std.testing.expectEqualStrings("\"say \"\"hello\"\"\"", c);
}

test "CsvKit parseLine" {
    const allocator = std.testing.allocator;
    const fields = try CsvKit.parseLine("a,b,c", allocator);
    defer {
        for (fields) |f| allocator.free(f);
        allocator.free(fields);
    }
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("b", fields[1]);
    try std.testing.expectEqualStrings("c", fields[2]);

    const quoted = try CsvKit.parseLine("\"a,b\",\"c\"", allocator);
    defer {
        for (quoted) |f| allocator.free(f);
        allocator.free(quoted);
    }
    try std.testing.expectEqual(@as(usize, 2), quoted.len);
    try std.testing.expectEqualStrings("a,b", quoted[0]);
    try std.testing.expectEqualStrings("c", quoted[1]);

    const escaped = try CsvKit.parseLine("\"say \"\"hi\"\"\",world", allocator);
    defer {
        for (escaped) |f| allocator.free(f);
        allocator.free(escaped);
    }
    try std.testing.expectEqual(@as(usize, 2), escaped.len);
    try std.testing.expectEqualStrings("say \"hi\"", escaped[0]);
}
