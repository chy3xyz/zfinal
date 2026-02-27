const std = @import("std");

/// 上传的文件
pub const UploadFile = struct {
    field_name: []const u8,
    filename: []const u8,
    content_type: []const u8,
    size: usize,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *UploadFile) void {
        self.allocator.free(self.field_name);
        self.allocator.free(self.filename);
        self.allocator.free(self.content_type);
        self.allocator.free(self.data);
    }

    /// 保存文件到指定路径
    pub fn saveTo(self: *UploadFile, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.data);
    }

    /// 保存文件到目录，使用原始文件名
    pub fn saveToDir(self: *UploadFile, dir: []const u8) !void {
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, self.filename });
        try self.saveTo(path);
    }
};

/// Multipart 表单解析器
pub const MultipartParser = struct {
    allocator: std.mem.Allocator,
    boundary: []const u8,

    pub fn init(allocator: std.mem.Allocator, content_type: []const u8) !MultipartParser {
        // 从 Content-Type 中提取 boundary
        // 例如: "multipart/form-data; boundary=----WebKitFormBoundary..."
        const boundary_prefix = "boundary=";
        const boundary_start = std.mem.indexOf(u8, content_type, boundary_prefix) orelse return error.NoBoundary;
        const boundary = content_type[boundary_start + boundary_prefix.len ..];

        return MultipartParser{
            .allocator = allocator,
            .boundary = boundary,
        };
    }

    /// 解析 multipart 数据
    pub fn parse(self: *MultipartParser, body: []const u8) !std.ArrayList(UploadFile) {
        var files = std.ArrayList(UploadFile).init(self.allocator);
        errdefer {
            for (files.items) |*file| {
                file.deinit();
            }
            files.deinit();
        }

        // 构建完整的 boundary 标记
        var boundary_buf: [512]u8 = undefined;
        const full_boundary = try std.fmt.bufPrint(&boundary_buf, "--{s}", .{self.boundary});
        _ = try std.fmt.bufPrint(&boundary_buf, "--{s}--", .{self.boundary}); // end_boundary for reference

        var pos: usize = 0;

        while (pos < body.len) {
            // 查找下一个 boundary
            const boundary_pos = std.mem.indexOf(u8, body[pos..], full_boundary) orelse break;
            pos += boundary_pos + full_boundary.len;

            // 检查是否是结束 boundary
            if (std.mem.startsWith(u8, body[pos..], "--")) break;

            // 跳过 CRLF
            if (pos + 2 <= body.len and body[pos] == '\r' and body[pos + 1] == '\n') {
                pos += 2;
            }

            // 解析 headers
            const headers_end = std.mem.indexOf(u8, body[pos..], "\r\n\r\n") orelse continue;
            const headers = body[pos .. pos + headers_end];
            pos += headers_end + 4; // 跳过 \r\n\r\n

            // 查找内容结束位置（下一个 boundary 之前）
            const next_boundary_pos = std.mem.indexOf(u8, body[pos..], full_boundary) orelse body.len - pos;
            var content_end = pos + next_boundary_pos;

            // 去除尾部的 \r\n
            if (content_end >= 2 and body[content_end - 2] == '\r' and body[content_end - 1] == '\n') {
                content_end -= 2;
            }

            const content = body[pos..content_end];

            // 解析 headers 获取文件信息
            if (try self.parseFilePart(headers, content)) |file| {
                try files.append(file);
            }

            pos = content_end;
        }

        return files;
    }

    fn parseFilePart(self: *MultipartParser, headers: []const u8, content: []const u8) !?UploadFile {
        var field_name: ?[]const u8 = null;
        var filename: ?[]const u8 = null;
        var content_type: []const u8 = "application/octet-stream";

        // 解析 Content-Disposition header
        var lines = std.mem.splitScalar(u8, headers, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (std.mem.startsWith(u8, trimmed, "Content-Disposition:")) {
                // 提取 name 和 filename
                if (std.mem.indexOf(u8, trimmed, "name=\"")) |name_start| {
                    const name_begin = name_start + 6;
                    const name_end = std.mem.indexOfScalarPos(u8, trimmed, name_begin, '"') orelse continue;
                    field_name = trimmed[name_begin..name_end];
                }

                if (std.mem.indexOf(u8, trimmed, "filename=\"")) |filename_start| {
                    const filename_begin = filename_start + 10;
                    const filename_end = std.mem.indexOfScalarPos(u8, trimmed, filename_begin, '"') orelse continue;
                    filename = trimmed[filename_begin..filename_end];
                }
            } else if (std.mem.startsWith(u8, trimmed, "Content-Type:")) {
                const type_start = std.mem.indexOf(u8, trimmed, ":") orelse continue;
                content_type = std.mem.trim(u8, trimmed[type_start + 1 ..], &std.ascii.whitespace);
            }
        }

        // 只处理有 filename 的部分（文件上传）
        if (filename == null) return null;

        return UploadFile{
            .field_name = try self.allocator.dupe(u8, field_name orelse "file"),
            .filename = try self.allocator.dupe(u8, filename.?),
            .content_type = try self.allocator.dupe(u8, content_type),
            .size = content.len,
            .data = try self.allocator.dupe(u8, content),
            .allocator = self.allocator,
        };
    }
};

test "multipart parsing" {
    const allocator = std.testing.allocator;

    const content_type = "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxkTrZu0gW";
    const body =
        "------WebKitFormBoundary7MA4YWxkTrZu0gW\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Hello, World!\r\n" ++
        "------WebKitFormBoundary7MA4YWxkTrZu0gW--";

    var parser = try MultipartParser.init(allocator, content_type);
    var files = try parser.parse(body);
    defer {
        for (files.items) |*file| {
            file.deinit();
        }
        files.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), files.items.len);
    try std.testing.expectEqualStrings("test.txt", files.items[0].filename);
    try std.testing.expectEqualStrings("Hello, World!", files.items[0].data);
}
