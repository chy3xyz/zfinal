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
    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    try output.print(ctx.allocator, "{{\"error\":\"{s}\",\"code\":{d}}}", .{ error_msg, code });
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

    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "SELECT * FROM {s} ORDER BY created_at DESC LIMIT {d} OFFSET {d}", .{ collection_name, per_page, offset_val }, 0);
    defer ctx.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    try output.appendSlice(ctx.allocator, "{\"items\":[");

    var first = true;
    while (rs.next()) {
        if (!first) try output.appendSlice(ctx.allocator, ",");
        first = false;
        const row = rs.getCurrentRowMap().?;
        try output.appendSlice(ctx.allocator, "{");
        var first_col = true;
        for (rs.columns) |col_name| {
            if (!first_col) try output.appendSlice(ctx.allocator, ",");
            first_col = false;
            try output.print(ctx.allocator, "\"{s}\":", .{col_name});
            if (row.get(col_name)) |val| {
                try output.print(ctx.allocator, "\"{s}\"", .{val});
            } else {
                try output.appendSlice(ctx.allocator, "null");
            }
        }
        try output.appendSlice(ctx.allocator, "}");
    }

    try output.appendSlice(ctx.allocator, "]}");
    try sendJson(ctx, output.items);
}

pub fn get(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "SELECT * FROM {s} WHERE id = '{s}' LIMIT 1", .{ collection_name, id }, 0);
    defer ctx.allocator.free(sql);

    var rs = try db.query(sql);
    defer rs.deinit();

    if (!rs.next()) {
        return sendError(ctx, .not_found, "Record not found", 404);
    }

    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    const row = rs.getCurrentRowMap().?;
    try output.appendSlice(ctx.allocator, "{");
    var first = true;
    for (rs.columns) |col_name| {
        if (!first) try output.appendSlice(ctx.allocator, ",");
        first = false;
        try output.print(ctx.allocator, "\"{s}\":", .{col_name});
        if (row.get(col_name)) |val| {
            try output.print(ctx.allocator, "\"{s}\"", .{val});
        } else {
            try output.appendSlice(ctx.allocator, "null");
        }
    }
    try output.appendSlice(ctx.allocator, "}");
    try sendJson(ctx, output.items);
}

pub fn create(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    var body_buffer = std.ArrayList(u8).empty;
    defer body_buffer.deinit(ctx.allocator);
    var req_reader_buf: [4096]u8 = undefined;
    var reader = ctx.req.readerExpectNone(&req_reader_buf);
    try reader.appendRemaining(ctx.allocator, &body_buffer, .limited(10 * 1024 * 1024)); // 10MB limit

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body_buffer.items, .{}) catch {
        return sendError(ctx, .bad_request, "Invalid JSON payload", 400);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return sendError(ctx, .bad_request, "Expected JSON object", 400);
    }

    var random_bytes: [16]u8 = undefined;
    zfinal.io_instance.io.random(&random_bytes);
    var id_buf: [32]u8 = undefined;
    const new_id = std.fmt.bufPrint(&id_buf, "{s}", .{std.fmt.bytesToHex(&random_bytes, .lower)}) catch "error";
    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();

    var fields_query = std.ArrayList(u8).empty;
    defer fields_query.deinit(ctx.allocator);
    var values_query = std.ArrayList(u8).empty;
    defer values_query.deinit(ctx.allocator);

    try fields_query.appendSlice(ctx.allocator, "id, created_at, updated_at");
    try values_query.print(ctx.allocator, "'{s}', {d}, {d}", .{ new_id, now, now });

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!isValidCollectionName(key)) continue;

        try fields_query.print(ctx.allocator, ", {s}", .{key});

        switch (entry.value_ptr.*) {
            .string => |s| {
                var escaped = std.ArrayList(u8).empty;
                defer escaped.deinit(ctx.allocator);
                for (s) |c| {
                    if (c == '\'') {
                        try escaped.appendSlice(ctx.allocator, "''");
                    } else {
                        try escaped.append(ctx.allocator, c);
                    }
                }
                try values_query.print(ctx.allocator, ", '{s}'", .{escaped.items});
            },
            .integer => |i| {
                try values_query.print(ctx.allocator, ", {d}", .{i});
            },
            .float => |f| {
                try values_query.print(ctx.allocator, ", {d}", .{f});
            },
            .bool => |b| {
                const b_val: u8 = if (b) 1 else 0;
                try values_query.print(ctx.allocator, ", {d}", .{b_val});
            },
            .null => {
                try values_query.print(ctx.allocator, ", NULL", .{});
            },
            else => {
                try values_query.print(ctx.allocator, ", NULL", .{});
            },
        }
    }

    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "INSERT INTO {s} ({s}) VALUES ({s})", .{ collection_name, fields_query.items, values_query.items }, 0);
    defer ctx.allocator.free(sql);

    db.exec(sql) catch |err| {
        std.debug.print("Insert error: {}\nSQL: {s}\n", .{ err, sql });
        return sendError(ctx, .internal_server_error, "Failed to create record", 500);
    };

    ctx.res_status = .created;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    try output.print(ctx.allocator, "{{\"id\":\"{s}\",\"message\":\"Record created successfully\"}}", .{new_id});
    try sendJson(ctx, output.items);
}

