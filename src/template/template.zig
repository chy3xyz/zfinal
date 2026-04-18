const std = @import("std");
const io_instance = @import("io_instance.zig");

/// Enhanced template engine with support for:
/// - Variable interpolation: {{variable}}
/// - Conditionals: {% if condition %}, {% else %}, {% endif %}
/// - Loops: {% for item in items %}, {% endfor %}
/// - Includes: {% include "partial.html" %}
/// - Layouts: {% extends "layout.html" %}, {% block content %}, {% endblock %}
/// - Comments: {# comment #}
/// - Filters: {{variable|upper}}, {{variable|lower}}, {{variable|capitalize}}
pub const Template = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) Template {
        return .{
            .allocator = allocator,
            .content = content,
        };
    }

    /// Load template from file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Template {
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        const content = try file.readToEndAlloc(io_instance.io, allocator, 10 * 1024 * 1024);
        return Template{
            .allocator = allocator,
            .content = content,
        };
    }

    /// Render template with data
    pub fn render(self: *Template, data: anytype) ![]const u8 {
        var engine = RenderEngine.init(self.allocator, self.content);
        return try engine.render(data);
    }

    pub fn deinit(self: *Template) void {
        self.allocator.free(self.content);
    }
};

/// Template Manager with caching and directory support
pub const TemplateManager = struct {
    templates: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    template_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, template_dir: []const u8) !TemplateManager {
        return TemplateManager{
            .templates = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .template_dir = try allocator.dupe(u8, template_dir),
        };
    }

    pub fn deinit(self: *TemplateManager) void {
        var it = self.templates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.templates.deinit();
        self.allocator.free(self.template_dir);
    }

    /// Load template from file
    pub fn load(self: *TemplateManager, name: []const u8) !void {
        const path = try std.fs.path.join(self.allocator, &.{ self.template_dir, name });
        defer self.allocator.free(path);

        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        const content = try file.readToEndAlloc(io_instance.io, self.allocator, 10 * 1024 * 1024);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.templates.put(name_copy, content);
    }

    /// Render template with data
    pub fn render(self: *TemplateManager, name: []const u8, data: anytype) ![]const u8 {
        const content = self.templates.get(name) orelse {
            try self.load(name);
            return self.render(name, data);
        };

        var engine = RenderEngine.init(self.allocator, content);
        engine.template_dir = self.template_dir;
        return try engine.render(data);
    }

    /// Render with layout support
    pub fn renderWithLayout(self: *TemplateManager, name: []const u8, layout: []const u8, data: anytype) ![]const u8 {
        const content = self.templates.get(name) orelse {
            try self.load(name);
            return self.renderWithLayout(name, layout, data);
        };

        var engine = RenderEngine.init(self.allocator, content);
        engine.template_dir = self.template_dir;
        engine.layout = layout;
        return try engine.render(data);
    }
};

/// Token types for template parsing
const TokenType = enum {
    text,
    variable,
    tag_if,
    tag_else,
    tag_endif,
    tag_for,
    tag_endfor,
    tag_include,
    tag_extends,
    tag_block,
    tag_endblock,
    comment,
    eof,
};

const Token = struct {
    type: TokenType,
    value: []const u8,
    line: usize,
    column: usize,
};

