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
pub const StaticFile = struct {
    content: []const u8,
    mime: []const u8,

    pub fn handler(self: *const StaticFile) *const fn (*Context) anyerror!void {
        return struct {
            fn h(ctx: *Context) !void {
                const sf: *const StaticFile = @fieldParentPtr("h", @This());
                _ = sf;
                try ctx.renderHtml(self.content);
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
