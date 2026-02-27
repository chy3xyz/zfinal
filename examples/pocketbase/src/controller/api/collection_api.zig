const std = @import("std");
const zfinal = @import("zfinal");
const State = @import("../../state.zig");
const Collection = @import("../../model/collection.zig").Collection;

/// Helper to get global DB
fn getDb() *zfinal.DB {
    return State.global_state.?.db;
}

/// List all collections (tables)
pub fn list(ctx: *zfinal.Context) !void {
    const db = getDb();

    const collections = try Collection.listAll(db, ctx.allocator);
    defer {
        for (collections) |col| {
            ctx.allocator.free(col);
        }
        ctx.allocator.free(collections);
    }

    try ctx.renderJson(.{
        .collections = collections,
        .total = collections.len,
    });
}
