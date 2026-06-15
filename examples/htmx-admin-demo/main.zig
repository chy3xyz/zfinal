//! htmx-admin-demo — runnable multi-table admin demo.
//! zig build run-htmx-admin-demo → http://localhost:8080/

const std = @import("std");
const zfinal = @import("zfinal");

fn health(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .framework = "zfinal" });
}

fn index(ctx: *zfinal.Context) !void {
    try ctx.renderHtml(
        \\<!DOCTYPE html>
        \\<html lang="zh"><head><meta charset="UTF-8"><title>ZFinal Admin Demo</title>
        \\<script src="https://cdn.tailwindcss.com"></script>
        \\</head><body class="bg-gray-50 min-h-screen p-8">
        \\<div class="max-w-2xl mx-auto bg-white rounded shadow p-6">
        \\  <h1 class="text-2xl font-bold text-gray-800 mb-2">ZFinal Admin Demo</h1>
        \\  <p class="text-sm text-gray-600 mb-4">3 tables · vben-style admin · Alpine + HTMX</p>
        \\  <ul class="space-y-2">
        \\    <li><a href="/admin/users" class="text-blue-600 hover:underline font-medium">📋 Users</a></li>
        \\    <li><a href="/admin/posts" class="text-blue-600 hover:underline font-medium">📝 Posts</a></li>
        \\    <li><a href="/admin/comments" class="text-blue-600 hover:underline font-medium">💬 Comments</a></li>
        \\  </ul>
        \\</div></body></html>
    );
}

fn adminHandler(ctx: *zfinal.Context) !void {
    const a = ctx.allocator;
    const io = zfinal.io_instance.io;
    const table = ctx.getPathParam("table") orelse "users";
    const path = try std.fmt.allocPrint(a, "public/{s}/admin.html", .{table});
    defer a.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        try ctx.renderHtml("404 — run `zf admin examples/htmx-admin-demo/schema.sql --out public` first");
        return;
    };
    defer file.close(io);
    const st = try file.stat(io);
    const buf = try a.alloc(u8, @intCast(st.size));
    defer a.free(buf);
    const chunks = [_][]u8{buf};
    _ = try file.readStreaming(io, &chunks);
    try ctx.renderHtml(buf);
}

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setPort(8080);

    try app.get("/", index);
    try app.get("/health", health);
    try app.get("/admin/:table", adminHandler);

    std.debug.print("\nZFinal Admin Demo on :8080\n", .{});
    std.debug.print("  http://localhost:8080/\n", .{});
    std.debug.print("  http://localhost:8080/admin/users\n", .{});
    std.debug.print("  http://localhost:8080/admin/posts\n", .{});
    std.debug.print("  http://localhost:8080/admin/comments\n", .{});
    try app.start();
}
