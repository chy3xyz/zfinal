const std = @import("std");
const params = @import("params.zig");

/// HTTP request/response context. Wraps the raw std.http.Server.Request
/// with convenience methods for query params, path params, cookies,
/// headers, attributes, file uploads, and response rendering.
///
/// Created per-request by Server. Call `deinit()` after use.
pub const Context = struct {
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    res_status: std.http.Status = .ok,
    /// Enable response compression (gzip/deflate) when client supports it.
    /// Automatically set based on Accept-Encoding header in render* methods.
    compress_enabled: bool = true,
    /// Remote address of the client (set by Server/AsyncServer at accept time).
    remote_addr: ?std.Io.net.IpAddress = null,
    /// Maximum request body size in bytes (default 10MB).
    max_body_size: usize = 10 * 1024 * 1024,
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
        http_only: bool = false,
    };

    pub fn init(req: *std.http.Server.Request, allocator: std.mem.Allocator) Context {
        return Context{
            .req = req,
            .allocator = allocator,
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .response_cookies = std.ArrayList(Cookie).empty,
            .response_headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.query_params) |*qp| {
            var it = qp.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            qp.deinit();
        }
        if (self.path_params) |*pp| {
            // Path params borrow from route/target; only free the map itself.
            pp.deinit();
        }
        var attr_it = self.attributes.iterator();
        while (attr_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
        if (self.cookies) |*c| {
            // Cookie values borrow from request headers; only free the map.
            c.deinit();
        }
        self.response_cookies.deinit(self.allocator);
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

        var map = std.StringHashMap([]const u8).init(self.allocator);

        // 1. Parse URL query string
        const target = self.req.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |q_pos| {
            const query = target[q_pos + 1 ..];
            try params.parseQueryIntoAllocator(self.allocator, query, &map);
        }

        // 2. Parse x-www-form-urlencoded body for POST/PUT/PATCH methods
        if (self.req.head.method == .POST or self.req.head.method == .PUT or self.req.head.method == .PATCH) {
            const content_type = self.getHeader("content-type") orelse "";
            if (std.ascii.startsWithIgnoreCase(content_type, "application/x-www-form-urlencoded")) {
                var body_buffer = std.ArrayList(u8).empty;
                defer body_buffer.deinit(self.allocator);

                var read_buf: [4096]u8 = undefined;
                var reader = self.req.readerExpectNone(&read_buf);
                try reader.appendRemaining(self.allocator, &body_buffer, .limited(self.max_body_size));
                if (body_buffer.items.len > 0) {
                    try params.parseQueryIntoAllocator(self.allocator, body_buffer.items, &map);
                }
            }
        }

        self.query_params = map;
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
        try self.setCookieFull(name, value, max_age, "/", false);
    }

    pub fn setCookieFull(self: *Context, name: []const u8, value: []const u8, max_age: ?i32, path: []const u8, http_only: bool) !void {
        try self.response_cookies.append(self.allocator, .{
            .name = name,
            .value = value,
            .max_age = max_age,
            .path = path,
            .http_only = http_only,
        });
    }

    pub fn removeCookie(self: *Context, name: []const u8) !void {
        try self.setCookieFull(name, "", @as(i32, 0), "/", false);
    }

    /// Check if the client accepts gzip encoding.
    fn clientAcceptsGzip(self: *Context) bool {
        if (!self.compress_enabled) return false;
        const accept = self.getHeader("Accept-Encoding") orelse return false;
        return std.mem.indexOf(u8, accept, "gzip") != null;
    }

    /// Apply gzip compression to a response body using std.compress.flate.
    /// Returns the compressed data, or the original body if compression fails/declines.
    fn compressBody(self: *Context, body: []const u8) !struct { data: []const u8, is_compressed: bool } {
        if (body.len < 256 or !self.clientAcceptsGzip()) return .{ .data = body, .is_compressed = false };

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        const gzip_hdr = std.compress.flate.Container.gzip.header();
        try buf.appendSlice(self.allocator, gzip_hdr);

        var w = buf.writer();
        const Compress = std.compress.flate.Compress;
        var compressor = Compress.Raw.init(&w, try self.allocator.alloc(u8, 8192), .gzip) catch {
            return .{ .data = body, .is_compressed = false };
        };
        defer compressor.deinit();

        compressor.writer.writeAll(body) catch {
            return .{ .data = body, .is_compressed = false };
        };
        compressor.close() catch {
            return .{ .data = body, .is_compressed = false };
        };

        const gzip_footer = std.compress.flate.Container.gzip.footer();
        try buf.appendSlice(self.allocator, gzip_footer);

        const data = try buf.toOwnedSlice(self.allocator);
        return .{ .data = data, .is_compressed = true };
    }

    // === Rendering ===

    fn appendSetCookieHeaders(self: *Context, headers: *std.ArrayList(std.http.Header)) !void {
        // Pre-build cookie strings on the heap so they outlive the for-loop scope.
        // The caller must free these after respond() via freeSetCookieDupes.
        for (self.response_cookies.items) |cookie| {
            const http_part = if (cookie.http_only) "; HttpOnly" else "";
            const cookie_value = if (cookie.max_age) |max_age|
                try std.fmt.allocPrint(self.allocator, "{s}={s}; Path={s}; Max-Age={d}{s}", .{ cookie.name, cookie.value, cookie.path, max_age, http_part })
            else
                try std.fmt.allocPrint(self.allocator, "{s}={s}; Path={s}{s}", .{ cookie.name, cookie.value, cookie.path, http_part });

            try headers.append(self.allocator, .{ .name = "Set-Cookie", .value = cookie_value });
        }
    }

    fn freeSetCookieDupes(self: *Context, headers: std.ArrayList(std.http.Header)) void {
        for (headers.items) |h| {
            if (std.mem.eql(u8, h.name, "Set-Cookie")) {
                self.allocator.free(h.value);
            }
        }
    }

    pub fn renderText(self: *Context, text: []const u8) !void {
        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        try self.req.respond(text, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    pub fn renderJson(self: *Context, data: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, data, .{});
        defer self.allocator.free(json);

        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        try self.req.respond(json, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    pub fn renderHtml(self: *Context, html: []const u8) !void {
        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "text/html; charset=utf-8" });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        try self.req.respond(html, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    // === SSE Streaming ===

    pub fn renderSSE(self: *Context) !std.http.BodyWriter {
        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "text/event-stream" });
        try headers.append(self.allocator, .{ .name = "Cache-Control", .value = "no-cache" });
        try headers.append(self.allocator, .{ .name = "Connection", .value = "keep-alive" });
        try headers.append(self.allocator, .{ .name = "X-Accel-Buffering", .value = "no" });

        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }
        try self.appendSetCookieHeaders(&headers);

        var body_buf: [8192]u8 = undefined;
        return try self.req.respondStreaming(&body_buf, .{
            .content_length = null,
            .respond_options = .{
                .status = self.res_status,
                .extra_headers = headers.items,
                .transfer_encoding = .chunked,
            },
        });
    }

    pub fn renderSSEError(self: *Context, msg: []const u8) !void {
        var bw = try self.renderSSE();
        defer bw.end() catch {};
        const sse_data = try std.fmt.allocPrint(self.allocator, "data: {{\"err\": \"{s}\"}}\n\n", .{msg});
        defer self.allocator.free(sse_data);
        try bw.writer.writeAll(sse_data);
        try bw.flush();
    }

    // === JSON Body ===

    /// Read request body as raw text.
    pub fn getBodyText(self: *Context) ![]const u8 {
        var read_buf: [4096]u8 = undefined;
        var reader = self.req.readerExpectNone(&read_buf);
        return try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_body_size));
    }

    /// Parse JSON request body into the given type.
    /// Caller owns the returned Parsed(T) and must call .deinit().
    pub fn parseJsonBody(self: *Context, comptime T: type) !std.json.Parsed(T) {
        const body = try self.getBodyText();
        defer self.allocator.free(body);
        return std.json.parseFromSlice(T, self.allocator, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    // === File Upload ===

    /// Get uploaded file by field name
    pub fn getFile(self: *Context, name: []const u8) !?@import("../upload/multipart.zig").UploadFile {
        const files = try self.getFiles();
        defer {
            for (files.items) |*file| {
                file.deinit();
            }
            files.deinit(self.allocator);
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
            return std.ArrayList(@import("../upload/multipart.zig").UploadFile).empty;
        }

        // Read request body
        var read_buf: [4096]u8 = undefined;
        var reader = self.req.readerExpectNone(&read_buf);
        const body = try reader.allocRemaining(self.allocator, std.Io.Limit.limited(self.max_body_size));
        defer self.allocator.free(body);

        // Parse multipart
        var parser = try MultipartParser.init(self.allocator, content_type.?);
        return try parser.parse(body);
    }

    // === File Download ===

    pub fn renderFile(self: *Context, path: []const u8, download_name: ?[]const u8) !void {
        const io_instance = @import("../io_instance.zig");
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        _ = try file.stat(io_instance.io);
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        var read_buf: [4096]u8 = undefined;
        var rdr = file.reader(io_instance.io, &read_buf);
        while (true) {
            const n = rdr.interface.readSliceShort(read_buf[0..]) catch break;
            if (n < read_buf.len) break;
            try content.appendSlice(self.allocator, read_buf[0..n]);
        }
        const file_content = try content.toOwnedSlice(self.allocator);
        defer self.allocator.free(file_content);

        self.res_status = .ok;

        const content_type = getContentType(path);

        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = content_type });

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        if (download_name) |name| {
            var disposition_buf: [512]u8 = undefined;
            const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{s}\"", .{name});
            try headers.append(self.allocator, .{ .name = "Content-Disposition", .value = disposition });
        }

        try self.req.respond(file_content, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    /// 渲染 CSV 响应，自动设置 Content-Type: text/csv 和下载文件名
    /// 使用 zfinal.CsvKit 生成的 []u8 内容直接返回
    pub fn renderCsv(self: *Context, data: []const u8, download_name: []const u8) !void {
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "text/csv; charset=utf-8" });

        var disposition_buf: [512]u8 = undefined;
        const disposition = try std.fmt.bufPrint(&disposition_buf, "attachment; filename=\"{s}\"", .{download_name});
        try headers.append(self.allocator, .{ .name = "Content-Disposition", .value = disposition });

        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        self.res_status = .ok;
        try self.req.respond(data, .{
            .status = self.res_status,
            .extra_headers = headers.items,
        });
    }

    /// Send a 302 redirect response to the given URL.
    pub fn redirect(self: *Context, url: []const u8) !void {
        try self.req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = url },
            },
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
        .{ ".csv", "text/csv" },
    });

    return Map.get(extension) orelse "application/octet-stream";
}
