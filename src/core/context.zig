const std = @import("std");
const params = @import("params.zig");

pub const Context = struct {
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    res_status: std.http.Status = .ok,
    query_params: ?std.StringHashMap([]const u8) = null,
    path_params: ?std.StringHashMap([]const u8) = null,
    attributes: std.StringHashMap([]const u8),
    session_id: ?[]const u8 = null,
    cookies: ?std.StringHashMap([]const u8) = null,
    response_cookies: std.ArrayList(Cookie),
    response_headers: std.StringHashMap([]const u8),

    pub const Cookie = struct {
        name: []const u8,
        value: []const u8,
        max_age: ?i32 = null,
        path: []const u8 = "/",
    };

    pub fn init(req: *std.http.Server.Request, allocator: std.mem.Allocator) Context {
        return Context{
            .req = req,
            .allocator = allocator,
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .response_cookies = std.ArrayList(Cookie).init(allocator),
            .response_headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.query_params) |*qp| {
            qp.deinit();
        }
        if (self.path_params) |*pp| {
            pp.deinit();
        }
        self.attributes.deinit();
        if (self.cookies) |*c| {
            c.deinit();
        }
        self.response_cookies.deinit();
        self.response_headers.deinit();
    }

    pub fn getHeader(self: *Context, name: []const u8) ?[]const u8 {
        var it = self.req.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    pub fn setHeader(self: *Context, name: []const u8, value: []const u8) !void {
        try self.response_headers.put(name, value);
    }

    // === Query Parameters ===

    fn ensureQueryParams(self: *Context) !void {
        if (self.query_params != null) return;

        const target = self.req.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |q_pos| {
            const query = target[q_pos + 1 ..];
            self.query_params = try params.parseQuery(self.allocator, query);
        } else {
            self.query_params = std.StringHashMap([]const u8).init(self.allocator);
        }
    }

    pub fn getPara(self: *Context, name: []const u8) !?[]const u8 {
        try self.ensureQueryParams();
        return self.query_params.?.get(name);
    }

    pub fn getParaDefault(self: *Context, name: []const u8, default_value: []const u8) ![]const u8 {
        const value = try self.getPara(name);
        return value orelse default_value;
    }

    pub fn getParaToInt(self: *Context, name: []const u8) !?i32 {
        const value = try self.getPara(name);
        return try params.toInt(value, null);
    }

    pub fn getParaToIntDefault(self: *Context, name: []const u8, default_value: i32) !i32 {
        const value = try self.getPara(name);
        const result = try params.toInt(value, default_value);
        return result orelse default_value;
    }

    pub fn getParaToLong(self: *Context, name: []const u8) !?i64 {
        const value = try self.getPara(name);
        return try params.toLong(value, null);
    }

    pub fn getParaToLongDefault(self: *Context, name: []const u8, default_value: i64) !i64 {
        const value = try self.getPara(name);
        const result = try params.toLong(value, default_value);
        return result orelse default_value;
    }

    pub fn getParaToBoolean(self: *Context, name: []const u8) !?bool {
        const value = try self.getPara(name);
        return params.toBoolean(value, null);
    }

    pub fn getParaToBooleanDefault(self: *Context, name: []const u8, default_value: bool) !bool {
        const value = try self.getPara(name);
        return params.toBoolean(value, default_value) orelse default_value;
    }

    // === Path Parameters ===

    /// Get path parameter value
    pub fn getPathParam(self: *Context, name: []const u8) ?[]const u8 {
        if (self.path_params) |pp| {
            return pp.get(name);
        }
        return null;
    }

    /// Get path parameter as integer
    pub fn getPathParamToInt(self: *Context, name: []const u8) !?i32 {
        const value = self.getPathParam(name) orelse return null;
        return try std.fmt.parseInt(i32, value, 10);
    }

    /// Get path parameter as i64
    pub fn getPathParamToLong(self: *Context, name: []const u8) !?i64 {
        const value = self.getPathParam(name) orelse return null;
        return try std.fmt.parseInt(i64, value, 10);
    }

    // === Attributes ===

    pub fn setAttr(self: *Context, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.attributes.put(key_copy, value_copy);
    }

    pub fn getAttr(self: *Context, key: []const u8) ?[]const u8 {
        return self.attributes.get(key);
    }

    pub fn getAttrDefault(self: *Context, key: []const u8, default_value: []const u8) []const u8 {
        return self.attributes.get(key) orelse default_value;
    }

    // === Cookies ===

    fn parseCookieHeader(self: *Context) !void {
        if (self.cookies != null) return;

        var cookies = std.StringHashMap([]const u8).init(self.allocator);
        errdefer cookies.deinit();

        var it = self.req.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Cookie")) {
                var cookie_it = std.mem.splitScalar(u8, header.value, ';');
                while (cookie_it.next()) |pair| {
                    const trimmed = std.mem.trim(u8, pair, " ");
                    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                        const name = trimmed[0..eq_pos];
                        const value = trimmed[eq_pos + 1 ..];
                        try cookies.put(name, value);
                    }
                }
            }
        }

        self.cookies = cookies;
    }

    pub fn getCookie(self: *Context, name: []const u8) !?[]const u8 {
        try self.parseCookieHeader();
        return self.cookies.?.get(name);
    }

    pub fn getCookieDefault(self: *Context, name: []const u8, default_value: []const u8) ![]const u8 {
        const value = try self.getCookie(name);
        return value orelse default_value;
    }

    pub fn setCookie(self: *Context, name: []const u8, value: []const u8, max_age: ?i32) !void {
        try self.response_cookies.append(.{
            .name = name,
            .value = value,
            .max_age = max_age,
        });
    }

    pub fn removeCookie(self: *Context, name: []const u8) !void {
        try self.setCookie(name, "", 0);
    }

    // === Rendering ===

    pub fn renderText(self: *Context, text: []const u8) !void {
        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers
        for (self.response_cookies.items) |cookie| {
            var cookie_value_buf: [512]u8 = undefined;
            const cookie_value = if (cookie.max_age) |max_age|
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}; Max-Age={d}", .{ cookie.name, cookie.value, cookie.path, max_age })
            else
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}", .{ cookie.name, cookie.value, cookie.path });

            try headers.append(.{ .name = "Set-Cookie", .value = cookie_value });
        }

        try self.req.respond(text, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    pub fn renderJson(self: *Context, data: anytype) !void {
        const json = try std.json.stringifyAlloc(self.allocator, data, .{});
        defer self.allocator.free(json);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = "Content-Type", .value = "application/json" });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers
        for (self.response_cookies.items) |cookie| {
            var cookie_value_buf: [512]u8 = undefined;
            const cookie_value = if (cookie.max_age) |max_age|
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}; Max-Age={d}", .{ cookie.name, cookie.value, cookie.path, max_age })
            else
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}", .{ cookie.name, cookie.value, cookie.path });

            try headers.append(.{ .name = "Set-Cookie", .value = cookie_value });
        }

        try self.req.respond(json, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    pub fn renderHtml(self: *Context, html: []const u8) !void {
        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = "Content-Type", .value = "text/html; charset=utf-8" });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers
        for (self.response_cookies.items) |cookie| {
            var cookie_value_buf: [512]u8 = undefined;
            const cookie_value = if (cookie.max_age) |max_age|
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}; Max-Age={d}", .{ cookie.name, cookie.value, cookie.path, max_age })
            else
                try std.fmt.bufPrint(&cookie_value_buf, "{s}={s}; Path={s}", .{ cookie.name, cookie.value, cookie.path });

            try headers.append(.{ .name = "Set-Cookie", .value = cookie_value });
        }

        try self.req.respond(html, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    // === File Upload ===

    /// Get uploaded file by field name
    pub fn getFile(self: *Context, name: []const u8) !?@import("../upload/multipart.zig").UploadFile {
        const files = try self.getFiles();
        defer {
            for (files.items) |*file| {
                file.deinit();
            }
            files.deinit();
        }

        for (files.items) |file| {
            if (std.mem.eql(u8, file.field_name, name)) {
                // Return a copy
                return @import("../upload/multipart.zig").UploadFile{
                    .field_name = try self.allocator.dupe(u8, file.field_name),
                    .filename = try self.allocator.dupe(u8, file.filename),
                    .content_type = try self.allocator.dupe(u8, file.content_type),
                    .size = file.size,
                    .data = try self.allocator.dupe(u8, file.data),
                    .allocator = self.allocator,
                };
            }
        }

        return null;
    }

    /// Get all uploaded files
    pub fn getFiles(self: *Context) !std.ArrayList(@import("../upload/multipart.zig").UploadFile) {
        const MultipartParser = @import("../upload/multipart.zig").MultipartParser;

        // Get Content-Type header
        var content_type: ?[]const u8 = null;
        var it = self.req.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_type = header.value;
                break;
            }
        }

        if (content_type == null or !std.mem.startsWith(u8, content_type.?, "multipart/form-data")) {
            return std.ArrayList(@import("../upload/multipart.zig").UploadFile).init(self.allocator);
        }

        // Read request body
        var body_buffer = std.ArrayList(u8).init(self.allocator);
        defer body_buffer.deinit();

        var reader = self.req.reader();
        try reader.readAllArrayList(&body_buffer, 10 * 1024 * 1024); // 10MB max

        // Parse multipart
        var parser = try MultipartParser.init(self.allocator, content_type.?);
        return try parser.parse(body_buffer.items);
    }

    // === File Download ===

    /// Render file for download
    pub fn renderFile(self: *Context, path: []const u8, download_name: ?[]const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(content);

        self.res_status = .ok;

        const content_type = getContentType(path);

        var headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{ .name = "Content-Type", .value = content_type });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        if (download_name) |name| {
            var disposition_buf: [512]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{s}\"", .{name});
            try headers.append(.{ .name = "Content-Disposition", .value = disposition });
        }

        try self.req.respond(content, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }
};

/// Get content type from file extension
/// Get content type from file extension
fn getContentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len == 0) return "application/octet-stream";

    const Map = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".html", "text/html" },
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".txt", "text/plain" },
        .{ ".xml", "application/xml" },
        .{ ".ico", "image/x-icon" },
    });

    return Map.get(extension) orelse "application/octet-stream";
}
