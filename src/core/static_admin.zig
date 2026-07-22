//! StaticAdmin — single-binary admin UI deployment.
//!
//! Embeds the generated admin HTML files (zf admin output) into the
//! binary at compile time via @embedFile, producing a single static
//! binary that runs anywhere — no config files, no CDN, no external
//! HTTP dependencies.
//!
//! ## Build
//!
//! 1. Generate the admin HTML:
//!    zf admin schema.sql --out public/
//!
//! 2. Add to your build.zig:
//!    const exe_mod = ...
//!    exe_mod.addAnonymousImport("admin_public_root", .{
//!        .root_source_file = .{ .cwd_relative = "public" },
//!    });
//!    Or just use @embedFile directly from your main.zig.
//!
//! 3. In your main.zig:
//!    const admin = zfinal.StaticAdmin(.{ .users = @embedFile("public/users/admin.html"), ... });
//!    try app.get("/users", admin.serve("users"));
//!
//! 4. zig build -Doptimize=ReleaseSafe → one binary, 5–8 MB with SQLite.

const std = @import("std");
const Context = @import("context.zig").Context;

/// Types for compile-time admin configuration.
pub const AdminTable = struct {
    name: []const u8,
    html: []const u8, // @embedFile("public/users/admin.html")
};

/// Generic static file server for embedded content.
/// Usage:
///   const f = zfinal.StaticFile{ .content = @embedFile("path") };
///   try app.get("/path", f.handler());
///
/// Supports HTTP `ETag` + `If-None-Match` for client-side caching:
/// when the client sends `If-None-Match: <etag>` and it matches the
/// file's etag, the handler responds with 304 (Not Modified) and no
/// body — saving ~100% of the response bandwidth for repeat visits.
pub const StaticFile = struct {
    content: []const u8,
    mime: []const u8,
    /// Optional explicit ETag (e.g. "v1.2.3"). If null, derived from
    /// a hash of `content` at handler-creation time.
    etag: ?[]const u8 = null,

    /// Compute a weak ETag from content length + first/last 8 bytes
    /// (FNV-1a 64-bit). Cheap and stable across builds — clients see
    /// the same etag for the same embedded content.
    fn computeEtag(content: []const u8) [18]u8 {
        var hash: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
        const step = if (content.len > 64) content.len / 32 else 1;
        var i: usize = 0;
        while (i < content.len) : (i += step) {
            hash ^= @as(u64, content[i]);
            hash = hash *% 0x100000001b3;
        }
        // Mix length in so different-size identical-prefix contents differ.
        hash ^= @as(u64, content.len);
        hash = hash *% 0x100000001b3;
        var buf: [18]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "W/\"{x:0>16}\"", .{hash}) catch "\"x\"";
        return buf;
    }

    pub fn handler(_: *const StaticFile) *const fn (*Context) anyerror!void {
        return struct {
            fn h(ctx: *Context) !void {
                const sf: *const StaticFile = @fieldParentPtr("h", @This());
                // Compute etag on each request — cheap (FNV-1a on
                // sampled bytes) and avoids lifetime issues with a
                // captured buffer going out of scope.
                var etag_buf: [18]u8 = undefined;
                const etag_slice: []const u8 = if (sf.etag) |e| e else blk: {
                    etag_buf = sf.computeEtag(sf.content);
                    break :blk &etag_buf;
                };
                // Always advertise the etag so clients can cache.
                try ctx.setHeader("ETag", etag_slice);
                // Honor client cache: If-None-Match → 304.
                if (ctx.getHeader("If-None-Match")) |inm| {
                    if (std.mem.eql(u8, inm, etag_slice) or
                        std.mem.eql(u8, inm, "*"))
                    {
                        ctx.res_status = .not_modified;
                        return;
                    }
                }
                try ctx.renderHtml(sf.content);
            }
        }.h;
    }
};

/// Build a map of table name → admin HTML content.
/// Takes a tuple of AdminTable.
pub fn Map(comptime tables: anytype) type {
    return struct {
        /// Serve the admin HTML for a specific table.
        pub fn serve(comptime name: []const u8) *const fn (*Context) anyerror!void {
            return struct {
                fn h(ctx: *Context) !void {
                    inline for (tables) |entry| {
                        if (std.mem.eql(u8, entry.name, name)) {
                            try ctx.renderHtml(entry.html);
                            return;
                        }
                    }
                    ctx.res_status = .not_found;
                    try ctx.renderJson(.{ .@"error" = "table not found" });
                }
            }.h;
        }
    };
}

/// Convenience: generate the Map from a pre-defined table list at comptime.
pub fn initMap(comptime table_names: []const []const u8, comptime admin_html_dir: []const u8) type {
    // Cannot do dynamic file I/O at comptime in Zig 0.17.
    // Instead, user calls @embedFile manually per table and uses Map directly.
    _ = table_names;
    _ = admin_html_dir;
    @compileError("Use StaticAdmin.Map with explicit @embedFile per table, e.g. \n  const admin = StaticAdmin.Map(&.{\n    .{.name = \"users\", .html = @embedFile(\"public/users/admin.html\")},\n    ...\n  });");
}

/// Serve a public/index.html style landing page from embedded content.
pub fn serveIndex(comptime html: []const u8) *const fn (*Context) anyerror!void {
    return struct {
        fn h(ctx: *Context) !void {
            try ctx.renderHtml(html);
        }
    }.h;
}
