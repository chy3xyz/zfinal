const std = @import("std");

/// Plural rule types
pub const PluralRule = enum {
    /// English-like: 1 = singular, everything else = plural
    one_other,
    /// Chinese/Japanese/Korean-like: no plural forms
    none,
    /// Russian-like: complex plural forms
    russian,
    /// Arabic-like: very complex plural forms
    arabic,
};

/// Locale information
pub const LocaleInfo = struct {
    code: []const u8,
    name: []const u8,
    native_name: []const u8,
    plural_rule: PluralRule,
    rtl: bool = false,
};

/// Supported locales
pub const SUPPORTED_LOCALES = [_]LocaleInfo{
    .{ .code = "en", .name = "English", .native_name = "English", .plural_rule = .one_other },
    .{ .code = "zh", .name = "Chinese", .native_name = "中文", .plural_rule = .none },
    .{ .code = "ja", .name = "Japanese", .native_name = "日本語", .plural_rule = .none },
    .{ .code = "ko", .name = "Korean", .native_name = "한국어", .plural_rule = .none },
    .{ .code = "es", .name = "Spanish", .native_name = "Español", .plural_rule = .one_other },
    .{ .code = "fr", .name = "French", .native_name = "Français", .plural_rule = .one_other },
    .{ .code = "de", .name = "German", .native_name = "Deutsch", .plural_rule = .one_other },
    .{ .code = "ru", .name = "Russian", .native_name = "Русский", .plural_rule = .russian },
    .{ .code = "ar", .name = "Arabic", .native_name = "العربية", .plural_rule = .arabic, .rtl = true },
    .{ .code = "pt", .name = "Portuguese", .native_name = "Português", .plural_rule = .one_other },
    .{ .code = "it", .name = "Italian", .native_name = "Italiano", .plural_rule = .one_other },
    .{ .code = "hi", .name = "Hindi", .native_name = "हिन्दी", .plural_rule = .one_other },
};

/// Get locale info by code
pub fn getLocaleInfo(code: []const u8) ?LocaleInfo {
    for (SUPPORTED_LOCALES) |locale| {
        if (std.mem.eql(u8, locale.code, code)) {
            return locale;
        }
    }
    return null;
}

/// Detect locale from Accept-Language header
pub fn detectLocale(accept_language: []const u8) []const u8 {
    // Simple parsing: take the first language code
    var it = std.mem.splitScalar(u8, accept_language, ',');
    if (it.next()) |first| {
        const trimmed = std.mem.trim(u8, first, " ");
        // Extract just the language code (e.g., "en-US" -> "en")
        if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash_pos| {
            const code = trimmed[0..dash_pos];
            if (getLocaleInfo(code) != null) return code;
        } else if (std.mem.indexOfScalar(u8, trimmed, ';')) |semi_pos| {
            const code = trimmed[0..semi_pos];
            if (getLocaleInfo(code) != null) return code;
        } else {
            if (getLocaleInfo(trimmed) != null) return trimmed;
        }
    }
    return "en"; // Default to English
}

/// Determine plural form index based on locale and count
pub fn getPluralIndex(locale: []const u8, count: i64) usize {
    const info = getLocaleInfo(locale) orelse return 0;

    switch (info.plural_rule) {
        .none => return 0,
        .one_other => {
            if (count == 1) return 0;
            return 1;
        },
        .russian => {
            const mod10 = @mod(count, 10);
            const mod100 = @mod(count, 100);
            if (mod10 == 1 and mod100 != 11) return 0; // singular
            if (mod10 >= 2 and mod10 <= 4 and (mod100 < 10 or mod100 >= 20)) return 1; // few
            return 2; // many
        },
        .arabic => {
            if (count == 0) return 0; // zero
            if (count == 1) return 1; // singular
            if (count == 2) return 2; // dual
            const mod100 = @mod(count, 100);
            if (mod100 >= 3 and mod100 <= 10) return 3; // few
            if (mod100 >= 11 and mod100 <= 99) return 4; // many
            return 5; // other
        },
    }
}

