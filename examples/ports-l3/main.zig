//! L3 ports demo — tenant header + outbox + store/cache/bus DI.
//!
//! ```
//! zig build run-ports-l3
//! curl -X POST localhost:8089/orders -H 'X-Tenant-Id: acme' -d '{"id":"o1","sku":"A"}'
//! curl localhost:8089/orders/o1 -H 'X-Tenant-Id: acme'
//! ```
//!
//! See doc/progressive_architecture.md (L3)

const std = @import("std");
const zfinal = @import("zfinal");

const MemoryStore = @import("adapters/memory_store.zig").MemoryStore;
const MemoryCache = @import("adapters/memory_cache.zig").MemoryCache;
const MemoryBus = @import("adapters/memory_bus.zig").MemoryBus;
const MemoryOutbox = @import("adapters/memory_outbox.zig").MemoryOutbox;
const OrdersService = @import("service/orders.zig").OrdersService;

var g_orders: OrdersService = undefined;

fn tenantFromHeader(ctx: *zfinal.Context) ?[]const u8 {
    return ctx.getHeader("X-Tenant-Id");
}

fn placeHandler(ctx: *zfinal.Context) !void {
    const tenant = tenantFromHeader(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "missing X-Tenant-Id" });
        return;
    };
    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);
    if (body.len == 0) {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "empty body" });
        return;
    }
    const order_id = try ctx.getParaDefault("id", "demo");
    const idem = try ctx.getParaDefault("idempotency_key", order_id);
    try g_orders.placeOrder(ctx.allocator, tenant, order_id, idem, body);
    try ctx.renderJson(.{ .ok = true, .tenant = tenant, .id = order_id });
}

fn getHandler(ctx: *zfinal.Context) !void {
    const tenant = tenantFromHeader(ctx) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "missing X-Tenant-Id" });
        return;
    };
    const id = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderJson(.{ .err = "missing id" });
        return;
    };
    const row = try g_orders.getOrder(ctx.allocator, tenant, id);
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
    var outbox_a = MemoryOutbox{ .allocator = allocator };
    defer outbox_a.deinit();

    g_orders = .{
        .store = store_a.port(),
        .cache = cache_a.port(),
        .bus = bus_a.port(),
        .outbox = outbox_a.port(),
    };

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{ .port = 8089 });

    try app.post("/orders", placeHandler);
    try app.get("/orders/:id", getHandler);
    try app.get("/health", struct {
        fn h(ctx: *zfinal.Context) !void {
            try ctx.renderJson(.{ .status = "ok", .demo = "ports-l3" });
        }
    }.h);

    std.log.info("ports-l3 listening on :8089 (tenant + outbox + bus)", .{});
    try app.start();
}
