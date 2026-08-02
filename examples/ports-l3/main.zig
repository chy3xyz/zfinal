//! L3 ports demo — comptime `app_id` + setState + outbox + bus.
//! Bus default: `zfinal.MemoryBus`. Swap to `NatsBus` / `RobustMQBus` (doc/bus.md).
//!
//! ```
//! zig build run-ports-l3
//! curl -X POST localhost:8089/orders -H 'X-App-Id: acme' -d '{"id":"o1","sku":"A"}'
//! curl localhost:8089/orders/o1 -H 'X-App-Id: acme'
//! ```

const std = @import("std");
const zfinal = @import("zfinal");

const MemoryStore = @import("adapters/memory_store.zig").MemoryStore;
const MemoryCache = @import("adapters/memory_cache.zig").MemoryCache;
const MemoryBus = @import("adapters/memory_bus.zig").MemoryBus;
const MemoryOutbox = @import("adapters/memory_outbox.zig").MemoryOutbox;
const OrdersService = @import("service/orders.zig").OrdersService;

const AppState = struct {
    orders: *OrdersService,
};

fn placeHandler(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const tenant = try zfinal.extract.requireTenant(ctx, zfinal.tenant.app_id);
    const body = try ctx.getBodyText();
    defer ctx.allocator.free(body);
    if (body.len == 0) return error.BadRequest;
    const order_id = try ctx.getParaDefault("id", "demo");
    const idem = try ctx.getParaDefault("idempotency_key", order_id);
    try st.orders.placeOrder(ctx.allocator, tenant, order_id, idem, body);
    try ctx.renderJson(.{ .ok = true, .app_id = tenant, .id = order_id });
}

fn getHandler(ctx: *zfinal.Context) !void {
    const st = try ctx.state(AppState);
    const tenant = try zfinal.extract.requireAppId(ctx);
    const id = try zfinal.extract.requireParam(ctx, "id");
    const row = try st.orders.getOrder(ctx.allocator, tenant, id);
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

    var store_a = zfinal.MemoryStore.init(allocator);
    defer store_a.deinit();
    var cache_a = zfinal.MemoryCache.init(allocator);
    defer cache_a.deinit();
    var bus_a = MemoryBus.init(allocator);
    defer bus_a.deinit();
    var outbox_a = zfinal.MemoryOutbox.init(allocator);
    defer outbox_a.deinit();

    var orders: OrdersService = .{
        .store = store_a.port(),
        .cache = cache_a.port(),
        .bus = bus_a.port(),
        .outbox = outbox_a.port(),
    };
    var app_state: AppState = .{ .orders = &orders };

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    app.setConfig(.{ .port = 8089 });
    app.setState(AppState, &app_state);

    try app.addGlobalInterceptor(zfinal.stock.createTraceInterceptor());
    try app.post("/orders", placeHandler);
    try app.get("/orders/:id", getHandler);
    try app.get("/health", struct {
        fn h(ctx: *zfinal.Context) !void {
            try ctx.renderJson(.{ .status = "ok", .demo = "ports-l3", .tenant_field = zfinal.tenant.app_id.field_name });
        }
    }.h);

    std.log.info("ports-l3 listening on :8089 (setState + comptime app_id + trace)", .{});
    try app.start();
}
