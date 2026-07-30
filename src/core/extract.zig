//! Lightweight request extractors (Axum-inspired). Return `HttpError` on failure;
//! `Server.dispatch` maps them to JSON envelopes.
const std = @import("std");
const Context = @import("context.zig").Context;
const http_error = @import("http_error.zig");
const HttpError = http_error.HttpError;
const tenant = @import("tenant.zig");

/// Require a path parameter (`:id`, etc.).
pub fn requireParam(ctx: *Context, name: []const u8) HttpError![]const u8 {
    return ctx.param(name) orelse {
        http_error.setDetail(ctx, name);
        return error.BadRequest;
    };
}

/// Parse path param as `T` (integer types).
pub fn requireParamInt(ctx: *Context, comptime T: type, name: []const u8) HttpError!T {
    const raw = try requireParam(ctx, name);
    return std.fmt.parseInt(T, raw, 10) catch {
        http_error.setDetail(ctx, name);
        return error.BadRequest;
    };
}

/// Optional query (or form) parameter.
pub fn optionalQuery(ctx: *Context, name: []const u8) HttpError!?[]const u8 {
    return ctx.getPara(name) catch {
        return error.BadRequest;
    };
}

/// Require query/form parameter.
pub fn requireQuery(ctx: *Context, name: []const u8) HttpError![]const u8 {
    const v = try optionalQuery(ctx, name);
    return v orelse {
        http_error.setDetail(ctx, name);
        return error.BadRequest;
    };
}

/// Parse JSON body into `T`. Caller owns `Parsed(T)` and must `.deinit()`.
pub fn jsonBody(ctx: *Context, comptime T: type) HttpError!std.json.Parsed(T) {
    return ctx.parseJsonBody(T) catch {
        http_error.setDetail(ctx, "json");
        return error.BadRequest;
    };
}

/// Require `Authorization: Bearer …` token value (without the Bearer prefix).
pub fn bearerToken(ctx: *Context) HttpError![]const u8 {
    const hdr = ctx.getHeader("Authorization") orelse {
        http_error.setDetail(ctx, "Authorization");
        return error.Unauthorized;
    };
    const prefix = "Bearer ";
    if (hdr.len <= prefix.len or !std.ascii.eqlIgnoreCase(hdr[0..prefix.len], prefix)) {
        http_error.setDetail(ctx, "Authorization");
        return error.Unauthorized;
    }
    const tok = std.mem.trim(u8, hdr[prefix.len..], " \t");
    if (tok.len == 0) {
        http_error.setDetail(ctx, "Authorization");
        return error.Unauthorized;
    }
    return tok;
}

/// Resolve tenant / app shard key using a **comptime** `tenant.Config`.
/// Order: attr → header → query/form (`field_name`) → path param (`field_name`).
pub fn requireTenant(ctx: *Context, comptime cfg: tenant.Config) HttpError![]const u8 {
    if (comptime cfg.attr_name != null) {
        if (ctx.getAttr(cfg.attr_name.?)) |v| {
            if (v.len > 0) return v;
        }
    }
    if (ctx.getHeader(cfg.header_name)) |v| {
        const t = std.mem.trim(u8, v, " \t");
        if (t.len > 0) return t;
    }
    if (try optionalQuery(ctx, cfg.field_name)) |v| {
        if (v.len > 0) return v;
    }
    if (ctx.param(cfg.field_name)) |v| {
        if (v.len > 0) return v;
    }
    http_error.setDetail(ctx, cfg.field_name);
    return error.BadRequest;
}

/// `requireTenant(ctx, .tenant_id)`.
pub fn requireTenantId(ctx: *Context) HttpError![]const u8 {
    return requireTenant(ctx, tenant.tenant_id);
}

/// `requireTenant(ctx, .app_id)` (ZigShop-style).
pub fn requireAppId(ctx: *Context) HttpError![]const u8 {
    return requireTenant(ctx, tenant.app_id);
}

test "requireParam missing sets BadRequest" {
    const testing = std.testing;
    var attrs = std.StringHashMap([]const u8).init(testing.allocator);
    defer attrs.deinit();
    var headers = std.StringHashMap([]const u8).init(testing.allocator);
    defer headers.deinit();
    var path_params = std.StringHashMap([]const u8).init(testing.allocator);
    defer {
        var it = path_params.iterator();
        while (it.next()) |e| {
            testing.allocator.free(e.key_ptr.*);
            testing.allocator.free(e.value_ptr.*);
        }
        path_params.deinit();
    }
    try path_params.put(try testing.allocator.dupe(u8, "id"), try testing.allocator.dupe(u8, "42"));

    var ctx: Context = .{
        .req = undefined,
        .allocator = testing.allocator,
        .attributes = attrs,
        .response_cookies = .empty,
        .response_headers = headers,
        .path_params = path_params,
    };
    const id = try requireParam(&ctx, "id");
    try testing.expectEqualStrings("42", id);
    const missing = requireParam(&ctx, "nope");
    try testing.expectError(error.BadRequest, missing);
}
