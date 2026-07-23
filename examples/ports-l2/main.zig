//! L2 ports demo — DI via store/cache/bus ports + memory adapters.
//!
//! ```
//! zig build run-ports-l2
//! curl -X POST localhost:8088/orders -d '{"id":"o1","sku":"A"}'
//! curl localhost:8088/orders/o1
//! ```
//!
//! Scaffold the same layout with: `zf g port store|cache|bus`
//! See doc/progressive_architecture.md

const std = @import("std");
const zfinal = @import("zfinal");

const MemoryStore = @import("adapters/memory_store.zig").MemoryStore;
const MemoryCache = @import("adapters/memory_cache.zig").MemoryCache;
const MemoryBus = @import("adapters/memory_bus.zig").MemoryBus;
const OrdersService = @import("service/orders.zig").OrdersService;

var g_orders: OrdersService = undefined;

fn placeHandler(ctx: *zfinal.Context) !void {
    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);
    if (body.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "empty body" });
        return;
    }
    const id = try ctx.getParaDefault("id", "demo");
    try g_orders.placeOrder(ctx.allocator, id, body);
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn getHandler(ctx: *zfinal.Context) !void {
    const id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "missing id" });
        return;
    };
    const row = try g_orders.getOrder(ctx.allocator, id);
    if (row) |r| {
        defer ctx.allocator.free(r);
        try ctx.renderText(r);
    } else {
        ctx.res_status = .not_found;
        try ctx.renderJson(.{ .err = "not found" });
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

    g_orders = .{
        .store = store_a.port(),
        .cache = cache_a.port(),
        .bus = bus_a.port(),
    };

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{ .port = 8088 });

    try app.post("/orders", placeHandler);
    try app.get("/orders/:id", getHandler);
    try app.get("/health", struct {
        fn h(ctx: *zfinal.Context) !void {
            try ctx.renderJson(.{ .status = "ok", .demo = "ports-l2" });
        }
    }.h);

    std.log.info("ports-l2 listening on :8088 (store+cache+bus DI)", .{});
    try app.start();
}
