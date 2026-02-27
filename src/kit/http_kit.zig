const std = @import("std");

/// HTTP 工具类
pub const HttpKit = struct {
    /// 常见 MIME 类型
    pub const MimeType = struct {
        pub const html = "text/html; charset=utf-8";
        pub const json = "application/json; charset=utf-8";
        pub const xml = "application/xml; charset=utf-8";
        pub const text = "text/plain; charset=utf-8";
        pub const css = "text/css; charset=utf-8";
        pub const javascript = "application/javascript; charset=utf-8";
        pub const png = "image/png";
        pub const jpg = "image/jpeg";
        pub const gif = "image/gif";
        pub const svg = "image/svg+xml";
        pub const pdf = "application/pdf";
        pub const zip = "application/zip";
    };

    /// 根据文件扩展名获取 MIME 类型
    pub fn getMimeType(ext: []const u8) []const u8 {
        const lower = std.ascii.allocLowerString(std.heap.page_allocator, ext) catch return MimeType.text;
        defer std.heap.page_allocator.free(lower);

        if (std.mem.eql(u8, lower, "html") or std.mem.eql(u8, lower, "htm")) return MimeType.html;
        if (std.mem.eql(u8, lower, "json")) return MimeType.json;
        if (std.mem.eql(u8, lower, "xml")) return MimeType.xml;
        if (std.mem.eql(u8, lower, "txt")) return MimeType.text;
        if (std.mem.eql(u8, lower, "css")) return MimeType.css;
        if (std.mem.eql(u8, lower, "js")) return MimeType.javascript;
        if (std.mem.eql(u8, lower, "png")) return MimeType.png;
        if (std.mem.eql(u8, lower, "jpg") or std.mem.eql(u8, lower, "jpeg")) return MimeType.jpg;
        if (std.mem.eql(u8, lower, "gif")) return MimeType.gif;
        if (std.mem.eql(u8, lower, "svg")) return MimeType.svg;
        if (std.mem.eql(u8, lower, "pdf")) return MimeType.pdf;
        if (std.mem.eql(u8, lower, "zip")) return MimeType.zip;

        return MimeType.text;
    }

    /// HTTP 状态码描述
    pub fn getStatusText(status_code: u16) []const u8 {
        return switch (status_code) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }

    /// 解析 User-Agent
    pub fn parseUserAgent(ua: []const u8) UserAgent {
        return UserAgent{
            .is_mobile = std.mem.indexOf(u8, ua, "Mobile") != null or
                std.mem.indexOf(u8, ua, "Android") != null or
                std.mem.indexOf(u8, ua, "iPhone") != null,
            .is_bot = std.mem.indexOf(u8, ua, "bot") != null or
                std.mem.indexOf(u8, ua, "crawler") != null or
                std.mem.indexOf(u8, ua, "spider") != null,
            .browser = detectBrowser(ua),
        };
    }

    fn detectBrowser(ua: []const u8) []const u8 {
        if (std.mem.indexOf(u8, ua, "Chrome") != null) return "Chrome";
        if (std.mem.indexOf(u8, ua, "Firefox") != null) return "Firefox";
        if (std.mem.indexOf(u8, ua, "Safari") != null) return "Safari";
        if (std.mem.indexOf(u8, ua, "Edge") != null) return "Edge";
        return "Unknown";
    }

    pub const UserAgent = struct {
        is_mobile: bool,
        is_bot: bool,
        browser: []const u8,
    };
};

test "HttpKit getMimeType" {
    try std.testing.expectEqualStrings(HttpKit.MimeType.json, HttpKit.getMimeType("json"));
    try std.testing.expectEqualStrings(HttpKit.MimeType.html, HttpKit.getMimeType("html"));
}

test "HttpKit getStatusText" {
    try std.testing.expectEqualStrings("OK", HttpKit.getStatusText(200));
    try std.testing.expectEqualStrings("Not Found", HttpKit.getStatusText(404));
}
