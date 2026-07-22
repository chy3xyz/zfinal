const std = @import("std");
const persist = @import("persistence.zig");

pub const ShopService = struct {
    store: *persist.ShopStore,

    pub fn init(store: *persist.ShopStore) ShopService {
        return .{ .store = store };
    }

    pub fn createUser(self: *ShopService, name: []const u8, handle: []const u8) !i64 {
        if (name.len == 0 or handle.len == 0) return error.InvalidInput;
        return try self.store.createUser(name, handle);
    }

    pub fn createProduct(self: *ShopService, seller_id: i64, name: []const u8, price_cents: i64, stock: i64) !i64 {
        if (seller_id <= 0 or name.len == 0 or price_cents < 0 or stock < 0) return error.InvalidInput;
        return try self.store.createProduct(seller_id, name, price_cents, stock);
    }

    pub fn follow(self: *ShopService, follower_id: i64, followee_id: i64) !i64 {
        if (follower_id <= 0 or followee_id <= 0 or follower_id == followee_id) return error.InvalidInput;
        return try self.store.follow(follower_id, followee_id);
    }

    pub fn createPost(self: *ShopService, author_id: i64, body: []const u8) !i64 {
        if (author_id <= 0 or body.len == 0) return error.InvalidInput;
        return try self.store.createPost(author_id, body);
    }

    pub fn listProducts(self: *ShopService, seller_id: i64) ![]persist.ShopStore.ProductRow {
        if (seller_id <= 0) return error.InvalidInput;
        return try self.store.listProductsBySeller(seller_id);
    }

    pub fn freeProducts(self: *ShopService, rows: []persist.ShopStore.ProductRow) void {
        self.store.freeProducts(rows);
    }

    pub fn listPosts(self: *ShopService, author_id: i64) ![]persist.ShopStore.PostRow {
        if (author_id <= 0) return error.InvalidInput;
        return try self.store.listPostsByAuthor(author_id);
    }

    pub fn freePosts(self: *ShopService, rows: []persist.ShopStore.PostRow) void {
        self.store.freePosts(rows);
    }

    pub fn listFollowing(self: *ShopService, follower_id: i64) ![]persist.ShopStore.FollowRow {
        if (follower_id <= 0) return error.InvalidInput;
        return try self.store.listFollowing(follower_id);
    }

    pub fn freeFollows(self: *ShopService, rows: []persist.ShopStore.FollowRow) void {
        self.store.freeFollows(rows);
    }
};
