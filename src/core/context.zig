const std = @import("std");
const params = @import("params.zig");
const Page = @import("../db/pagination.zig").Page;

/// Monotonic nanosecond timestamp. Zig 0.17 removed
/// `std.time.Instant.now()` / `nanoTimestamp()` in favor of
/// `std.Io.Timestamp.now(io, .awake)`, but our context doesn't hold an
/// Io instance. `std.c.clock_gettime(.MONOTONIC, ...)` is portable and
/// matches the platform-correct timespec layout (macOS vs Linux differ).
fn monoNowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// HTTP request/response context. Wraps the raw std.http.Server.Request
/// with convenience methods for query params, path params, cookies,
/// headers, attributes, file uploads, and response rendering.
///
/// Created per-request by Server. Call `deinit()` after use.
///
/// All per-request allocations go through `allocator` (parent allocator —
/// Arena was removed for Zig 0.17 threaded-IO safety). Handlers MUST free
/// what they allocate. Call `deinit()` after the response is sent.
pub const Context = struct {
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: ?std.heap.ArenaAllocator = null,
    res_status: std.http.Status = .ok,
    /// Enable response compression (gzip/deflate) when client supports it.
    /// Automatically set based on Accept-Encoding header in render* methods.
    compress_enabled: bool = true,
    /// Remote address of the client (set by Server/AsyncServer at accept time).
    remote_addr: ?std.Io.net.IpAddress = null,
    /// Maximum request body size in bytes (default 10MB).
    max_body_size: usize = 10 * 1024 * 1024,
    deadline_ns: ?i128 = null,
    query_params: ?std.StringHashMap([]const u8) = null,
    path_params: ?std.StringHashMap([]const u8) = null,
    attributes: std.StringHashMap([]const u8),
    session_id: ?[]const u8 = null,
    cookies: ?std.StringHashMap([]const u8) = null,
    response_cookies: std.ArrayList(Cookie),
    response_headers: std.StringHashMap([]const u8),
    /// App State from `ZFinal.setState` (type-erased; use `state(T)`).
    app_state: @import("state.zig").Handle = .{},
    /// Request-scoped typed Extensions (use `ext` / `setExt`).
    extensions: @import("extension.zig").Bag = .{},
    /// Optional detail for `HttpError` JSON envelope (not owned).
    err_detail: ?[]const u8 = null,
    /// True after a successful `respond` / streaming start (prevents double-render).
    response_started: bool = false,
    /// Client disconnected / write failed during streaming — stop writing.
    client_gone: bool = false,
    /// When set, `renderJson`/`renderText`/`renderHtml` write here instead of `req.respond` (in-process tests).
    capture: ?*CapturedResponse = null,
    /// Optional request headers for `oneshot.capture` / tests (case-insensitive lookup).
    mock_headers: ?std.StringHashMap([]const u8) = null,
    /// Optional body for capture-mode extractors (`getBodyText` / `parseJsonBody`).
    mock_body: ?[]const u8 = null,

    pub const CapturedResponse = struct {
        status: std.http.Status = .ok,
        body: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *CapturedResponse) void {
            self.body.deinit(self.allocator);
            self.* = undefined;
        }
    };

    pub const Cookie = struct {
        name: []const u8,
        value: []const u8,
        max_age: ?i32 = null,
        path: []const u8 = "/",
        http_only: bool = true,
        same_site: bool = true,
        secure: bool = false,
    };

    /// Create per-request Context. Uses parent allocator directly (no Arena)
    /// to avoid Arena+container reallocation segfaults in Zig 0.17 threaded IO.
    /// Handlers MUST individually free all allocated memory via ctx.allocator.
    pub fn init(req: *std.http.Server.Request, parent_allocator: std.mem.Allocator) Context {
        var headers = std.StringHashMap([]const u8).init(parent_allocator);
        // Pre-allocate is best-effort — fall back to incremental growth if OOM.
        headers.ensureTotalCapacity(16) catch |err| {
            std.debug.print("context.init: headers pre-alloc failed ({s}); using incremental growth\n", .{@errorName(err)});
        };

        var attrs = std.StringHashMap([]const u8).init(parent_allocator);
        attrs.ensureTotalCapacity(8) catch |err| {
            std.debug.print("context.init: attrs pre-alloc failed ({s}); using incremental growth\n", .{@errorName(err)});
        };

        return Context{
            .req = req,
            .allocator = parent_allocator,
            .arena = null,
            .attributes = attrs,
            .response_cookies = std.ArrayList(Cookie).empty,
            .response_headers = headers,
        };
    }

    pub fn deinit(self: *Context) void {
        self.extensions.deinit(self.allocator);

        // Owned key+value: free strings before deinit map
        var hdr_it = self.response_headers.iterator();
        while (hdr_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.response_headers.deinit();

        var attr_it = self.attributes.iterator();
        while (attr_it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.attributes.deinit();

        if (self.query_params) |*qp| {
            var it = qp.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            qp.deinit();
        }

        // Borrowed values (path params from URL, cookies from request headers)
        if (self.path_params) |*pp| pp.deinit();
        if (self.cookies) |*ck| ck.deinit();
        // mock_headers: keys/values borrowed (setMockHeader does not copy)
        if (self.mock_headers) |*mh| mh.deinit();

        // response_cookies: name/value/path owned (dup'd in setCookieFull)
        for (self.response_cookies.items) |ck| {
            self.allocator.free(ck.name);
            self.allocator.free(ck.value);
            self.allocator.free(ck.path);
        }
        self.response_cookies.deinit(self.allocator);

        // Request-scoped arena for bindJson-owned DTO strings.
        if (self.arena) |*a| a.deinit();
    }

    pub fn getHeader(self: *Context, name: []const u8) ?[]const u8 {
        if (self.mock_headers) |*mh| {
            var it = mh.iterator();
            while (it.next()) |e| {
                if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) return e.value_ptr.*;
            }
            return null;
        }
        // oneshot.capture sets `req = undefined`; skip real header walk.
        if (self.capture != null) return null;
        var it = self.req.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) {
                return header.value;
            }
        }
        return null;
    }

    /// Insert a mock request header (capture / unit tests). Values are not copied.
    pub fn setMockHeader(self: *Context, name: []const u8, value: []const u8) !void {
        if (self.mock_headers == null) {
            self.mock_headers = .init(self.allocator);
        }
        try self.mock_headers.?.put(name, value);
    }

    /// Set a per-request deadline (relative to now). `ms = 0` clears
    /// the deadline. Callers (dispatch loop, handler) should check
    /// `isExpired()` periodically and bail out via `sendError(.request_timeout)` if so.
    pub fn setTimeoutMs(self: *Context, ms: u64) void {
        if (ms == 0) {
            self.deadline_ns = null;
            return;
        }
        const now = monoNowNs();
        self.deadline_ns = now + @as(i128, ms) * std.time.ns_per_ms;
    }

    /// Returns true once the per-request deadline (if set) has elapsed.
    /// Used by the dispatch loop and long-running handlers to bail out.
    pub fn isExpired(self: *const Context) bool {
        const deadline = self.deadline_ns orelse return false;
        return monoNowNs() >= deadline;
    }

    /// Set a response header. Copies both name and value — caller retains ownership.
    /// Overwriting the same name frees the previous owned value.
    pub fn setHeader(self: *Context, name: []const u8, value: []const u8) !void {
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        if (self.response_headers.getPtr(name)) |vp| {
            self.allocator.free(vp.*);
            vp.* = value_copy;
            return;
        }
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.response_headers.put(name_copy, value_copy);
    }

    // === Query Parameters ===

    fn ensureQueryParams(self: *Context) !void {
        if (self.query_params != null) return;

        var map = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                self.allocator.free(e.value_ptr.*);
            }
            map.deinit();
        }

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
                _ = reader.discardRemaining() catch |err| {
                    std.debug.print("context.form parsing: discardRemaining failed ({s}) — request may have leftover bytes\n", .{@errorName(err)});
                };
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

    // === Declarative DTO binding ===

    /// Bind query-string params into a struct by field name (declarative DTO
    /// binding, ADR-017). Supported field types: `?i64`, `?i32`, `?f64`,
    /// `?bool`, `?[]const u8`, and optionals of enums (`?enum { asc, desc }`).
    /// Missing params keep the struct's existing defaults; a present-but-invalid
    /// value responds 400 with a JSON error and returns `error.BadRequest`.
    /// Text values are borrowed from the request params (valid for the handler).
    pub fn bindQuery(self: *Context, ptr: anytype) !void {
        const Getter = struct {
            ctx: *Context,
            fn get(ctx: *const @This(), name: []const u8) ?[]const u8 {
                return ctx.ctx.getPara(name) catch null;
            }
        };
        const g = Getter{ .ctx = self };
        bindStruct(g, ptr) catch |err| {
            if (err == error.BadRequestValue) {
                self.res_status = .bad_request;
                try self.renderJson(.{ .err = "invalid query parameter value" });
                return error.BadRequest;
            }
            return err;
        };
    }

    // === Path Parameters ===

    /// Get path parameter value
    pub fn getPathParam(self: *Context, name: []const u8) ?[]const u8 {
        if (self.path_params) |pp| {
            return pp.get(name);
        }
        return null;
    }

    /// Alias for `getPathParam` (smart_routing).
    pub fn param(self: *Context, name: []const u8) ?[]const u8 {
        return self.getPathParam(name);
    }

    /// Wildcard path param with `..` rejection (and empty). Returns null if missing;
    /// returns `error.InvalidWildcardPath` if unsafe.
    pub fn wildcardPath(self: *Context, name: []const u8) !?[]const u8 {
        const value = self.getPathParam(name) orelse return null;
        if (value.len == 0) return error.InvalidWildcardPath;
        if (std.mem.eql(u8, value, "..") or std.mem.startsWith(u8, value, "../") or
            std.mem.endsWith(u8, value, "/..") or std.mem.indexOf(u8, value, "/../") != null)
        {
            return error.InvalidWildcardPath;
        }
        if (value[0] == '/' or (value.len >= 2 and value[1] == ':')) {
            return error.InvalidWildcardPath; // absolute / drive
        }
        return value;
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

    /// Store a request attribute (copies key+value). Overwrite frees the old value.
    pub fn setAttr(self: *Context, key: []const u8, value: []const u8) !void {
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        if (self.attributes.getPtr(key)) |vp| {
            self.allocator.free(vp.*);
            vp.* = value_copy;
            return;
        }
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.attributes.put(key_copy, value_copy);
    }

    pub fn getAttr(self: *Context, key: []const u8) ?[]const u8 {
        return self.attributes.get(key);
    }

    pub fn getAttrDefault(self: *Context, key: []const u8, default_value: []const u8) []const u8 {
        return self.attributes.get(key) orelse default_value;
    }

    /// Typed app State (`ZFinal.setState`). Returns `error.StateNotSet` / `StateTypeMismatch`.
    pub fn state(self: *Context, comptime T: type) !*T {
        return self.app_state.get(T);
    }

    pub fn stateOrNull(self: *Context, comptime T: type) ?*T {
        return self.app_state.getOrNull(T);
    }

    /// Request-scoped typed Extension (Axum `Extension<T>`).
    pub fn ext(self: *Context, comptime T: type) ?*T {
        return self.extensions.get(T);
    }

    pub fn setExt(self: *Context, comptime T: type, value: T) !void {
        try @import("extension.zig").putOwned(&self.extensions, self.allocator, T, value);
    }

    pub fn markResponded(self: *Context) void {
        self.response_started = true;
    }

    /// Write SSE data; on `WriteFailed` sets `client_gone` and returns that error.
    pub fn sseWrite(self: *Context, bw: *std.http.BodyWriter, data: []const u8) !void {
        if (self.client_gone) return error.WriteFailed;
        writeSseData(bw, data) catch |err| {
            if (err == error.WriteFailed) self.client_gone = true;
            return err;
        };
    }

    pub fn isClientGone(self: *const Context) bool {
        return self.client_gone;
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
        // Secure defaults: HttpOnly + SameSite=Strict. Use setCookieFull for Secure (HTTPS).
        try self.setCookieFull(name, value, max_age, "/", true, true, false);
    }

    pub fn setCookieFull(self: *Context, name: []const u8, value: []const u8, max_age: ?i32, path: []const u8, http_only: bool, same_site: bool, secure: bool) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.response_cookies.append(self.allocator, .{
            .name = name_copy,
            .value = value_copy,
            .max_age = max_age,
            .path = path_copy,
            .http_only = http_only,
            .same_site = same_site,
            .secure = secure,
        });
    }

    pub fn removeCookie(self: *Context, name: []const u8) !void {
        try self.setCookieFull(name, "", @as(i32, 0), "/", true, true, false);
    }

    /// Check if the client accepts gzip encoding.
    fn clientAcceptsGzip(self: *Context) bool {
        if (!self.compress_enabled) return false;
        const accept = self.getHeader("Accept-Encoding") orelse return false;
        return std.mem.indexOf(u8, accept, "gzip") != null;
    }

    /// Apply gzip compression to a response body using std.compress.flate.
    /// Returns the compressed data, or the original body if compression fails/declines.
    /// When `is_compressed`, caller owns `data` and must free it.
    fn compressBody(self: *Context, body: []const u8) !struct { data: []const u8, is_compressed: bool } {
        if (body.len < 256 or !self.clientAcceptsGzip()) return .{ .data = body, .is_compressed = false };

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        // Stack window — Compress.Raw borrows it; never heap-alloc (was leaked).
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var scratch: [16384]u8 = undefined;
        var scratch_w: std.Io.Writer = .fixed(&scratch);
        const Compress = std.compress.flate.Compress;
        var compressor = Compress.Raw.init(&scratch_w, &window, .gzip) catch |err| {
            std.debug.print("context.compressGzip: compressor init failed ({s}); serving uncompressed\n", .{@errorName(err)});
            return .{ .data = body, .is_compressed = false };
        };

        compressor.writer.writeAll(body) catch |err| {
            std.debug.print("context.compressGzip: writeAll failed ({s}); serving uncompressed\n", .{@errorName(err)});
            return .{ .data = body, .is_compressed = false };
        };
        compressor.finish() catch |err| {
            std.debug.print("context.compressGzip: finish failed ({s}); serving partial compressed output\n", .{@errorName(err)});
        };

        // Copy scratch buffer (full gzip stream including header + footer).
        const compressed_len = scratch_w.end;
        try buf.appendSlice(self.allocator, scratch[0..compressed_len]);

        const data = try buf.toOwnedSlice(self.allocator);
        return .{ .data = data, .is_compressed = true };
    }

    // === Rendering ===

    fn appendSetCookieHeaders(self: *Context, headers: *std.ArrayList(std.http.Header)) !void {
        // Pre-build cookie strings on the heap so they outlive the for-loop scope.
        // The caller must free these after respond() via freeSetCookieDupes.
        for (self.response_cookies.items) |cookie| {
            const http_part = if (cookie.http_only) "; HttpOnly" else "";
            const same_site_part = if (cookie.same_site) "; SameSite=Strict" else "";
            const secure_part = if (cookie.secure) "; Secure" else "";
            const cookie_value = if (cookie.max_age) |max_age|
                try std.fmt.allocPrint(self.allocator, "{s}={s}; Path={s}; Max-Age={d}{s}{s}{s}", .{ cookie.name, cookie.value, cookie.path, max_age, http_part, same_site_part, secure_part })
            else
                try std.fmt.allocPrint(self.allocator, "{s}={s}; Path={s}{s}{s}{s}", .{ cookie.name, cookie.value, cookie.path, http_part, same_site_part, secure_part });

            try headers.append(self.allocator, .{ .name = "Set-Cookie", .value = cookie_value });
        }
    }

    /// Drain unconsumed request body — must be called before any respond().
    /// Handlers that don't call getBodyText leave the POST body unread,
    /// which causes std.http.Server.discardBody assertion failure in Zig 0.17.
    /// See `keepalive_safety.zig` + zig#25017.
    fn drainUnconsumedBody(self: *Context) void {
        const ka = @import("keepalive_safety.zig");
        ka.drainPreparedBody(self.req);
    }

    fn freeSetCookieDupes(self: *Context, headers: std.ArrayList(std.http.Header)) void {
        for (headers.items) |h| {
            if (std.mem.eql(u8, h.name, "Set-Cookie")) {
                self.allocator.free(h.value);
            }
        }
    }

    pub fn renderText(self: *Context, text: []const u8) !void {
        if (self.response_started) return;
        if (self.capture) |cap| {
            cap.status = self.res_status;
            try cap.body.appendSlice(self.allocator, text);
            self.markResponded();
            return;
        }
        // Try gzip if client accepts and body is large enough to be worth compressing.
        const compressed = try self.compressBody(text);
        // If compressed, the slice is a fresh heap allocation we must free.
        defer if (compressed.is_compressed) self.allocator.free(compressed.data);

        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        if (compressed.is_compressed) {
            try headers.append(self.allocator, .{ .name = "Content-Encoding", .value = "gzip" });
        }

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        self.drainUnconsumedBody();

        try self.req.respond(compressed.data, .{
            .status = self.res_status,
            .extra_headers = headers.items,
            .keep_alive = self.req.head.keep_alive,
        });
        self.markResponded();
    }

    pub fn renderJson(self: *Context, data: anytype) !void {
        if (self.response_started) return;
        const json = try std.json.Stringify.valueAlloc(self.allocator, data, .{});
        defer self.allocator.free(json);

        if (self.capture) |cap| {
            cap.status = self.res_status;
            try cap.body.appendSlice(self.allocator, json);
            self.markResponded();
            return;
        }
        const compressed = try self.compressBody(json);
        defer if (compressed.is_compressed) self.allocator.free(compressed.data);

        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "application/json" });
        if (compressed.is_compressed) {
            try headers.append(self.allocator, .{ .name = "Content-Encoding", .value = "gzip" });
        }

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        self.drainUnconsumedBody();

        try self.req.respond(compressed.data, .{
            .status = self.res_status,
            .extra_headers = headers.items,
            .keep_alive = self.req.head.keep_alive,
        });
        self.markResponded();
    }

    /// 200 response shortcut: `{"data": ...}`.
    pub fn ok(self: *Context, data: anytype) !void {
        try self.renderJson(.{ .data = data });
    }

    /// 201 response shortcut: `{"ok": true, "id": ...}`.
    pub fn created(self: *Context, id: anytype) !void {
        self.res_status = .created;
        try self.renderJson(.{ .ok = true, .id = id });
    }

    /// Serialize a `Page(T)`-shaped value as `{data, total, page, size}`, then
    /// free it: per-item `deinit(allocator)` (when the item type has one) and
    /// the list slice. One call replaces the render + free dance in list handlers.
    pub fn renderPage(self: *Context, page: anytype, allocator: std.mem.Allocator) !void {
        var p = page;
        const items = p.list;
        const Item = @TypeOf(items[0]);
        const total: i64 = @intCast(p.total_row);
        const page_num: i64 = @intCast(p.page_number);
        const size: i64 = @intCast(p.page_size);

        errdefer deinitPageItems(items, Item, allocator);
        try self.renderJson(.{ .data = items, .total = total, .page = page_num, .size = size });
        deinitPageItems(items, Item, allocator);
        p.deinit();
    }

    pub fn renderHtml(self: *Context, html: []const u8) !void {
        if (self.response_started) return;
        if (self.capture) |cap| {
            cap.status = self.res_status;
            try cap.body.appendSlice(self.allocator, html);
            self.markResponded();
            return;
        }
        const compressed = try self.compressBody(html);
        defer if (compressed.is_compressed) self.allocator.free(compressed.data);

        var headers = std.ArrayList(std.http.Header).empty;
        defer {
            self.freeSetCookieDupes(headers);
            headers.deinit(self.allocator);
        }

        try headers.append(self.allocator, .{ .name = "Content-Type", .value = "text/html; charset=utf-8" });
        if (compressed.is_compressed) {
            try headers.append(self.allocator, .{ .name = "Content-Encoding", .value = "gzip" });
        }

        // Add custom headers
        var header_it = self.response_headers.iterator();
        while (header_it.next()) |entry| {
            try headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Add Set-Cookie headers (heap-allocated, freed in defer above)
        try self.appendSetCookieHeaders(&headers);

        self.drainUnconsumedBody();

        try self.req.respond(compressed.data, .{
            .status = self.res_status,
            .extra_headers = headers.items,
            .keep_alive = self.req.head.keep_alive,
        });
        self.markResponded();
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
        const bw = try self.req.respondStreaming(&body_buf, .{
            .content_length = null,
            .respond_options = .{
                .status = self.res_status,
                .extra_headers = headers.items,
                .transfer_encoding = .chunked,
            },
        });
        self.markResponded();
        return bw;
    }

    pub fn renderSSEError(self: *Context, msg: []const u8) !void {
        var bw = try self.renderSSE();
        defer bw.end() catch {};
        var buf: [512]u8 = undefined;
        // Keep payload simple JSON; callers can write richer frames via writeSse*.
        const payload = std.fmt.bufPrint(&buf, "{{\"err\":\"{s}\"}}", .{msg}) catch "{\"err\":\"error\"}";
        try Context.writeSseData(&bw, payload);
        try bw.flush();
    }

    /// Write one SSE `data:` frame (adds trailing `\n\n`).
    pub fn writeSseData(bw: *std.http.BodyWriter, data: []const u8) !void {
        try bw.writer.writeAll("data: ");
        try bw.writer.writeAll(data);
        try bw.writer.writeAll("\n\n");
    }

    /// Write SSE frame with optional `event:` name.
    pub fn writeSseEvent(bw: *std.http.BodyWriter, event: []const u8, data: []const u8) !void {
        try bw.writer.writeAll("event: ");
        try bw.writer.writeAll(event);
        try bw.writer.writeAll("\n");
        try writeSseData(bw, data);
    }

    /// SSE comment line (`: …`) — useful as keepalive.
    pub fn writeSseComment(bw: *std.http.BodyWriter, comment: []const u8) !void {
        try bw.writer.writeAll(": ");
        try bw.writer.writeAll(comment);
        try bw.writer.writeAll("\n\n");
    }

    // === JSON Body ===

    /// Read request body as raw text.
    pub fn getBodyText(self: *Context) ![]const u8 {
        if (self.mock_body) |b| return try self.allocator.dupe(u8, b);
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

    /// Declarative JSON-body DTO binding (ADR-017). Parses the request body
    /// into `ptr` (unknown fields ignored); the struct's string fields are
    /// owned by a request-scoped arena freed at `Context.deinit`, so they stay
    /// valid for the whole handler. Parse failure responds 400 and returns
    /// `error.BadRequest`.
    pub fn bindJson(self: *Context, ptr: anytype) !void {
        const body = self.getBodyText() catch {
            self.res_status = .bad_request;
            try self.renderJson(.{ .err = "cannot read request body" });
            return error.BadRequest;
        };
        defer self.allocator.free(body);
        if (self.arena == null) {
            self.arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        const arena = &self.arena.?;
        bindJsonInto(arena, body, ptr) catch |err| {
            if (err == error.BadRequest) {
                self.res_status = .bad_request;
                try self.renderJson(.{ .err = "invalid JSON body" });
                return error.BadRequest;
            }
            return err;
        };
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

    /// Reject path traversal / absolute paths for download helpers.
    pub fn isSafeDownloadPath(path: []const u8) bool {
        if (path.len == 0 or path[0] == '/') return false;
        if (std.mem.indexOf(u8, path, "..") != null) return false;
        return true;
    }

    pub fn renderFile(self: *Context, path: []const u8, download_name: ?[]const u8) !void {
        if (self.response_started) return;
        if (!isSafeDownloadPath(path)) return error.PathTraversal;
        const io_instance = @import("../io_instance.zig");
        const file = try std.Io.Dir.cwd().openFile(io_instance.io, path, .{});
        defer file.close(io_instance.io);

        const stat = try file.stat(io_instance.io);
        if (stat.size > 50 * 1024 * 1024) return error.FileTooLarge;
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);
        var read_buf: [4096]u8 = undefined;
        var rdr = file.reader(io_instance.io, &read_buf);
        while (true) {
            const n = rdr.interface.readSliceShort(read_buf[0..]) catch break;
            if (n == 0) break;
            try content.appendSlice(self.allocator, read_buf[0..n]);
            if (n < read_buf.len) break;
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
        self.markResponded();
    }

    /// 渲染 CSV 响应，自动设置 Content-Type: text/csv 和下载文件名
    /// 使用 zfinal.CsvKit 生成的 []u8 内容直接返回
    pub fn renderCsv(self: *Context, data: []const u8, download_name: []const u8) !void {
        if (self.response_started) return;
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
        self.markResponded();
    }

    /// Send a 302 redirect response to the given URL.
    pub fn redirect(self: *Context, url: []const u8) !void {
        if (self.response_started) return;
        try self.req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = url },
            },
        });
        self.markResponded();
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

test "context: isSafeDownloadPath rejects traversal" {
    try std.testing.expect(!Context.isSafeDownloadPath(""));
    try std.testing.expect(!Context.isSafeDownloadPath("/etc/passwd"));
    try std.testing.expect(!Context.isSafeDownloadPath("../secret"));
    try std.testing.expect(!Context.isSafeDownloadPath("foo/../../etc"));
    try std.testing.expect(Context.isSafeDownloadPath("static/app.js"));
    try std.testing.expect(Context.isSafeDownloadPath("ok/file.txt"));
}

test "context: setCookie defaults HttpOnly+SameSite" {
    const a = std.testing.allocator;
    // Minimal Context without a live HTTP request — only exercise cookie list.
    var ctx: Context = undefined;
    ctx.allocator = a;
    ctx.response_cookies = .empty;
    defer {
        for (ctx.response_cookies.items) |c| {
            a.free(c.name);
            a.free(c.value);
            a.free(c.path);
        }
        ctx.response_cookies.deinit(a);
    }

    try ctx.setCookie("sid", "abc", 3600);
    try std.testing.expectEqual(@as(usize, 1), ctx.response_cookies.items.len);
    const c = ctx.response_cookies.items[0];
    try std.testing.expect(c.http_only);
    try std.testing.expect(c.same_site);
    try std.testing.expect(!c.secure);
    try std.testing.expectEqualStrings("sid", c.name);
    try std.testing.expectEqualStrings("abc", c.value);
}

test "context: second render is no-op when response_started" {
    const a = std.testing.allocator;
    var cap: Context.CapturedResponse = .{ .allocator = a };
    defer cap.deinit();
    var ctx: Context = .{
        .req = undefined,
        .allocator = a,
        .attributes = .init(a),
        .response_cookies = .empty,
        .response_headers = .init(a),
        .capture = &cap,
        .compress_enabled = false,
    };
    defer {
        ctx.attributes.deinit();
        ctx.response_headers.deinit();
        ctx.response_cookies.deinit(a);
    }

    try ctx.renderText("first");
    try ctx.renderText("second");
    try ctx.renderJson(.{ .ignored = true });
    try std.testing.expect(ctx.response_started);
    try std.testing.expectEqualStrings("first", cap.body.items);
}

test "context: setAttr/setHeader overwrite frees previous value" {
    const a = std.testing.allocator;
    var ctx: Context = .{
        .req = undefined,
        .allocator = a,
        .attributes = .init(a),
        .response_cookies = .empty,
        .response_headers = .init(a),
        .compress_enabled = false,
    };
    defer ctx.deinit();

    try ctx.setAttr("k", "v1");
    try ctx.setAttr("k", "v2");
    try std.testing.expectEqualStrings("v2", ctx.getAttr("k").?);

    try ctx.setHeader("X-A", "1");
    try ctx.setHeader("X-A", "2");
    try std.testing.expectEqualStrings("2", ctx.response_headers.get("X-A").?);
}

// ─────────────────────────────────────────────────────────────────────────────
// Declarative DTO binding helpers (ADR-017) — pure, unit-testable.
// ─────────────────────────────────────────────────────────────────────────────

/// Iterate a struct's fields and bind each from `getter.get(field_name)`.
/// Missing params keep the struct's defaults; invalid values return
/// `error.BadRequestValue`.
fn bindStruct(getter: anytype, ptr: anytype) !void {
    const PtrT = @TypeOf(ptr);
    const Struct = @typeInfo(PtrT).@"pointer".child;
    const fields = @typeInfo(Struct).@"struct";
    inline for (fields.field_names, fields.field_types) |fname, FT| {
        const raw = getter.get(fname);
        if (raw) |r| { // param absent — keep the struct's default
            @field(ptr, fname) = try parseBound(FT, r);
        }
    }
}

fn parseBound(comptime FT: type, raw: ?[]const u8) !FT {
    const is_opt = @typeInfo(FT) == .optional;
    const T = if (is_opt) @typeInfo(FT).optional.child else FT;
    const trimmed = if (raw) |r| std.mem.trim(u8, r, " \t\r\n") else null;
    if (trimmed == null or trimmed.?.len == 0) {
        return if (is_opt) @as(FT, null) else std.mem.zeroes(FT);
    }
    return switch (@typeInfo(T)) {
        .int => blk: {
            const v = std.fmt.parseInt(T, trimmed.?, 10) catch return error.BadRequestValue;
            break :blk if (is_opt) @as(FT, v) else @as(FT, v);
        },
        .float => blk: {
            const v = std.fmt.parseFloat(T, trimmed.?) catch return error.BadRequestValue;
            break :blk if (is_opt) @as(FT, v) else @as(FT, v);
        },
        .bool => blk: {
            const v = params.toBoolean(trimmed, null) orelse return error.BadRequestValue;
            break :blk if (is_opt) @as(FT, v) else @as(FT, v);
        },
        .pointer => blk: {
            if (T != []const u8) @compileError("unsupported bindQuery pointer type: " ++ @typeName(FT));
            break :blk if (is_opt) @as(FT, trimmed.?) else @as(FT, trimmed.?);
        },
        .@"enum" => blk: {
            const v = std.meta.stringToEnum(T, trimmed.?) orelse return error.BadRequestValue;
            break :blk if (is_opt) @as(FT, v) else @as(FT, v);
        },
        else => @compileError("unsupported bindQuery field type: " ++ @typeName(FT)),
    };
}

const QueryStub = struct {
    map: std.StringHashMap([]const u8),
    fn get(self: QueryStub, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

test "bindStruct: parses typed fields with defaults preserved" {
    const a = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(a);
    defer map.deinit();
    try map.put("status", "pub");
    try map.put("views", "42");
    try map.put("active", "true");
    try map.put("q", "hello");
    try map.put("sort", "desc");
    const stub = QueryStub{ .map = map };

    const Filters = struct {
        status: ?[]const u8 = null,
        views: ?i64 = null,
        active: ?bool = null,
        q: ?[]const u8 = null,
        sort: ?enum { asc, desc } = null,
        min_views: ?i64 = null,
        limit: i64 = 20,
    };
    var f: Filters = .{};
    try bindStruct(stub, &f);
    try std.testing.expectEqualStrings("pub", f.status.?);
    try std.testing.expectEqual(@as(?i64, 42), f.views);
    try std.testing.expectEqual(@as(?bool, true), f.active);
    try std.testing.expectEqualStrings("hello", f.q.?);
    try std.testing.expect(f.sort != null and f.sort.? == .desc);
    try std.testing.expectEqual(@as(?i64, null), f.min_views);
    try std.testing.expectEqual(@as(i64, 20), f.limit); // missing param keeps default
}

test "bindStruct: invalid int → BadRequestValue" {
    const a = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(a);
    defer map.deinit();
    try map.put("views", "abc");
    const stub = QueryStub{ .map = map };
    const Filters = struct { views: ?i64 = null };
    var f: Filters = .{};
    try std.testing.expectError(error.BadRequestValue, bindStruct(stub, &f));
}

test "bindStruct: invalid enum tag → BadRequestValue" {
    const a = std.testing.allocator;
    var map = std.StringHashMap([]const u8).init(a);
    defer map.deinit();
    try map.put("sort", "sideways");
    const stub = QueryStub{ .map = map };
    const Filters = struct { sort: ?enum { asc, desc } = null };
    var f: Filters = .{};
    try std.testing.expectError(error.BadRequestValue, bindStruct(stub, &f));
}

/// Free a Page's items (calling `deinit(allocator)` when the item type has one).
/// The list slice itself is freed by `Page.deinit`.
fn deinitPageItems(items: anytype, comptime Item: type, allocator: std.mem.Allocator) void {
    if (@hasDecl(Item, "deinit")) {
        for (items) |*it| it.deinit(allocator);
    }
}

test "context: renderPage serializes and frees items" {
    const a = std.testing.allocator;
    var cap: Context.CapturedResponse = .{ .allocator = a };
    defer cap.deinit();
    var ctx: Context = .{
        .req = undefined,
        .allocator = a,
        .attributes = .init(a),
        .response_cookies = .empty,
        .response_headers = .init(a),
        .capture = &cap,
        .compress_enabled = false,
    };
    defer {
        ctx.attributes.deinit();
        ctx.response_headers.deinit();
        ctx.response_cookies.deinit(a);
    }

    const Item = struct {
        name: []const u8,
        fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.name);
        }
    };
    const list = try a.alloc(Item, 2);
    list[0] = .{ .name = try a.dupe(u8, "x") };
    list[1] = .{ .name = try a.dupe(u8, "y") };
    const page = Page(Item).init(a, list, 1, 2, 2);
    try ctx.renderPage(page, a);
    try std.testing.expect(ctx.response_started);
    try std.testing.expectEqualStrings(
        "{\"data\":[{\"name\":\"x\"},{\"name\":\"y\"}],\"total\":2,\"page\":1,\"size\":2}",
        cap.body.items,
    );
}

/// Parse `body` as JSON into `ptr` (unknown fields ignored; missing fields keep
/// struct defaults). String fields are allocated from `arena` — the caller
/// (request-scoped arena) owns them until the arena is deinit'd. Parse failure
/// → `error.BadRequest`.
fn bindJsonInto(arena: *std.heap.ArenaAllocator, body: []const u8, ptr: anytype) !void {
    const T = @typeInfo(@TypeOf(ptr)).@"pointer".child;
    const parsed = std.json.parseFromSlice(T, arena.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return error.BadRequest;
    };
    defer parsed.deinit(); // arena free is a no-op; memory lives until arena.deinit
    ptr.* = parsed.value;
}

test "bindJsonInto: parses struct, ignores unknown fields, keeps defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const Input = struct {
        title: []const u8 = "",
        views: i64 = 0,
        tags: ?[]const u8 = null,
    };
    var dto: Input = .{};
    try bindJsonInto(&arena, "{\"title\":\"hi\",\"views\":3,\"unknown\":true}", &dto);
    try std.testing.expectEqualStrings("hi", dto.title);
    try std.testing.expectEqual(@as(i64, 3), dto.views);
    try std.testing.expect(dto.tags == null); // missing optional keeps default
    // arena-owned string is readable after the helper returns
    try std.testing.expectEqualStrings("hi", dto.title);
}

