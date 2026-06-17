//! standalone-admin — single-binary ZFinal admin deployment.
//! All admin HTML embedded at compile time. One binary, zero deps.
//!
//! Build: zig build run-standalone-admin
//! Deploy: scp zig-out/bin/standalone-admin user@vps:/opt/app/

const std = @import("std");
const zfinal = @import("zfinal");

const admin_users = @embedFile("public/users/admin.html");
const admin_posts = @embedFile("public/posts/admin.html");
const admin_comments = @embedFile("public/comments/admin.html");

const admin_map = zfinal.StaticAdmin.Map(.{
    zfinal.StaticAdmin.AdminTable{ .name = "users", .html = admin_users },
    zfinal.StaticAdmin.AdminTable{ .name = "posts", .html = admin_posts },
    zfinal.StaticAdmin.AdminTable{ .name = "comments", .html = admin_comments },
});

const index_html =
    \\<!DOCTYPE html>
    \\<html lang="zh"><head><meta charset="UTF-8"><title>ZFinal Admin</title>
    \\<script src="https://cdn.tailwindcss.com"></script>
    \\</head><body class="bg-gray-50 min-h-screen p-8">
    \\<div class="max-w-2xl mx-auto bg-white rounded shadow p-6">
    \\  <h1 class="text-2xl font-bold text-gray-800 mb-2">ZFinal Standalone Admin</h1>
    \\  <p class="text-sm text-gray-600 mb-4">Single binary — all HTML @embedFile at build time</p>
    \\  <ul class="space-y-2">
    \\    <li><a href="/admin/users" class="text-blue-600 hover:underline font-medium">Users</a></li>
    \\    <li><a href="/admin/posts" class="text-blue-600 hover:underline font-medium">Posts</a></li>
    \\    <li><a href="/admin/comments" class="text-blue-600 hover:underline font-medium">Comments</a></li>
    \\  </ul>
    \\</div></body></html>
;

fn health(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .mode = "standalone" });
}

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setPort(8080);

    try app.get("/", zfinal.StaticAdmin.serveIndex(index_html));
    try app.get("/health", health);
    try app.get("/admin/users", admin_map.serve("users"));
    try app.get("/admin/posts", admin_map.serve("posts"));
    try app.get("/admin/comments", admin_map.serve("comments"));

    std.debug.print("\nZFinal Standalone on :8080\n", .{});
    try app.start();
}