/// Enhanced internationalization with pluralization and interpolation
pub const I18n = struct {
    locales: std.StringHashMap(std.StringHashMap([]const u8)),
    plural_locales: std.StringHashMap(std.StringHashMap([]const []const u8)),
    default_locale: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, default_locale: []const u8) I18n {
        return I18n{
            .locales = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .plural_locales = std.StringHashMap(std.StringHashMap([]const []const u8)).init(allocator),
            .default_locale = default_locale,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *I18n) void {
        // Clean up regular messages
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

        // Clean up plural messages
        var plural_locale_it = self.plural_locales.iterator();
        while (plural_locale_it.next()) |locale_entry| {
            self.allocator.free(locale_entry.key_ptr.*);

            var msg_it = locale_entry.value_ptr.iterator();
            while (msg_it.next()) |msg_entry| {
                self.allocator.free(msg_entry.key_ptr.*);
                for (msg_entry.value_ptr.*) |s| {
                    self.allocator.free(s);
                }
                self.allocator.free(msg_entry.value_ptr.*);
            }
            locale_entry.value_ptr.deinit();
        }
        self.plural_locales.deinit();
    }

    /// Load locale from JSON file
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

        var plural_messages = std.StringHashMap([]const []const u8).init(self.allocator);
        errdefer plural_messages.deinit();

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);

            switch (entry.value_ptr.*) {
                .string => |s| {
                    const value = try self.allocator.dupe(u8, s);
                    try messages.put(key, value);
                },
                .array => |arr| {
                    // Plural forms
                    var forms = try self.allocator.alloc([]const u8, arr.items.len);
                    for (arr.items, 0..) |item, i| {
                        if (item == .string) {
                            forms[i] = try self.allocator.dupe(u8, item.string);
                        } else {
                            forms[i] = try self.allocator.dupe(u8, "");
                        }
                    }
                    try plural_messages.put(key, forms);
                },
                else => {
                    const value = try self.allocator.dupe(u8, "");
                    try messages.put(key, value);
                },
            }
        }

        const locale_copy = try self.allocator.dupe(u8, locale);

        if (messages.count() > 0) {
            try self.locales.put(locale_copy, messages);
        } else {
            messages.deinit();
        }

        if (plural_messages.count() > 0) {
            try self.plural_locales.put(try self.allocator.dupe(u8, locale), plural_messages);
        } else {
            plural_messages.deinit();
        }
    }

    /// Get translation (simple)
    pub fn get(self: *const I18n, locale: []const u8, key: []const u8) []const u8 {
        // Try specified locale
        if (self.locales.get(locale)) |messages| {
            if (messages.get(key)) |value| {
                return value;
            }
        }

        // Fallback to default locale
        if (!std.mem.eql(u8, locale, self.default_locale)) {
            if (self.locales.get(self.default_locale)) |messages| {
                if (messages.get(key)) |value| {
                    return value;
                }
            }
        }

        return key;
    }

    /// Get pluralized translation
    pub fn getPlural(self: *const I18n, locale: []const u8, key: []const u8, count: i64) []const u8 {
        const plural_index = getPluralIndex(locale, count);

        // Try specified locale
        if (self.plural_locales.get(locale)) |messages| {
            if (messages.get(key)) |forms| {
                if (plural_index < forms.len) {
                    return forms[plural_index];
                }
                return forms[forms.len - 1];
            }
        }

        // Fallback to default locale
        if (!std.mem.eql(u8, locale, self.default_locale)) {
            if (self.plural_locales.get(self.default_locale)) |messages| {
                if (messages.get(key)) |forms| {
                    if (plural_index < forms.len) {
                        return forms[plural_index];
                    }
                    return forms[forms.len - 1];
                }
            }
        }

        return key;
    }

    /// Translate with interpolation
    /// Supports: {{variable}} replacement from context
    pub fn translate(self: *const I18n, locale: []const u8, key: []const u8, context: anytype) ![]const u8 {
        const template = self.get(locale, key);

        // Simple interpolation
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < template.len) {
            const start = std.mem.indexOfPos(u8, template, pos, "{{") orelse {
                try result.appendSlice(self.allocator, template[pos..]);
                break;
            };

            try result.appendSlice(self.allocator, template[pos..start]);

            const end = std.mem.indexOfPos(u8, template, start, "}}") orelse {
                try result.appendSlice(self.allocator, template[pos..]);
                break;
            };

            const var_name = std.mem.trim(u8, template[start + 2 .. end], &std.ascii.whitespace);

            // Try to find variable in context
            const value = try getContextValue(self.allocator, context, var_name);
            defer if (value) |v| self.allocator.free(v);

            if (value) |v| {
                try result.appendSlice(self.allocator, v);
            }

            pos = end + 2;
        }

        return result.toOwnedSlice();
    }

    /// Translate with pluralization and interpolation
    pub fn translatePlural(self: *const I18n, locale: []const u8, key: []const u8, count: i64, context: anytype) ![]const u8 {
        const template = self.getPlural(locale, key, count);

        // Merge count into context
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < template.len) {
            const start = std.mem.indexOfPos(u8, template, pos, "{{") orelse {
                try result.appendSlice(self.allocator, template[pos..]);
                break;
            };

            try result.appendSlice(self.allocator, template[pos..start]);

            const end = std.mem.indexOfPos(u8, template, start, "}}") orelse {
                try result.appendSlice(self.allocator, template[pos..]);
                break;
            };

            const var_name = std.mem.trim(u8, template[start + 2 .. end], &std.ascii.whitespace);

            if (std.mem.eql(u8, var_name, "count")) {
                const count_str = try std.fmt.allocPrint(self.allocator, "{d}", .{count});
                defer self.allocator.free(count_str);
                try result.appendSlice(self.allocator, count_str);
            } else {
                const value = try getContextValue(self.allocator, context, var_name);
                defer if (value) |v| self.allocator.free(v);
                if (value) |v| {
                    try result.appendSlice(self.allocator, v);
                }
            }

            pos = end + 2;
        }

        return result.toOwnedSlice();
    }

    /// Add a translation
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

    /// Add a plural translation
    pub fn addPlural(self: *I18n, locale: []const u8, key: []const u8, forms: []const []const u8) !void {
        const locale_entry = try self.plural_locales.getOrPut(locale);
        if (!locale_entry.found_existing) {
            locale_entry.key_ptr.* = try self.allocator.dupe(u8, locale);
            locale_entry.value_ptr.* = std.StringHashMap([]const []const u8).init(self.allocator);
        }

        const messages = locale_entry.value_ptr;
        const key_copy = try self.allocator.dupe(u8, key);

        var forms_copy = try self.allocator.alloc([]const u8, forms.len);
        for (forms, 0..) |form, i| {
            forms_copy[i] = try self.allocator.dupe(u8, form);
        }

        if (messages.fetchPut(key_copy, forms_copy)) |kv| {
            if (kv) |old_kv| {
                self.allocator.free(old_kv.key);
                for (old_kv.value) |s| self.allocator.free(s);
                self.allocator.free(old_kv.value);
            }
        } else |err| {
            self.allocator.free(key_copy);
            for (forms_copy) |s| self.allocator.free(s);
            self.allocator.free(forms_copy);
            return err;
        }
    }

    /// Get context value for interpolation
    fn getContextValue(allocator: std.mem.Allocator, context: anytype, field_name: []const u8) !?[]const u8 {
        const T = @TypeOf(context);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            return null;
        }

        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                const value = @field(context, field.name);
                return try formatValue(allocator, value);
            }
        }

        return null;
    }

    fn formatValue(allocator: std.mem.Allocator, value: anytype) !?[]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int, .comptime_int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .float, .comptime_float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
            .bool => if (value) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false"),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try allocator.dupe(u8, value);
                }
                return null;
            },
            .optional => |opt| {
                if (value) |v| {
                    return try formatValue(allocator, v);
                } else {
                    return try allocator.dupe(u8, "");
                }
            },
            else => null,
        };
    }
};