test "bindJsonInto: malformed JSON → BadRequest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Input = struct { title: []const u8 = "" };
    var dto: Input = .{};
    try std.testing.expectError(error.BadRequest, bindJsonInto(&arena, "{not json", &dto));
}

test "context: ok() and created() response shortcuts" {
    const a = std.testing.allocator;
    // ok()
    {
        var cap: Context.CapturedResponse = .{ .allocator = a };
        defer cap.deinit();
        var ctx: Context = .{
            .req = undefined,
            .allocator = a,
            .attributes = .init(a),
            .response_cookies = .empty,
            .response_headers = .init(a),
            .capture = &cap,
            .compress_enabled = false,
        };
        defer {
            ctx.attributes.deinit();
            ctx.response_headers.deinit();
            ctx.response_cookies.deinit(a);
        }
        try ctx.ok(.{ .name = "x" });
        try std.testing.expectEqualStrings("{\"data\":{\"name\":\"x\"}}", cap.body.items);
        try std.testing.expectEqual(std.http.Status.ok, cap.status);
    }
    // created()
    {
        var cap: Context.CapturedResponse = .{ .allocator = a };
        defer cap.deinit();
        var ctx: Context = .{
            .req = undefined,
            .allocator = a,
            .attributes = .init(a),
            .response_cookies = .empty,
            .response_headers = .init(a),
            .capture = &cap,
            .compress_enabled = false,
        };
        defer {
            ctx.attributes.deinit();
            ctx.response_headers.deinit();
            ctx.response_cookies.deinit(a);
        }
        try ctx.created(@as(i64, 7));
        try std.testing.expectEqualStrings("{\"ok\":true,\"id\":7}", cap.body.items);
        try std.testing.expectEqual(std.http.Status.created, cap.status);
    }
}