pub fn update(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    var body_buffer = std.ArrayList(u8).empty;
    defer body_buffer.deinit(ctx.allocator);
    var req_reader_buf: [4096]u8 = undefined;
    var reader = ctx.req.readerExpectNone(&req_reader_buf);
    try reader.appendRemaining(ctx.allocator, &body_buffer, .limited(10 * 1024 * 1024)); // 10MB limit

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body_buffer.items, .{}) catch {
        return sendError(ctx, .bad_request, "Invalid JSON payload", 400);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return sendError(ctx, .bad_request, "Expected JSON object", 400);
    }

    const now = std.Io.Timestamp.now(zfinal.io_instance.io, .real).toSeconds();
    var set_query = std.ArrayList(u8).empty;
    defer set_query.deinit(ctx.allocator);

    try set_query.print(ctx.allocator, "updated_at = {d}", .{now});

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!isValidCollectionName(key) or std.mem.eql(u8, key, "id")) continue;

        try set_query.print(ctx.allocator, ", {s} = ", .{key});

        switch (entry.value_ptr.*) {
            .string => |s| {
                var escaped = std.ArrayList(u8).empty;
                defer escaped.deinit(ctx.allocator);
                for (s) |c| {
                    if (c == '\'') {
                        try escaped.appendSlice(ctx.allocator, "''");
                    } else {
                        try escaped.append(ctx.allocator, c);
                    }
                }
                try set_query.print(ctx.allocator, "'{s}'", .{escaped.items});
            },
            .integer => |i| {
                try set_query.print(ctx.allocator, "{d}", .{i});
            },
            .float => |f| {
                try set_query.print(ctx.allocator, "{d}", .{f});
            },
            .bool => |b| {
                const b_val: u8 = if (b) 1 else 0;
                try set_query.print(ctx.allocator, "{d}", .{b_val});
            },
            .null => {
                try set_query.print(ctx.allocator, "NULL", .{});
            },
            else => {
                try set_query.print(ctx.allocator, "NULL", .{});
            },
        }
    }

    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "UPDATE {s} SET {s} WHERE id = '{s}'", .{ collection_name, set_query.items, id }, 0);
    defer ctx.allocator.free(sql);

    db.exec(sql) catch |err| {
        std.debug.print("Update error: {}\nSQL: {s}\n", .{ err, sql });
        return sendError(ctx, .internal_server_error, "Failed to update record", 500);
    };

    ctx.res_status = .ok;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    try output.print(ctx.allocator, "{{\"id\":\"{s}\",\"message\":\"Record updated successfully\"}}", .{id});
    try sendJson(ctx, output.items);
}

pub fn delete(ctx: *zfinal.Context) !void {
    const collection_name = ctx.getPathParam("name") orelse return sendError(ctx, .bad_request, "Missing collection name", 400);
    const id = ctx.getPathParam("id") orelse return sendError(ctx, .bad_request, "Missing record ID", 400);
    if (!isValidCollectionName(collection_name)) return sendError(ctx, .bad_request, "Invalid collection name", 400);

    const db = getDb();

    const sql = try std.fmt.allocPrintSentinel(ctx.allocator, "DELETE FROM {s} WHERE id = '{s}'", .{ collection_name, id }, 0);
    defer ctx.allocator.free(sql);
    try db.exec(sql);

    ctx.res_status = .ok;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(ctx.allocator);
    try output.print(ctx.allocator, "{{\"id\":\"{s}\",\"message\":\"Record deleted\"}}", .{id});
    try sendJson(ctx, output.items);
}
