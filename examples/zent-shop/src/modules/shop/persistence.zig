//! Persistence over zent Client — SQL stays inside zent builders.
const std = @import("std");
const zent = @import("zfinal").zent;
const model = @import("model.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.User, model.Product, model.Follow, model.Post });
pub const infos = graph.types;
pub const Client = zent.codegen.client.Client(infos);
const UserInfo = infos[0];
const ProductInfo = infos[1];
const FollowInfo = infos[2];
const PostInfo = infos[3];

pub const ShopStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, driver: zent.sql_driver.Driver) ShopStore {
        return .{
            .allocator = allocator,
            .client = zent.codegen.client.makeClient(infos, allocator, driver),
        };
    }

    pub fn createUser(self: *ShopStore, name: []const u8, handle: []const u8) !i64 {
        var b = try self.client.user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("handle", handle);
        const row = try b.Save();
        return row.id;
    }

    pub fn createProduct(self: *ShopStore, seller_id: i64, name: []const u8, price_cents: i64, stock: i64) !i64 {
        var b = try self.client.product.Create();
        defer b.deinit();
        _ = try b.setFieldValue("seller_id", seller_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("price_cents", price_cents);
        _ = try b.setFieldValue("stock", stock);
        const row = try b.Save();
        return row.id;
    }

    pub fn follow(self: *ShopStore, follower_id: i64, followee_id: i64) !i64 {
        var b = try self.client.follow.Create();
        defer b.deinit();
        _ = try b.setFieldValue("follower_id", follower_id);
        _ = try b.setFieldValue("followee_id", followee_id);
        const row = try b.Save();
        return row.id;
    }

    pub fn createPost(self: *ShopStore, author_id: i64, body: []const u8) !i64 {
        var b = try self.client.post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("author_id", author_id);
        _ = try b.setFieldValue("body", body);
        const row = try b.Save();
        return row.id;
    }

    pub const ProductRow = struct {
        id: i64,
        seller_id: i64,
        name: []const u8,
        price_cents: i64,
        stock: i64,
    };

    pub const PostRow = struct {
        id: i64,
        author_id: i64,
        body: []const u8,
    };

    pub const FollowRow = struct {
        id: i64,
        follower_id: i64,
        followee_id: i64,
    };

    /// Caller owns returned slice + each `name`. Free with `freeProducts`.
    pub fn listProductsBySeller(self: *ShopStore, seller_id: i64) ![]ProductRow {
        var q = self.client.product.Query();
        defer q.deinit();
        const preds = self.client.product.predicates;
        _ = try q.Where(.{preds.seller_idEQ(.{ .int = seller_id })});
        var found = try q.All();
        defer {
            for (found.items) |*p| {
                zent.codegen.deinitEntity(infos, ProductInfo, p, self.allocator);
            }
            found.deinit();
        }

        var out = try self.allocator.alloc(ProductRow, found.items.len);
        errdefer self.allocator.free(out);
        for (found.items, 0..) |p, i| {
            out[i] = .{
                .id = p.id,
                .seller_id = p.seller_id,
                .name = try self.allocator.dupe(u8, p.name),
                .price_cents = p.price_cents,
                .stock = p.stock,
            };
        }
        return out;
    }

    pub fn freeProducts(self: *ShopStore, rows: []ProductRow) void {
        for (rows) |r| self.allocator.free(r.name);
        self.allocator.free(rows);
    }

    pub fn listPostsByAuthor(self: *ShopStore, author_id: i64) ![]PostRow {
        var q = self.client.post.Query();
        defer q.deinit();
        const preds = self.client.post.predicates;
        _ = try q.Where(.{preds.author_idEQ(.{ .int = author_id })});
        var found = try q.All();
        defer {
            for (found.items) |*p| {
                zent.codegen.deinitEntity(infos, PostInfo, p, self.allocator);
            }
            found.deinit();
        }

        var out = try self.allocator.alloc(PostRow, found.items.len);
        errdefer self.allocator.free(out);
        for (found.items, 0..) |p, i| {
            out[i] = .{
                .id = p.id,
                .author_id = p.author_id,
                .body = try self.allocator.dupe(u8, p.body),
            };
        }
        return out;
    }

    pub fn freePosts(self: *ShopStore, rows: []PostRow) void {
        for (rows) |r| self.allocator.free(r.body);
        self.allocator.free(rows);
    }

    pub fn listFollowing(self: *ShopStore, follower_id: i64) ![]FollowRow {
        var q = self.client.follow.Query();
        defer q.deinit();
        const preds = self.client.follow.predicates;
        _ = try q.Where(.{preds.follower_idEQ(.{ .int = follower_id })});
        var found = try q.All();
        defer {
            for (found.items) |*f| {
                zent.codegen.deinitEntity(infos, FollowInfo, f, self.allocator);
            }
            found.deinit();
        }

        var out = try self.allocator.alloc(FollowRow, found.items.len);
        errdefer self.allocator.free(out);
        for (found.items, 0..) |f, i| {
            out[i] = .{
                .id = f.id,
                .follower_id = f.follower_id,
                .followee_id = f.followee_id,
            };
        }
        return out;
    }

    pub fn freeFollows(self: *ShopStore, rows: []FollowRow) void {
        self.allocator.free(rows);
    }

    // silence unused if codegen renames
    comptime {
        _ = UserInfo;
    }
};
