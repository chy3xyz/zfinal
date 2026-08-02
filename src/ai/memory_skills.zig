//! Memory skills: let an Agent remember / recall / forget facts via tools.
//! Set `SkillContext.userdata = *MemoryStore` (or use `MemorySkillCtx`).

const std = @import("std");
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const MemoryStore = @import("memory.zig").MemoryStore;

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

fn strArg(args: std.json.Value, name: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn storeFrom(ctx: *SkillContext) !*MemoryStore {
    return @ptrCast(@alignCast(ctx.userdata orelse return error.MemoryNotConfigured));
}

pub fn registerMemorySkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "memory_remember",
        .description = "Store a fact under a key for this tenant/user",
        .parameters = &.{
            .{ .name = "key", .type = .string, .description = "Logical key", .required = true },
            .{ .name = "value", .type = .string, .description = "Value to store", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const store = try storeFrom(ctx);
                const key = strArg(args, "key") orelse return error.InvalidArguments;
                const value = strArg(args, "value") orelse return error.InvalidArguments;
                try store.remember(key, value, ctx.tenant_id orelse 0, ctx.user_id orelse 0);
                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, ctx.allocator, "key", .{ .string = try ctx.allocator.dupe(u8, key) });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "memory_get",
        .description = "Get a single memory value by key",
        .parameters = &.{
            .{ .name = "key", .type = .string, .description = "Logical key", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const store = try storeFrom(ctx);
                const key = strArg(args, "key") orelse return error.InvalidArguments;
                const val = try store.get(ctx.allocator, key, ctx.tenant_id orelse 0, ctx.user_id orelse 0);
                var out = std.json.ObjectMap{};
                if (val) |v| {
                    try putOwned(&out, ctx.allocator, "found", .{ .bool = true });
                    try putOwned(&out, ctx.allocator, "value", .{ .string = v });
                } else {
                    try putOwned(&out, ctx.allocator, "found", .{ .bool = false });
                }
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "memory_recall",
        .description = "List memories whose key starts with the given prefix (empty = all for tenant/user)",
        .parameters = &.{
            .{ .name = "prefix", .type = .string, .description = "Key prefix (optional)", .required = false },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const store = try storeFrom(ctx);
                const prefix = strArg(args, "prefix") orelse "";
                var hits = try store.recall(ctx.allocator, prefix, ctx.tenant_id orelse 0, ctx.user_id orelse 0);
                defer {
                    for (hits.items) |e| {
                        ctx.allocator.free(e.key);
                        ctx.allocator.free(e.value);
                    }
                    hits.deinit(ctx.allocator);
                }
                var arr = std.json.Array.init(ctx.allocator);
                for (hits.items) |e| {
                    var obj = std.json.ObjectMap{};
                    try putOwned(&obj, ctx.allocator, "key", .{ .string = try ctx.allocator.dupe(u8, e.key) });
                    try putOwned(&obj, ctx.allocator, "value", .{ .string = try ctx.allocator.dupe(u8, e.value) });
                    try arr.append(.{ .object = obj });
                }
                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "hits", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "memory_forget",
        .description = "Delete a memory key",
        .parameters = &.{
            .{ .name = "key", .type = .string, .description = "Logical key", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const store = try storeFrom(ctx);
                const key = strArg(args, "key") orelse return error.InvalidArguments;
                store.forget(key, ctx.tenant_id orelse 0, ctx.user_id orelse 0);
                var out = std.json.ObjectMap{};
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                return .{ .object = out };
            }
        }.h,
    });
}

test "memory skills remember and get" {
    const allocator = std.testing.allocator;
    var store = MemoryStore.init(allocator, std.testing.io);
    defer store.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerMemorySkills(&registry);

    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&store), .tenant_id = 1, .user_id = 2 };
    var args = std.json.ObjectMap{};
    defer args.deinit(allocator);
    try args.put(allocator, "key", .{ .string = "lang" });
    try args.put(allocator, "value", .{ .string = "zh" });
    const r1 = try registry.dispatch("memory_remember", &ctx, .{ .object = args });
    defer @import("skill.zig").freeValue(allocator, r1);

    var gargs = std.json.ObjectMap{};
    defer gargs.deinit(allocator);
    try gargs.put(allocator, "key", .{ .string = "lang" });
    const r2 = try registry.dispatch("memory_get", &ctx, .{ .object = gargs });
    defer @import("skill.zig").freeValue(allocator, r2);
    try std.testing.expect(r2 == .object);
    try std.testing.expect(r2.object.get("found").?.bool);
    try std.testing.expectEqualStrings("zh", r2.object.get("value").?.string);
}
