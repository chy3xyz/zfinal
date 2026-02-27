const std = @import("std");

/// 国际化资源
pub const I18n = struct {
    locales: std.StringHashMap(std.StringHashMap([]const u8)),
    default_locale: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, default_locale: []const u8) I18n {
        return I18n{
            .locales = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .default_locale = default_locale,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *I18n) void {
        var locale_it = self.locales.iterator();
        while (locale_it.next()) |locale_entry| {
            self.allocator.free(locale_entry.key_ptr.*);

            var msg_it = locale_entry.value_ptr.iterator();
            while (msg_it.next()) |msg_entry| {
                self.allocator.free(msg_entry.key_ptr.*);
                self.allocator.free(msg_entry.value_ptr.*);
            }
            locale_entry.value_ptr.deinit();
        }
        self.locales.deinit();
    }

    /// 从目录加载所有语言文件
    pub fn loadFromDir(allocator: std.mem.Allocator, dir_path: []const u8, default_locale: []const u8) !I18n {
        var i18n = I18n.init(allocator, default_locale);
        errdefer i18n.deinit();

        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            // 从文件名提取 locale (例如: en.json -> en)
            const locale = entry.name[0 .. entry.name.len - 5];

            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name });

            try i18n.loadLocale(locale, full_path);
        }

        return i18n;
    }

    /// 加载单个语言文件
    pub fn loadLocale(self: *I18n, locale: []const u8, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidJson;

        var messages = std.StringHashMap([]const u8).init(self.allocator);
        errdefer messages.deinit();

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            const value = if (entry.value_ptr.* == .string)
                try self.allocator.dupe(u8, entry.value_ptr.string)
            else
                try self.allocator.dupe(u8, "");

            try messages.put(key, value);
        }

        const locale_copy = try self.allocator.dupe(u8, locale);
        try self.locales.put(locale_copy, messages);
    }

    /// 获取翻译文本
    pub fn get(self: *const I18n, locale: []const u8, key: []const u8) []const u8 {
        // 尝试获取指定语言的翻译
        if (self.locales.get(locale)) |messages| {
            if (messages.get(key)) |value| {
                return value;
            }
        }

        // 回退到默认语言
        if (!std.mem.eql(u8, locale, self.default_locale)) {
            if (self.locales.get(self.default_locale)) |messages| {
                if (messages.get(key)) |value| {
                    return value;
                }
            }
        }

        // 返回 key 本身
        return key;
    }

    /// 添加翻译
    pub fn add(self: *I18n, locale: []const u8, key: []const u8, value: []const u8) !void {
        const locale_entry = try self.locales.getOrPut(locale);
        if (!locale_entry.found_existing) {
            locale_entry.key_ptr.* = try self.allocator.dupe(u8, locale);
            locale_entry.value_ptr.* = std.StringHashMap([]const u8).init(self.allocator);
        }

        const messages = locale_entry.value_ptr;
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        if (messages.fetchPut(key_copy, value_copy)) |kv| {
            if (kv) |old_kv| {
                self.allocator.free(old_kv.key);
                self.allocator.free(old_kv.value);
            }
        } else |err| {
            self.allocator.free(key_copy);
            self.allocator.free(value_copy);
            return err;
        }
    }
};

/// Context 扩展：国际化支持
pub fn t(i18n: *const I18n, locale: []const u8, key: []const u8) []const u8 {
    return i18n.get(locale, key);
}

test "i18n basic" {
    const allocator = std.testing.allocator;

    var i18n = I18n.init(allocator, "en");
    defer i18n.deinit();

    try i18n.add("en", "hello", "Hello");
    try i18n.add("zh", "hello", "你好");

    try std.testing.expectEqualStrings("Hello", i18n.get("en", "hello"));
    try std.testing.expectEqualStrings("你好", i18n.get("zh", "hello"));
}

test "i18n fallback" {
    const allocator = std.testing.allocator;

    var i18n = I18n.init(allocator, "en");
    defer i18n.deinit();

    try i18n.add("en", "hello", "Hello");

    // 未定义的语言应该回退到默认语言
    try std.testing.expectEqualStrings("Hello", i18n.get("fr", "hello"));

    // 未定义的 key 应该返回 key 本身
    try std.testing.expectEqualStrings("unknown", i18n.get("en", "unknown"));
}
