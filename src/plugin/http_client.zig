const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// HTTP client wrapping `std.http.Client` (GET/POST/PUT/DELETE).
/// Caller owns `Response.body` and must `deinit` the response.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    timeout_ms: u64 = 10_000,

    pub const Method = enum { GET, POST, PUT, DELETE };
    pub const Response = struct {
        status: u16,
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Response) void {
            self.allocator.free(self.body);
        }
    };

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !HttpClient {
        return .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, base_url),
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.allocator.free(self.base_url);
    }

    pub fn joinUrl(self: *const HttpClient, path: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
            return try self.allocator.dupe(u8, path);
        }
        if (self.base_url.len == 0) return try self.allocator.dupe(u8, path);
        const needs_slash = self.base_url[self.base_url.len - 1] != '/' and (path.len == 0 or path[0] != '/');
        if (needs_slash) {
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.base_url, path });
        }
        return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    }

    pub fn get(self: *HttpClient, path: []const u8) !Response {
        return self.request(.GET, path, null, null);
    }
    pub fn post(self: *HttpClient, path: []const u8, body: ?[]const u8) !Response {
        return self.request(.POST, path, body, null);
    }
    /// POST with `Content-Type: application/x-www-form-urlencoded`.
    pub fn postForm(self: *HttpClient, path: []const u8, body: []const u8) !Response {
        return self.request(.POST, path, body, "application/x-www-form-urlencoded");
    }
    pub fn put(self: *HttpClient, path: []const u8, body: ?[]const u8) !Response {
        return self.request(.PUT, path, body, null);
    }
    pub fn delete(self: *HttpClient, path: []const u8) !Response {
        return self.request(.DELETE, path, null, null);
    }

    pub fn request(self: *HttpClient, method: Method, path: []const u8, body: ?[]const u8, content_type: ?[]const u8) !Response {
        const url = try self.joinUrl(path);
        defer self.allocator.free(url);

        var client = std.http.Client{ .allocator = self.allocator, .io = io_instance.io };
        defer client.deinit();

        // Zig 0.17.0-dev.1422+: `FetchOptions.response_writer` is `?*Writer`.
        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        const http_method: std.http.Method = switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
        };

        var headers_buf: [1]std.http.Header = undefined;
        const extra_headers: []const std.http.Header = if (content_type) |ct| blk: {
            headers_buf[0] = .{ .name = "content-type", .value = ct };
            break :blk headers_buf[0..1];
        } else &.{};

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = http_method,
            .payload = body,
            .extra_headers = extra_headers,
            .response_writer = &body_writer.writer,
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = try body_writer.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
};

test "http client: joinUrl" {
    const a = std.testing.allocator;
    var c = try HttpClient.init(a, "http://example.com/api");
    defer c.deinit();
    const joined = try c.joinUrl("/v1");
    defer a.free(joined);
    try std.testing.expectEqualStrings("http://example.com/api/v1", joined);
    const abs = try c.joinUrl("http://other/x");
    defer a.free(abs);
    try std.testing.expectEqualStrings("http://other/x", abs);
}
