//! Tenant / shard-key naming — **comptime** config.
//! Default is `tenant_id`; ZigShop-style apps use `app_id`.
//!
//! ```zig
//! // presets
//! const id = try zfinal.extract.requireTenant(ctx, .app_id);
//! const id = try zfinal.extract.requireAppId(ctx);
//!
//! // custom (still comptime)
//! const StoreKey = zfinal.tenant.Config{
//!     .field_name = "store_id",
//!     .header_name = "X-Store-Id",
//! };
//! const id = try zfinal.extract.requireTenant(ctx, StoreKey);
//! ```
const std = @import("std");

/// Compile-time tenant naming. Pass to `extract.requireTenant(ctx, comptime cfg)`.
pub const Config = struct {
    /// DB column / Zig field / query param name (`tenant_id` or `app_id`).
    field_name: []const u8,
    /// HTTP header when value is not already in attrs (JWT etc.).
    header_name: []const u8,
    /// Optional `ctx` attribute (tried first). `null` = skip attr lookup.
    attr_name: ?[]const u8 = null,
};

/// Classic L3 docs style: `tenant_id` + `X-Tenant-Id`.
pub const tenant_id: Config = .{
    .field_name = "tenant_id",
    .header_name = "X-Tenant-Id",
};

/// ZigShop / multi-storefront style: `app_id` + `X-App-Id` (+ attr `app_id`).
pub const app_id: Config = .{
    .field_name = "app_id",
    .header_name = "X-App-Id",
    .attr_name = "app_id",
};

test "comptime presets" {
    try std.testing.expectEqualStrings("app_id", app_id.field_name);
    try std.testing.expectEqualStrings("X-App-Id", app_id.header_name);
    try std.testing.expectEqualStrings("tenant_id", tenant_id.field_name);
    comptime {
        const cfg: Config = app_id;
        if (!std.mem.eql(u8, cfg.field_name, "app_id")) @compileError("app_id preset broken");
    }
}
