//! ZFinal HTTP + zent schema-as-code demo (e-commerce catalog + social follows/posts).
//!
//! Uses peer data layer: `const zent = zfinal.zent;`
//!
//! Run:
//!   cd examples/zent-shop && zig build run
//!   zig build run-zent-shop

const std = @import("std");
const zfinal = @import("zfinal");
const zent = zfinal.zent; // peer data layer to zfinal.DB / Model

const persist = @import("modules/shop/persistence.zig");
const service = @import("modules/shop/service.zig");
const handler = @import("modules/shop/handler.zig");
const routes = @import("modules/shop/routes.zig");

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    const sqlite_path = if (std.c.getenv("ZENT_SQLITE")) |p| std.mem.span(p) else "zent-shop.db";
    var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, sqlite_path);
    defer drv.close();
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), persist.infos);
    std.log.info("[zent] migrated schema at {s}", .{sqlite_path});

    var store = persist.ShopStore.init(allocator, drv.asDriver());
    var svc = service.ShopService.init(&store);
    handler.g_svc = &svc;

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    const port: u16 = blk: {
        if (std.c.getenv("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, std.mem.span(p), 10) catch 18200;
        }
        break :blk 18200;
    };
    app.setPort(port);

    try app.get("/health", health);
    try routes.register(&app);

    std.log.info("[zent-shop] listening http://127.0.0.1:{d}", .{port});
    std.log.info("[zent-shop] POST /api/v1/users?name=&handle=&email=", .{});
    std.log.info("[zent-shop] POST /api/v1/products?seller_id=&name=&price_cents=&stock=", .{});
    std.log.info("[zent-shop] POST /api/v1/cartItems?user_id=&product_id=&qty=", .{});
    std.log.info("[zent-shop] POST /api/v1/orders/checkout?user_id=  (tx: cart→order, stock--)", .{});
    std.log.info("[zent-shop] POST /api/v1/follows?follower_id=&followee_id=  (dedup)", .{});
    std.log.info("[zent-shop] POST /api/v1/likes?user_id=&post_id=  (dedup)", .{});
    std.log.info("[zent-shop] POST /api/v1/posts?author_id=&body=", .{});
    try app.start();
}

fn health(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{ .status = "UP", .stack = "zfinal+zent" });
}