/// Template rendering engine
const RenderEngine = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    template_dir: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    blocks: std.StringHashMap([]const u8),
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Self {
        return .{
            .allocator = allocator,
            .source = source,
            .blocks = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.blocks.deinit();
    }

    /// Main render function
    pub fn render(self: *Self, data: anytype) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        // Check for extends tag at the beginning
        const extends_name = try self.checkExtends();
        if (extends_name) |layout_name| {
            // Parse blocks from current template
            try self.parseBlocks(data);

            // Render the layout with blocks
            const layout_content = try self.loadTemplateFile(layout_name);
            defer self.allocator.free(layout_content);

            var layout_engine = RenderEngine.init(self.allocator, layout_content);
            layout_engine.template_dir = self.template_dir;
            layout_engine.blocks = self.blocks;
            // Move blocks ownership
            const render_result = try layout_engine.renderInternal(data);
            // Don't deinit layout_engine.blocks since we transferred ownership
            return render_result;
        }

        return try self.renderInternal(data);
    }

    fn renderInternal(self: *Self, data: anytype) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        while (self.pos < self.source.len) {
            // Check for template tags
            if (self.match("{{")) {
                try self.renderVariable(&result, data);
            } else if (self.match("{%")) {
                try self.renderTag(&result, data);
            } else if (self.match("{#")) {
                try self.skipComment();
            } else {
                // Regular text
                try result.append(self.allocator, self.source[self.pos]);
                self.advance();
            }
        }

        return result.toOwnedSlice();
    }

    /// Check if template starts with extends tag
    fn checkExtends(self: *Self) !?[]const u8 {
        self.skipWhitespace();
        if (self.source.len - self.pos >= 4 and std.mem.startsWith(u8, self.source[self.pos..], "{%")) {
            const saved_pos = self.pos;
            self.pos += 2;
            self.skipWhitespace();

            if (self.matchWord("extends")) {
                self.skipWhitespace();
                const name = try self.parseString();
                self.skipWhitespace();
                if (self.match("%}")) {
                    return name;
                }
                self.allocator.free(name);
            }
            self.pos = saved_pos;
        }
        return null;
    }

    /// Parse blocks from template
    fn parseBlocks(self: *Self, _: anytype) !void {
        while (self.pos < self.source.len) {
            if (self.match("{%")) {
                self.skipWhitespace();
                if (self.matchWord("block")) {
                    self.skipWhitespace();
                    const block_name = try self.parseIdentifier();
                    self.skipWhitespace();
                    if (!self.match("%}")) return error.ExpectedBlockEnd;

                    // Capture block content
                    const start = self.pos;
                    var depth: usize = 1;
                    while (self.pos < self.source.len and depth > 0) {
                        if (self.source.len - self.pos >= 2 and std.mem.startsWith(u8, self.source[self.pos..], "{%")) {
                            self.pos += 2;
                            self.skipWhitespace();
                            if (self.matchWord("block")) {
                                depth += 1;
                            } else if (self.matchWord("endblock")) {
                                depth -= 1;
                                if (depth == 0) {
                                    self.skipWhitespace();
                                    if (!self.match("%}")) return error.ExpectedEndBlock;
                                    break;
                                }
                            }
                        } else {
                            self.pos += 1;
                        }
                    }

                    const content = try self.allocator.dupe(u8, self.source[start..self.pos]);
                    const name_copy = try self.allocator.dupe(u8, block_name);
                    try self.blocks.put(name_copy, content);
                    self.allocator.free(block_name);
                } else {
                    self.skipTag();
                }
            } else {
                self.pos += 1;
            }
        }
    }

    /// Render variable tag {{ variable }}
    fn renderVariable(self: *Self, result: *std.ArrayList(u8), data: anytype) !void {
        self.skipWhitespace();
        const var_expr = try self.parseExpression();
        defer self.allocator.free(var_expr);
        self.skipWhitespace();

        if (!self.match("}}")) return error.UnclosedVariable;

        // Check for filter
        const filter_pos = std.mem.indexOfScalar(u8, var_expr, '|');
        const var_name = if (filter_pos) |pos| var_expr[0..pos] else var_expr;
        const filter_name = if (filter_pos) |pos| std.mem.trim(u8, var_expr[pos + 1 ..], &std.ascii.whitespace) else null;

        const value = try self.getFieldValue(data, var_name);
        defer if (value) |v| self.allocator.free(v);

        if (value) |v| {
            const filtered = if (filter_name) |f| try self.applyFilter(v, f) else try self.allocator.dupe(u8, v);
            defer if (filter_name != null) self.allocator.free(filtered);
            try result.appendSlice(self.allocator, filtered);
        }
    }

    /// Render template tag
    fn renderTag(self: *Self, result: *std.ArrayList(u8), data: anytype) !void {
        self.skipWhitespace();

        if (self.matchWord("if")) {
            try self.renderIf(result, data);
        } else if (self.matchWord("for")) {
            try self.renderFor(result, data);
        } else if (self.matchWord("include")) {
            try self.renderInclude(result, data);
        } else if (self.matchWord("block")) {
            try self.renderBlock(result);
        } else {
            // Unknown tag, skip it
            self.skipTag();
        }
    }

    /// Render if statement
    fn renderIf(self: *Self, result: *std.ArrayList(u8), data: anytype) !void {
        self.skipWhitespace();
        const condition = try self.parseExpression();
        defer self.allocator.free(condition);
        self.skipWhitespace();

        if (!self.match("%}")) return error.ExpectedIfEnd;

        const condition_result = try self.evaluateCondition(data, condition);

        // Capture if body
        const if_start = self.pos;
        var depth: usize = 1;
        var has_else = false;
        var else_pos: usize = 0;

        while (self.pos < self.source.len and depth > 0) {
            if (self.source.len - self.pos >= 2 and std.mem.startsWith(u8, self.source[self.pos..], "{%")) {
                const tag_pos = self.pos;
                self.pos += 2;
                self.skipWhitespace();

                if (self.matchWord("if")) {
                    depth += 1;
                } else if (depth == 1 and self.matchWord("else")) {
                    if (!has_else) {
                        has_else = true;
                        else_pos = tag_pos;
                    }
                } else if (self.matchWord("endif")) {
                    depth -= 1;
                    if (depth == 0) {
                        self.skipWhitespace();
                        if (!self.match("%}")) return error.ExpectedEndIf;
                        break;
                    }
                }
            } else {
                self.pos += 1;
            }
        }

        if (depth > 0) return error.UnclosedIf;

        // Render appropriate branch
        const end_pos = self.pos;
        if (condition_result) {
            const branch_end = if (has_else) else_pos else end_pos;
            var branch_engine = RenderEngine.init(self.allocator, self.source[if_start..branch_end]);
            branch_engine.blocks = self.blocks;
            const branch_result = try branch_engine.renderInternal(data);
            try result.appendSlice(self.allocator, branch_result);
            self.allocator.free(branch_result);
        } else if (has_else) {
            const else_start = else_pos;
            // Skip past {% else %}
            var skip_pos = else_start;
            skip_pos += 2; // {%
            while (skip_pos < self.source.len and self.source[skip_pos] != '%') skip_pos += 1;
            skip_pos += 2; // %}

            var branch_engine = RenderEngine.init(self.allocator, self.source[skip_pos..end_pos]);
            branch_engine.blocks = self.blocks;
            const branch_result = try branch_engine.renderInternal(data);
            try result.appendSlice(self.allocator, branch_result);
            self.allocator.free(branch_result);
        }
    }

    /// Render for loop
    fn renderFor(self: *Self, result: *std.ArrayList(u8), data: anytype) !void {
        self.skipWhitespace();
        const var_name = try self.parseIdentifier();
        defer self.allocator.free(var_name);
        self.skipWhitespace();

        if (!self.matchWord("in")) return error.ExpectedIn;
        self.skipWhitespace();

        const collection_name = try self.parseExpression();
        defer self.allocator.free(collection_name);
        self.skipWhitespace();

        if (!self.match("%}")) return error.ExpectedForEnd;

        // Capture loop body
        const body_start = self.pos;
        var depth: usize = 1;

        while (self.pos < self.source.len and depth > 0) {
            if (self.source.len - self.pos >= 2 and std.mem.startsWith(u8, self.source[self.pos..], "{%")) {
                self.pos += 2;
                self.skipWhitespace();

                if (self.matchWord("for")) {
                    depth += 1;
                } else if (self.matchWord("endfor")) {
                    depth -= 1;
                    if (depth == 0) {
                        self.skipWhitespace();
                        if (!self.match("%}")) return error.ExpectedEndFor;
                        break;
                    }
                }
            } else {
                self.pos += 1;
            }
        }

        if (depth > 0) return error.UnclosedFor;
        const body_end = self.pos;

        // Try to iterate over collection
        try self.iterateCollection(data, collection_name, var_name, self.source[body_start..body_end], result);
    }

    /// Render include tag
    fn renderInclude(self: *Self, result: *std.ArrayList(u8), data: anytype) !void {
        self.skipWhitespace();
        const template_name = try self.parseString();
        defer self.allocator.free(template_name);
        self.skipWhitespace();

        if (!self.match("%}")) return error.ExpectedIncludeEnd;

        const include_content = try self.loadTemplateFile(template_name);
        defer self.allocator.free(include_content);

        var include_engine = RenderEngine.init(self.allocator, include_content);
        include_engine.template_dir = self.template_dir;
        include_engine.blocks = self.blocks;
        const include_result = try include_engine.renderInternal(data);
        try result.appendSlice(self.allocator, include_result);
        self.allocator.free(include_result);
    }

    /// Render block tag (for layouts)
    fn renderBlock(self: *Self, result: *std.ArrayList(u8)) !void {
        self.skipWhitespace();
        const block_name = try self.parseIdentifier();
        defer self.allocator.free(block_name);
        self.skipWhitespace();

        if (!self.match("%}")) return error.ExpectedBlockEnd;

        // Check if we have this block defined
        if (self.blocks.get(block_name)) |block_content| {
            var block_engine = RenderEngine.init(self.allocator, block_content);
            block_engine.blocks = self.blocks;
            const block_result = try block_engine.renderInternal(.{});
            try result.appendSlice(self.allocator, block_result);
            self.allocator.free(block_result);
        }

        // Skip the default block content
        var depth: usize = 1;
        while (self.pos < self.source.len and depth > 0) {
            if (self.source.len - self.pos >= 2 and std.mem.startsWith(u8, self.source[self.pos..], "{%")) {
                self.pos += 2;
                self.skipWhitespace();
                if (self.matchWord("block")) {
                    depth += 1;
                } else if (self.matchWord("endblock")) {
                    depth -= 1;
                    if (depth == 0) {
                        self.skipWhitespace();
                        if (!self.match("%}")) return error.ExpectedEndBlock;
                    }
                }
            } else {
                self.pos += 1;
            }
        }
    }

    /// Load template file
    fn loadTemplateFile(self: *Self, name: []const u8) ![]const u8 {
        if (self.template_dir) |dir| {
            const path = try std.fs.path.join(self.allocator, &.{ dir, name });
            defer self.allocator.free(path);

            const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
            defer file.close(io_instance.io);

            return try file.readToEndAlloc(io_instance.io, self.allocator, 10 * 1024 * 1024);
        }
        return error.NoTemplateDir;
    }

    /// Get field value from data
    fn getFieldValue(self: *Self, data: anytype, field_name: []const u8) !?[]const u8 {
        const T = @TypeOf(data);
        const type_info = @typeInfo(T);

        // Handle empty struct (no fields)
        if (type_info != .@"struct") {
            return null;
        }

        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                const value = @field(data, field.name);
                return try self.formatValue(value);
            }
        }

        return null;
    }

    /// Format value as string
    fn formatValue(self: *Self, value: anytype) !?[]const u8 {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .int, .comptime_int => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .float, .comptime_float => try std.fmt.allocPrint(self.allocator, "{d}", .{value}),
            .bool => if (value) try self.allocator.dupe(u8, "true") else try self.allocator.dupe(u8, "false"),
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    return try self.allocator.dupe(u8, value);
                }
                // Handle arrays/slices of structs
                return null;
            },
            .optional => |opt_value| {
                if (opt_value) |v| {
                    return try self.formatValue(v);
                } else {
                    return try self.allocator.dupe(u8, "");
                }
            },
            else => null,
        };
    }

    /// Evaluate condition
    fn evaluateCondition(self: *Self, data: anytype, condition: []const u8) !bool {
        // Simple condition evaluation
        // Support: variable, !variable, variable == value, variable != value

        const trimmed = std.mem.trim(u8, condition, &std.ascii.whitespace);

        // Check for negation
        if (trimmed.len > 1 and trimmed[0] == '!') {
            const var_name = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
            const value = try self.getFieldValue(data, var_name);
            defer if (value) |v| self.allocator.free(v);
            return value == null or (value != null and value.?.len == 0);
        }

        // Check for comparison operators
        const eq_pos = std.mem.indexOf(u8, trimmed, "==");
        const ne_pos = std.mem.indexOf(u8, trimmed, "!=");

        if (eq_pos) |pos| {
            const left = std.mem.trim(u8, trimmed[0..pos], &std.ascii.whitespace);
            const right = std.mem.trim(u8, trimmed[pos + 2 ..], &std.ascii.whitespace);
            const left_val = try self.getFieldValue(data, left);
            defer if (left_val) |v| self.allocator.free(v);
            return if (left_val) |lv| std.mem.eql(u8, lv, right) else false;
        }

        if (ne_pos) |pos| {
            const left = std.mem.trim(u8, trimmed[0..pos], &std.ascii.whitespace);
            const right = std.mem.trim(u8, trimmed[pos + 2 ..], &std.ascii.whitespace);
            const left_val = try self.getFieldValue(data, left);
            defer if (left_val) |v| self.allocator.free(v);
            return if (left_val) |lv| !std.mem.eql(u8, lv, right) else true;
        }

        // Simple truthiness check
        const value = try self.getFieldValue(data, trimmed);
        defer if (value) |v| self.allocator.free(v);
        return value != null and value.?.len > 0;
    }

    /// Iterate over collection
    fn iterateCollection(self: *Self, data: anytype, collection_name: []const u8, var_name: []const u8, body: []const u8, result: *std.ArrayList(u8)) !void {
        // Try to find the collection in data
        const T = @TypeOf(data);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") return;

        inline for (type_info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, collection_name)) {
                const collection = @field(data, field.name);
                const CollectionT = @TypeOf(collection);
                const collection_info = @typeInfo(CollectionT);

                // Handle slices and arrays
                if (collection_info == .pointer and collection_info.pointer.size == .slice) {
                    const ChildT = collection_info.pointer.child;
                    const child_info = @typeInfo(ChildT);

                    if (child_info == .@"struct") {
                        for (collection) |item| {
                            var item_engine = RenderEngine.init(self.allocator, body);
                            item_engine.blocks = self.blocks;
                            const item_result = try item_engine.renderInternal(item);
                            try result.appendSlice(self.allocator, item_result);
                            self.allocator.free(item_result);
                        }
                    } else {
                        // Simple array (strings, ints, etc.)
                        for (collection) |item| {
                            var item_engine = RenderEngine.init(self.allocator, body);
                            item_engine.blocks = self.blocks;

                            // Create a struct with the item as the loop variable
                            var loop_data = std.StringHashMap([]const u8).init(self.allocator);
                            defer {
                                var it = loop_data.iterator();
                                while (it.next()) |entry| {
                                    self.allocator.free(entry.key_ptr.*);
                                    self.allocator.free(entry.value_ptr.*);
                                }
                                loop_data.deinit();
                            }

                            const item_str = try self.formatValue(item);
                            defer if (item_str) |s| self.allocator.free(s);
                            if (item_str) |s| {
                                const key = try self.allocator.dupe(u8, var_name);
                                const val = try self.allocator.dupe(u8, s);
                                try loop_data.put(key, val);
                            }
                        }
                    }
                }
                return;
            }
        }
    }

    /// Apply filter to value
    fn applyFilter(self: *Self, value: []const u8, filter_name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, filter_name, "upper")) {
            const upper = try self.allocator.alloc(u8, value.len);
            for (value, upper) |c, *u| u.* = std.ascii.toUpper(c);
            return upper;
        } else if (std.mem.eql(u8, filter_name, "lower")) {
            const lower = try self.allocator.alloc(u8, value.len);
            for (value, lower) |c, *l| l.* = std.ascii.toLower(c);
            return lower;
        } else if (std.mem.eql(u8, filter_name, "capitalize")) {
            if (value.len == 0) return try self.allocator.dupe(u8, "");
            const cap = try self.allocator.alloc(u8, value.len);
            cap[0] = std.ascii.toUpper(value[0]);
            for (value[1..], cap[1..]) |c, *u| u.* = std.ascii.toLower(c);
            return cap;
        } else if (std.mem.eql(u8, filter_name, "trim")) {
            return try self.allocator.dupe(u8, std.mem.trim(u8, value, &std.ascii.whitespace));
        } else if (std.mem.eql(u8, filter_name, "length")) {
            return try std.fmt.allocPrint(self.allocator, "{d}", .{value.len});
        } else if (std.mem.eql(u8, filter_name, "reverse")) {
            const reversed = try self.allocator.alloc(u8, value.len);
            for (value, 0..) |c, i| {
                reversed[value.len - 1 - i] = c;
            }
            return reversed;
        }
        return try self.allocator.dupe(u8, value);
    }

    /// Skip comment {# ... #}
    fn skipComment(self: *Self) !void {
        const end = std.mem.indexOfPos(u8, self.source, self.pos, "#}");
        if (end == null) return error.UnclosedComment;
        self.pos = end.? + 2;
    }

    /// Parse expression (identifier or dotted path)
    fn parseExpression(self: *Self) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and !std.mem.startsWith(u8, self.source[self.pos..], "%}") and !std.mem.startsWith(u8, self.source[self.pos..], "}}")) {
            self.pos += 1;
        }
        return try self.allocator.dupe(u8, std.mem.trim(u8, self.source[start..self.pos], &std.ascii.whitespace));
    }

    /// Parse identifier
    fn parseIdentifier(self: *Self) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        if (start == self.pos) return error.ExpectedIdentifier;
        return try self.allocator.dupe(u8, self.source[start..self.pos]);
    }

    /// Parse string literal
    fn parseString(self: *Self) ![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return error.ExpectedString;

        const quote = self.source[self.pos];
        if (quote != '"' and quote != '\'') return error.ExpectedString;
        self.pos += 1;

        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != quote) {
            self.pos += 1;
        }

        if (self.pos >= self.source.len) return error.UnclosedString;
        const value = self.source[start..self.pos];
        self.pos += 1; // skip closing quote

        return try self.allocator.dupe(u8, value);
    }

    /// Skip to end of tag
    fn skipTag(self: *Self) void {
        while (self.pos < self.source.len and !std.mem.startsWith(u8, self.source[self.pos..], "%}")) {
            self.pos += 1;
        }
        self.pos += 2; // skip %}
    }

    /// Match string at current position
    fn match(self: *Self, str: []const u8) bool {
        if (self.pos + str.len <= self.source.len and std.mem.startsWith(u8, self.source[self.pos..], str)) {
            self.pos += str.len;
            return true;
        }
        return false;
    }

    /// Match word at current position
    fn matchWord(self: *Self, word: []const u8) bool {
        if (self.pos + word.len > self.source.len) return false;
        if (!std.mem.startsWith(u8, self.source[self.pos..], word)) return false;
        // Check that it's a complete word
        if (self.pos + word.len < self.source.len) {
            const next = self.source[self.pos + word.len];
            if (std.ascii.isAlphanumeric(next) or next == '_') return false;
        }
        self.pos += word.len;
        return true;
    }

    /// Skip whitespace
    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    /// Advance one character
    fn advance(self: *Self) void {
        if (self.pos < self.source.len) {
            self.pos += 1;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Template basic variable" {
    const allocator = std.testing.allocator;

    const html = "Hello, {{name}}!";
    var template = Template.init(allocator, html);

    const data = .{
        .name = "Alice",
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, Alice!", result);
}

test "Template with filters" {
    const allocator = std.testing.allocator;

    const html = "{{name|upper}} - {{name|lower}} - {{name|capitalize}}";
    var template = Template.init(allocator, html);

    const data = .{
        .name = "aLiCe",
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("ALICE - alice - Alice", result);
}

test "Template if statement" {
    const allocator = std.testing.allocator;

    const html = "{% if show %}Visible{% else %}Hidden{% endif %}";
    var template = Template.init(allocator, html);

    const data = .{
        .show = "yes",
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Visible", result);
}

test "Template if else" {
    const allocator = std.testing.allocator;

    const html = "{% if show %}Yes{% else %}No{% endif %}";
    var template = Template.init(allocator, html);

    const data = .{
        .show = "",
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("No", result);
}

test "Template comment" {
    const allocator = std.testing.allocator;

    const html = "Hello {# this is a comment #}World";
    var template = Template.init(allocator, html);

    const result = try template.render(.{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}

test "Template complex" {
    const allocator = std.testing.allocator;

    const html =
        \\Welcome {{name|capitalize}}!
        \\
        \\{% if admin %}
        \\You are an admin.
        \\{% else %}
        \\You are a user.
        \\{% endif %}
    ;

    var template = Template.init(allocator, html);

    const data = .{
        .name = "alice",
        .admin = "true",
    };

    const result = try template.render(data);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "Welcome Alice!") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "You are an admin.") != null);
}
