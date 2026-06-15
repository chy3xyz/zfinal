// examples/htmx-admin/main.zig
// ──────────────────────────────────────────────────────────────
// vben-style admin UI demo. Run:
//
//   zf admin schema.sql --out examples/htmx-admin/public
//   zig build run-htmx-admin
//
// Then open http://localhost:8080/admin
// ──────────────────────────────────────────────────────────────

const std = @import("std");
const zfinal = @import("zfinal");

fn homeHandler(ctx: *zfinal.Context) !void {
    try ctx.renderHtml(
        \\<!DOCTYPE html>
        \\<html><body>
        \\<h1>ZFinal Admin Demo</h1>
        \\<p>Run <code>zf admin schema.sql --out examples/htmx-admin/public</code> first.</p>
        \\<p>Then visit <a href="/admin">/admin</a> to see the vben-style admin UI.</p>
        \\</body></html>
    );
}

fn adminHandler(ctx: *zfinal.Context) !void {
    // Read the generated admin.html
    const allocator = ctx.allocator;
    const io = zfinal.io_instance.io;

    var file = try std.Io.Dir.cwd().openFile(io, "examples/htmx-admin/public/admin.html", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(buf);
    const chunks = [_][]u8{buf};
    _ = try file.readStreaming(io, &chunks);

    try ctx.renderHtml(buf);
}

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.addRoute("/", homeHandler);
    try app.addRoute("/admin", adminHandler);

    std.debug.print("htmx-admin listening on :8080\n", .{});
    std.debug.print("  http://localhost:8080/      (banner)\n", .{});
    std.debug.print("  http://localhost:8080/admin (vben-style admin UI)\n", .{});
    try app.start();
}
