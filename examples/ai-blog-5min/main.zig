// examples/ai-blog-5min/main.zig
// ──────────────────────────────────────────────────────────────
// 5-Minute AI Speedrun: blog API in Zig + ZFinal.
//
// The schema is the source of truth (see schema.sql). Run:
//
//   zf crud:sql schema.sql --json     # generate model/service/handler/routes
//   # ... edit inside the ai-edit-zone markers ...
//   zig build run-ai-blog-5min        # boot the server
//
// This main.zig is the runtime shell. The generated routes are
// registered from src/modules/manifest.gen.zig (created by zf).
// Until you run `zf crud:sql`, only the hand-written /health route
// below is live.
// ──────────────────────────────────────────────────────────────

const std = @import("std");
const zfinal = @import("zfinal");

fn health(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "ok", .example = "ai-blog-5min" });
}

fn banner(ctx: *zfinal.Context) !void {
    try ctx.renderText("ai-blog-5min — see /health; run `zf crud:sql schema.sql` to generate /users and /posts CRUD");
}

pub fn main(init: std.process.Init) !void {
    @import("zfinal").io_instance.init(init);
    const allocator = init.gpa;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    try app.addRoute("/", banner);
    try app.addRoute("/health", health);

    std.debug.print("ai-blog-5min on :8080\n", .{});
    std.debug.print("  GET  /         banner\n", .{});
    std.debug.print("  GET  /health   liveness\n", .{});
    std.debug.print("  Next: zf crud:sql schema.sql --json (regenerate /users, /posts)\n", .{});
    try app.start();
}
