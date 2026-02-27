const std = @import("std");
const zfinal = @import("zfinal");
const State = @import("../../state.zig");

fn getDb() *zfinal.DB {
    return State.global_state.?.db;
}

fn sendJson(ctx: *zfinal.Context, json_str: []const u8) !void {
    ctx.res_status = .ok;
    try ctx.setHeader("Content-Type", "application/json");
    try ctx.renderText(json_str);
}

fn sendError(ctx: *zfinal.Context, status: std.http.Status, error_msg: []const u8, code: u32) !void {
    ctx.res_status = status;
    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    try output.writer().print("{{\"error\":\"{s}\",\"code\":{d}}}", .{ error_msg, code });
    try sendJson(ctx, output.items);
}

fn isValidCollectionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const is_valid = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!is_valid) return false;
    }
    return true;
}

pub fn list(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const page = try ctx.getParaToIntDefault("page", 1);
    const per_page = try ctx.getParaToIntDefault("per_page", 20);
    const offset_val = (page - 1) * per_page;

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "SELECT * FROM {s} ORDER BY created_at DESC LIMIT {d} OFFSET {d}", .{ collection_name, per_page, offset_val });
    defer ctx.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    try output.writer().writeAll("{\"items\":[");

    var first = true;
    while (rs.next()) {
        if (!first) try output.writer().writeAll(",");
        first = false;
        const row = rs.getCurrentRowMap().?;
        try output.writer().writeAll("{");
        var first_col = true;
        for (rs.columns) |col_name| {
            if (!first_col) try output.writer().writeAll(",");
            first_col = false;
            try output.writer().print("\"{s}\":", .{col_name});
            if (row.get(col_name)) |val| {
                try output.writer().print("\"{s}\"", .{val});
            } else {
                try output.writer().writeAll("null");
            }
        }
        try output.writer().writeAll("}");
    }

    try output.writer().writeAll("]}");
    try sendJson(ctx, output.items);
}

pub fn get(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "SELECT * FROM {s} WHERE id = '{s}' LIMIT 1", .{ collection_name, id });
    defer ctx.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    if (!rs.next()) {
        return sendError(ctx, .not_found, "Record not found", 404);
    }

    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    const row = rs.getCurrentRowMap().?;
    try output.writer().writeAll("{");
    var first = true;
    for (rs.columns) |col_name| {
        if (!first) try output.writer().writeAll(",");
        first = false;
        try output.writer().print("\"{s}\":", .{col_name});
        if (row.get(col_name)) |val| {
            try output.writer().print("\"{s}\"", .{val});
        } else {
            try output.writer().writeAll("null");
        }
    }
    try output.writer().writeAll("}");
    try sendJson(ctx, output.items);
}

pub fn create(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    var id_buf: [32]u8 = undefined;
    const new_id = std.fmt.bufPrint(&id_buf, "{s}", .{std.fmt.fmtSliceHexLower(&random_bytes)}) catch "error";
    const now = std.time.timestamp();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "INSERT INTO {s} (id, created_at) VALUES ('{s}', {d})", .{ collection_name, new_id, now });
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    ctx.res_status = .created;
    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    try output.writer().print("{{\"id\":\"{s}\",\"message\":\"Record created\"}}", .{new_id});
    try sendJson(ctx, output.items);
}

pub fn update(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const now = std.time.timestamp();
    const sql = try std.fmt.allocPrintZ(ctx.allocator, "UPDATE {s} SET updated_at = {d} WHERE id = '{s}'", .{ collection_name, now, id });
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    ctx.res_status = .ok;
    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    try output.writer().print("{{\"id\":\"{s}\",\"message\":\"Record updated\"}}", .{id});
    try sendJson(ctx, output.items);
}

pub fn delete(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const sql = try std.fmt.allocPrintZ(ctx.allocator, "DELETE FROM {s} WHERE id = '{s}'", .{ collection_name, id });
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    ctx.res_status = .ok;
    var output = std.ArrayList(u8).init(ctx.allocator);
    defer output.deinit();
    try output.writer().print("{{\"id\":\"{s}\",\"message\":\"Record deleted\"}}", .{id});
    try sendJson(ctx, output.items);
}
