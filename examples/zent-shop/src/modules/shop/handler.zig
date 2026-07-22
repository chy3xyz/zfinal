const std = @import("std");
const zfinal = @import("zfinal");
const service = @import("service.zig");

/// Set from main before routes run.
pub var g_svc: ?*service.ShopService = null;

fn svcOrErr(ctx: *zfinal.Context) !*service.ShopService {
    _ = ctx;
    return g_svc orelse error.ServiceNotReady;
}

pub fn register(app: *zfinal.ZFinal) !void {
    var api = zfinal.RouteGroup.init(app, "/api/v1");
    _ = try api.post("/users", createUser);
    _ = try api.post("/products", createProduct);
    _ = try api.get("/products", listProducts);
    _ = try api.post("/follows", createFollow);
    _ = try api.get("/follows", listFollows);
    _ = try api.post("/posts", createPost);
    _ = try api.get("/posts", listPosts);
}

fn createUser(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const name = try ctx.getPara("name") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing name" });
        return;
    };
    const handle = try ctx.getPara("handle") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing handle" });
        return;
    };
    const id = svc.createUser(name, handle) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn createProduct(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const seller_id = try ctx.getParaToLong("seller_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing seller_id" });
        return;
    };
    const name = try ctx.getPara("name") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing name" });
        return;
    };
    const price = try ctx.getParaToLongDefault("price_cents", 0);
    const stock = try ctx.getParaToLongDefault("stock", 0);
    const id = svc.createProduct(seller_id, name, price, stock) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn listProducts(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const seller_id = try ctx.getParaToLong("seller_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing seller_id" });
        return;
    };
    const rows = svc.listProducts(seller_id) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    defer svc.freeProducts(rows);

    var list: std.ArrayList(struct {
        id: i64,
        seller_id: i64,
        name: []const u8,
        price_cents: i64,
        stock: i64,
    }) = .empty;
    defer list.deinit(ctx.allocator);
    for (rows) |r| {
        try list.append(ctx.allocator, .{
            .id = r.id,
            .seller_id = r.seller_id,
            .name = r.name,
            .price_cents = r.price_cents,
            .stock = r.stock,
        });
    }
    try ctx.renderJson(.{ .ok = true, .products = list.items });
}

fn createFollow(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const follower_id = try ctx.getParaToLong("follower_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing follower_id" });
        return;
    };
    const followee_id = try ctx.getParaToLong("followee_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing followee_id" });
        return;
    };
    const id = svc.follow(follower_id, followee_id) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn listFollows(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const follower_id = try ctx.getParaToLong("follower_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing follower_id" });
        return;
    };
    const rows = svc.listFollowing(follower_id) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    defer svc.freeFollows(rows);
    try ctx.renderJson(.{ .ok = true, .follows = rows });
}

fn createPost(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const author_id = try ctx.getParaToLong("author_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing author_id" });
        return;
    };
    const body = try ctx.getPara("body") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing body" });
        return;
    };
    const id = svc.createPost(author_id, body) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    try ctx.renderJson(.{ .ok = true, .id = id });
}

fn listPosts(ctx: *zfinal.Context) !void {
    const svc = try svcOrErr(ctx);
    const author_id = try ctx.getParaToLong("author_id") orelse {
        try ctx.renderJson(.{ .ok = false, .error_msg = "Missing author_id" });
        return;
    };
    const rows = svc.listPosts(author_id) catch |err| {
        try ctx.renderJson(.{ .ok = false, .error_msg = @errorName(err) });
        return;
    };
    defer svc.freePosts(rows);

    var list: std.ArrayList(struct { id: i64, author_id: i64, body: []const u8 }) = .empty;
    defer list.deinit(ctx.allocator);
    for (rows) |r| {
        try list.append(ctx.allocator, .{ .id = r.id, .author_id = r.author_id, .body = r.body });
    }
    try ctx.renderJson(.{ .ok = true, .posts = list.items });
}