/// Context helper: translate function
pub fn t(i18n: *const I18n, locale: []const u8, key: []const u8) []const u8 {
    return i18n.get(locale, key);
}

/// Context helper: translate with interpolation
pub fn t_fmt(i18n: *const I18n, locale: []const u8, key: []const u8, context: anytype) ![]const u8 {
    return try i18n.translate(locale, key, context);
}

/// Context helper: pluralize
pub fn t_plural(i18n: *const I18n, locale: []const u8, key: []const u8, count: i64) []const u8 {
    return i18n.getPlural(locale, key, count);
}

// ============================================================================
// Tests
// ============================================================================

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

    // Undefined locale should fallback to default
    try std.testing.expectEqualStrings("Hello", i18n.get("fr", "hello"));

    // Undefined key should return key itself
    try std.testing.expectEqualStrings("unknown", i18n.get("en", "unknown"));
}

test "i18n interpolation" {
    const allocator = std.testing.allocator;

    var i18n = I18n.init(allocator, "en");
    defer i18n.deinit();

    try i18n.add("en", "greeting", "Hello, {{name}}!");

    const result = try i18n.translate("en", "greeting", .{ .name = "Alice" });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, Alice!", result);
}

test "locale detection" {
    try std.testing.expectEqualStrings("en", detectLocale("en-US,zh;q=0.9"));
    try std.testing.expectEqualStrings("zh", detectLocale("zh-CN,en;q=0.9"));
    try std.testing.expectEqualStrings("en", detectLocale("fr-FR,en;q=0.8"));
}

test "plural rules" {
    // English: 1 = singular (0), other = plural (1)
    try std.testing.expectEqual(@as(usize, 0), getPluralIndex("en", 1));
    try std.testing.expectEqual(@as(usize, 1), getPluralIndex("en", 0));
    try std.testing.expectEqual(@as(usize, 1), getPluralIndex("en", 2));
    try std.testing.expectEqual(@as(usize, 1), getPluralIndex("en", 100));

    // Chinese: always same form
    try std.testing.expectEqual(@as(usize, 0), getPluralIndex("zh", 1));
    try std.testing.expectEqual(@as(usize, 0), getPluralIndex("zh", 100));
}

test "i18n plural" {
    const allocator = std.testing.allocator;

    var i18n = I18n.init(allocator, "en");
    defer i18n.deinit();

    try i18n.addPlural("en", "items", &.{ "one item", "{{count}} items" });

    try std.testing.expectEqualStrings("one item", i18n.getPlural("en", "items", 1));
    try std.testing.expectEqualStrings("5 items", i18n.getPlural("en", "items", 5));
}
