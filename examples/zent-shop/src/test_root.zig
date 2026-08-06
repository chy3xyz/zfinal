//! zent-shop domain integration tests (SQLite in-memory, service-level).
//!
//! Run: `zig build test-zent-shop` (from the repo root).
//! Covers: @unique dedup, composite-unique Follow/Like dedup, transactional
//! checkout (stock decrement / cart clear / rollback), QueryEdge feed,
//! data_scope row-level security (own orders only).
const std = @import("std");
const zfinal = @import("zfinal");
const zent = zfinal.zent;

const persist = @import("modules/shop/persistence.zig");
const service = @import("modules/shop/service.zig");

/// Open an in-memory driver and migrate the shop schema.
/// NOTE: `asDriver()` points at the caller's instance, so the returned driver
/// must outlive any Store/Service built from it (keep it on the test stack).
fn setupDrv() !zent.sql_sqlite.SQLiteDriver {
    const a = std.testing.allocator;
    var drv = try zent.sql_sqlite.SQLiteDriver.open(a, ":memory:");
    errdefer drv.close();
    try zent.sql_schema.migrateSchema(a, drv.asDriver(), persist.infos);
    return drv;
}

test "zent-shop: unique handle/email dedup" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    try std.testing.expect(alice > 0);
    try std.testing.expectError(error.Duplicate, svc.createUser("A2", "alice", "b@x.com"));
    try std.testing.expectError(error.Duplicate, svc.createUser("A3", "bob", "a@x.com"));
}

test "zent-shop: transactional checkout (stock--, cart cleared, rollback)" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    const bob = try svc.createUser("Bob", "bob", "b@x.com");
    const pid = try svc.createProduct(1, "Widget", 1000, 5);

    // cart → order
    _ = try store.createCartItem(bob, pid, 2);
    const order_id = try svc.checkout(bob);
    try std.testing.expect(order_id > 0);

    // stock decremented, cart cleared
    const prod = (try store.getProductById(pid)).?;
    defer store.freeProduct(prod);
    try std.testing.expectEqual(@as(i64, 3), prod.stock);
    const cart = try store.listCartItemByUserId(bob, 0, 0);
    defer store.freeCartItems(cart.rows);
    try std.testing.expectEqual(@as(usize, 0), cart.rows.len);

    // insufficient stock → whole tx rolls back (no order, stock untouched)
    _ = try store.createCartItem(alice, pid, 99);
    try std.testing.expectError(error.InsufficientStock, svc.checkout(alice));
    const prod2 = (try store.getProductById(pid)).?;
    defer store.freeProduct(prod2);
    try std.testing.expectEqual(@as(i64, 3), prod2.stock); // unchanged after rollback
    const cart2 = try store.listCartItemByUserId(alice, 0, 0);
    defer store.freeCartItems(cart2.rows);
    try std.testing.expectEqual(@as(usize, 1), cart2.rows.len); // cart kept on failure
}

test "zent-shop: follow/like composite-unique dedup" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    const bob = try svc.createUser("Bob", "bob", "b@x.com");
    const post_id = try svc.createPost(bob, "hello-social");

    _ = try svc.createFollow(alice, bob);
    try std.testing.expectError(error.Duplicate, svc.createFollow(alice, bob));
    try std.testing.expectError(error.InvalidInput, svc.createFollow(alice, alice));

    _ = try svc.createLike(alice, post_id);
    try std.testing.expectError(error.Duplicate, svc.createLike(alice, post_id));
}

test "zent-shop: feed uses QueryEdge batch author load" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    const bob = try svc.createUser("Bob", "bob", "b@x.com");
    _ = try svc.createFollow(alice, bob);
    _ = try svc.createPost(bob, "post-1");
    _ = try svc.createPost(bob, "post-2");

    const feed = try svc.feed(alice, 10);
    defer svc.freeFeed(feed);
    try std.testing.expectEqual(@as(usize, 2), feed.len);
    try std.testing.expectEqualStrings("bob", feed[0].author_handle); // newest first
    try std.testing.expectEqualStrings("post-2", feed[0].body);
}

test "zent-shop: data_scope row-level security (own orders only)" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    const bob = try svc.createUser("Bob", "bob", "b@x.com");
    const pid = try svc.createProduct(1, "Widget", 1000, 10);
    _ = try store.createCartItem(alice, pid, 1);
    _ = try store.createCartItem(bob, pid, 2);
    _ = try svc.checkout(alice);
    _ = try svc.checkout(bob);

    const mine = try svc.listMyOrders(alice);
    defer svc.freeScopedOrders(mine);
    try std.testing.expectEqual(@as(usize, 1), mine.len);
    try std.testing.expectEqual(alice, mine[0].buyer_id);

    const bob_orders = try svc.listMyOrders(bob);
    defer svc.freeScopedOrders(bob_orders);
    try std.testing.expectEqual(@as(usize, 1), bob_orders.len);
    try std.testing.expectEqual(bob, bob_orders[0].buyer_id);
}

test "zent-shop: loginByHandle resolves user (JWT auth path)" {
    const a = std.testing.allocator;
    var drv = try setupDrv();
    defer drv.close();
    var store = persist.ShopStore.init(a, drv.asDriver());
    var svc = service.ShopService.init(&store);

    const alice = try svc.createUser("Alice", "alice", "a@x.com");
    try std.testing.expectEqual(alice, try svc.loginByHandle("alice"));
    try std.testing.expectError(error.UserNotFound, svc.loginByHandle("nobody"));
}
