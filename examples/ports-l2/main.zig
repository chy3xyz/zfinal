//! L2 ports demo — DI via `app.setState` + store/cache/bus ports.
//!
//! ```
//! zig build run-ports-l2
//! curl -X POST localhost:8088/orders -d '{"id":"o1","sku":"A"}'
//! curl localhost:8088/orders/o1
//! ```
//!
//! Scaffold: `zf g port store|cache|bus` · See doc/progressive_architecture.md

const std = @import("std");
const zfinal = @import("zfinal");

const MemoryStore = @import("adapters/memory_store.zig").MemoryStore;
const MemoryCache = @import("adapters/memory_cache.zig").MemoryCache;
const MemoryBus = @import("adapters/memory_bus.zig").MemoryBus;
const OrdersService = @import("service/orders.zig").OrdersService;

const AppState = struct {
    orders: *OrdersService,
};

fn placeHandler(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);
    if (body.len == 0) return error.BadRequest;
    const id = try ctx.getParaDefault("id", "demo");
    try st.orders.placeOrder(ctx.allocator, id, body);
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn getHandler(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const id = try zfinal.extract.requireParam(ctx, "id");
    const row = try st.orders.getOrder(ctx.allocator, id);
    if (row) |r| {
        defer ctx.allocator.free(r);
        try ctx.renderText(r);
    } else {
        return error.NotFound;
    }
}

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    var store_a = MemoryStore{ .allocator = allocator };
    defer store_a.deinit();
    var cache_a = MemoryCache{ .allocator = allocator };
    defer cache_a.deinit();
    var bus_a = MemoryBus.init(allocator);
    defer bus_a.deinit();

    var orders: OrdersService = .{
        .store = store_a.port(),
        .cache = cache_a.port(),
        .bus = bus_a.port(),
    };
    var app_state: AppState = .{ .orders = &orders };

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{ .port = 8088 });
    app.setState(AppState, &app_state);

    try app.post("/orders", placeHandler);
    try app.get("/orders/:id", getHandler);
    try app.get("/health", struct {
        fn h(ctx: *zfinal.Context) !void {
            try ctx.renderJson(.{ .status = "ok", .demo = "ports-l2" });
        }
    }.h);
    try app.setFallback(struct {
        fn h(_: *zfinal.Context) !void {
            return error.NotFound;
        }
    }.h);

    std.log.info("ports-l2 listening on :8088 (setState + store/cache/bus)", .{});
    try app.start();
}
