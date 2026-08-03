//! REST envelope helpers: `{ ok, data, error }`.
const std = @import("std");
const zfinal = @import("zfinal");

pub fn ok(ctx: *zfinal.Context, data: anytype) !void {
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .ok = true, .data = data, .@"error" = null });
}

/// `{ ok, data, error, meta }` — additive pagination metadata without breaking
/// clients that read `data` (P1: todo list pagination).
pub fn okMeta(ctx: *zfinal.Context, data: anytype, meta: anytype) !void {
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .ok = true, .data = data, .@"error" = null, .meta = meta });
}

pub fn okEmpty(ctx: *zfinal.Context) !void {
    ctx.res_status = .ok;
    try ctx.renderJson(.{ .ok = true, .data = null, .@"error" = null });
}

pub fn err(ctx: *zfinal.Context, status: std.http.Status, message: []const u8) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .ok = false, .data = null, .@"error" = message });
}
