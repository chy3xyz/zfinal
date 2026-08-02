//! MCP client (stdio / injectable transport): initialize, tools/list, tools/call.
//! Supports NDJSON lines and Content-Length framed messages; skips notifications;
//! matches responses by JSON-RPC id. Opt-in only.

const std = @import("std");
const time_util = @import("time_util.zig");

pub const PROTOCOL_VERSION = "2024-11-05";

pub const McpToolInfo = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,

    pub fn deinit(self: McpToolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

pub const McpResourceInfo = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8,

    pub fn deinit(self: McpResourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.mime_type);
    }
};

pub const McpPromptInfo = struct {
    name: []const u8,
    description: []const u8,

    pub fn deinit(self: McpPromptInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

pub const Transport = struct {
    ptr: *anyopaque,
    /// Write one JSON-RPC message (without trailing framing details — transport adds them).
    writeMessageFn: *const fn (ptr: *anyopaque, json: []const u8) anyerror!void,
    /// Read one complete JSON-RPC message body (owned by caller).
    readMessageFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    closeFn: *const fn (ptr: *anyopaque) void,

    pub fn writeMessage(self: Transport, json: []const u8) !void {
        return self.writeMessageFn(self.ptr, json);
    }
    pub fn readMessage(self: Transport, allocator: std.mem.Allocator) ![]u8 {
        return self.readMessageFn(self.ptr, allocator);
    }
    pub fn close(self: Transport) void {
        self.closeFn(self.ptr);
    }
};

/// In-memory fake server for unit tests (scripted response bodies = raw JSON).
pub const FakeTransport = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayList([]u8),
    requests: std.ArrayList([]u8),
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) FakeTransport {
        return .{ .allocator = allocator, .responses = .empty, .requests = .empty };
    }

    pub fn deinit(self: *FakeTransport) void {
        for (self.responses.items) |r| self.allocator.free(r);
        self.responses.deinit(self.allocator);
        for (self.requests.items) |r| self.allocator.free(r);
        self.requests.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enqueueResponse(self: *FakeTransport, json: []const u8) !void {
        try self.responses.append(self.allocator, try self.allocator.dupe(u8, json));
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{
            .ptr = self,
            .writeMessageFn = writeMessage,
            .readMessageFn = readMessage,
            .closeFn = close,
        };
    }

    fn writeMessage(ptr: *anyopaque, json: []const u8) anyerror!void {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.TransportClosed;
        try self.requests.append(self.allocator, try self.allocator.dupe(u8, json));
    }

    fn readMessage(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        if (self.closed) return error.TransportClosed;
        if (self.responses.items.len == 0) return error.NoResponse;
        const line = self.responses.orderedRemove(0);
        defer self.allocator.free(line);
        return try allocator.dupe(u8, line);
    }

    fn close(ptr: *anyopaque) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }
};

pub const CallOpts = struct {
    /// Absolute deadline in ms (monotonic); null = no client-side deadline.
    deadline_ms: ?i64 = null,
};

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    transport: Transport,
    next_id: i64 = 1,
    initialized: bool = false,
    owns_transport_close: bool = true,
    /// Out-of-order JSON-RPC responses keyed by id (owned message bodies).
    pending_by_id: std.AutoHashMap(i64, []u8),

    const max_pending_responses: usize = 32;

    pub fn initWithTransport(allocator: std.mem.Allocator, io: std.Io, transport: Transport) McpClient {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .transport = transport,
            .owns_transport_close = true,
            .pending_by_id = std.AutoHashMap(i64, []u8).init(allocator),
        };
    }

    pub fn start(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !McpClient {
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer {
            child.kill(io);
            _ = child.wait(io) catch {};
        }

        const box = try allocator.create(StdioTransport);
        errdefer allocator.destroy(box);
        box.* = .{ .child = child, .allocator = allocator, .io = io };

        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .transport = box.transport(),
            .owns_transport_close = true,
            .pending_by_id = std.AutoHashMap(i64, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *McpClient) void {
        var it = self.pending_by_id.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.pending_by_id.deinit();
        if (self.owns_transport_close) self.transport.close();
        self.* = undefined;
    }

    pub fn initialize(self: *McpClient) !void {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"");
        try req_buf.appendSlice(self.allocator, PROTOCOL_VERSION);
        try req_buf.appendSlice(self.allocator, "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zfinal\",\"version\":\"0.20\"}}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, null);
        defer self.allocator.free(resp);
        try expectJsonRpcOk(self.allocator, resp, id);

        try self.transport.writeMessage("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
        self.initialized = true;
    }

    /// List all tools, following `nextCursor` until exhausted.
    pub fn listTools(self: *McpClient) ![]McpToolInfo {
        return self.listToolsOpts(.{});
    }

    pub fn listToolsOpts(self: *McpClient, opts: CallOpts) ![]McpToolInfo {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;

        var all = std.ArrayList(McpToolInfo).empty;
        errdefer {
            for (all.items) |t| t.deinit(self.allocator);
            all.deinit(self.allocator);
        }

        var cursor: ?[]const u8 = null;
        defer if (cursor) |c| self.allocator.free(c);

        while (true) {
            try checkDeadline(opts.deadline_ms);

            const id = self.allocId();
            var req_buf = std.ArrayList(u8).empty;
            defer req_buf.deinit(self.allocator);
            try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
            try req_buf.print(self.allocator, "{d}", .{id});
            try req_buf.appendSlice(self.allocator, ",\"method\":\"tools/list\"");
            if (cursor) |c| {
                try req_buf.appendSlice(self.allocator, ",\"params\":{\"cursor\":");
                try appendJsonString(&req_buf, self.allocator, c);
                try req_buf.append(self.allocator, '}');
            }
            try req_buf.append(self.allocator, '}');

            try self.transport.writeMessage(req_buf.items);
            const resp = try self.readMatching(id, opts.deadline_ms);
            defer self.allocator.free(resp);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidResponse;
            if (parsed.value.object.get("error") != null) return error.McpError;
            const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
            if (result != .object) return error.InvalidResponse;
            const tools_val = result.object.get("tools") orelse return error.InvalidResponse;
            if (tools_val != .array) return error.InvalidResponse;

            for (tools_val.array.items) |item| {
                if (item != .object) continue;
                const name = switch (item.object.get("name") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const desc: []const u8 = blk: {
                    if (item.object.get("description")) |d| break :blk switch (d) {
                        .string => |s| s,
                        else => "",
                    };
                    break :blk "";
                };
                const schema_val = item.object.get("inputSchema") orelse item.object.get("input_schema");
                const schema_json = if (schema_val) |sv|
                    try std.json.Stringify.valueAlloc(self.allocator, sv, .{})
                else
                    try self.allocator.dupe(u8, "{}");
                errdefer self.allocator.free(schema_json);
                try all.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .description = try self.allocator.dupe(u8, desc),
                    .input_schema_json = schema_json,
                });
            }

            if (cursor) |c| {
                self.allocator.free(c);
                cursor = null;
            }
            if (result.object.get("nextCursor")) |nc| {
                if (nc == .string and nc.string.len > 0) {
                    cursor = try self.allocator.dupe(u8, nc.string);
                    continue;
                }
            }
            break;
        }
        return try all.toOwnedSlice(self.allocator);
    }

    pub fn freeTools(self: *McpClient, tools: []McpToolInfo) void {
        for (tools) |t| t.deinit(self.allocator);
        self.allocator.free(tools);
    }

    pub fn callTool(self: *McpClient, name: []const u8, arguments: std.json.Value) !std.json.Value {
        return self.callToolOpts(name, arguments, .{});
    }

    pub fn callToolOpts(self: *McpClient, name: []const u8, arguments: std.json.Value, opts: CallOpts) !std.json.Value {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;
        try checkDeadline(opts.deadline_ms);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"tools/call\",\"params\":{\"name\":");
        try appendJsonString(&req_buf, self.allocator, name);
        try req_buf.appendSlice(self.allocator, ",\"arguments\":");
        {
            const args_json = try std.json.Stringify.valueAlloc(self.allocator, arguments, .{});
            defer self.allocator.free(args_json);
            try req_buf.appendSlice(self.allocator, args_json);
        }
        try req_buf.appendSlice(self.allocator, "}}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, opts.deadline_ms);
        defer self.allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.McpError;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        return try extractCallResult(self.allocator, result);
    }

    /// `resources/list` (no pagination in this cut).
    pub fn listResources(self: *McpClient) ![]McpResourceInfo {
        return self.listResourcesOpts(.{});
    }

    pub fn listResourcesOpts(self: *McpClient, opts: CallOpts) ![]McpResourceInfo {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;
        try checkDeadline(opts.deadline_ms);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"resources/list\"}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, opts.deadline_ms);
        defer self.allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.McpError;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result != .object) return error.InvalidResponse;
        const arr = result.object.get("resources") orelse return error.InvalidResponse;
        if (arr != .array) return error.InvalidResponse;

        var out = std.ArrayList(McpResourceInfo).empty;
        errdefer {
            for (out.items) |r| r.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const uri = switch (item.object.get("uri") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const name: []const u8 = blk: {
                if (item.object.get("name")) |n| break :blk switch (n) {
                    .string => |s| s,
                    else => "",
                };
                break :blk "";
            };
            const desc: []const u8 = blk: {
                if (item.object.get("description")) |d| break :blk switch (d) {
                    .string => |s| s,
                    else => "",
                };
                break :blk "";
            };
            const mime: []const u8 = blk: {
                if (item.object.get("mimeType")) |m| break :blk switch (m) {
                    .string => |s| s,
                    else => "",
                };
                break :blk "";
            };
            try out.append(self.allocator, .{
                .uri = try self.allocator.dupe(u8, uri),
                .name = try self.allocator.dupe(u8, name),
                .description = try self.allocator.dupe(u8, desc),
                .mime_type = try self.allocator.dupe(u8, mime),
            });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn freeResources(self: *McpClient, resources: []McpResourceInfo) void {
        for (resources) |r| r.deinit(self.allocator);
        self.allocator.free(resources);
    }

    /// `resources/read` — returns concatenated text contents (owned).
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        return self.readResourceOpts(uri, .{});
    }

    pub fn readResourceOpts(self: *McpClient, uri: []const u8, opts: CallOpts) ![]u8 {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;
        try checkDeadline(opts.deadline_ms);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"resources/read\",\"params\":{\"uri\":");
        try appendJsonString(&req_buf, self.allocator, uri);
        try req_buf.appendSlice(self.allocator, "}}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, opts.deadline_ms);
        defer self.allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.McpError;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result != .object) return error.InvalidResponse;
        const contents = result.object.get("contents") orelse return error.InvalidResponse;
        if (contents != .array) return error.InvalidResponse;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        for (contents.array.items) |part| {
            if (part != .object) continue;
            if (part.object.get("text")) |tx| {
                if (tx == .string) {
                    if (buf.items.len > 0) try buf.append(self.allocator, '\n');
                    try buf.appendSlice(self.allocator, tx.string);
                }
            }
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn listPrompts(self: *McpClient) ![]McpPromptInfo {
        return self.listPromptsOpts(.{});
    }

    pub fn listPromptsOpts(self: *McpClient, opts: CallOpts) ![]McpPromptInfo {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;
        try checkDeadline(opts.deadline_ms);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"prompts/list\"}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, opts.deadline_ms);
        defer self.allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.McpError;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result != .object) return error.InvalidResponse;
        const arr = result.object.get("prompts") orelse return error.InvalidResponse;
        if (arr != .array) return error.InvalidResponse;

        var out = std.ArrayList(McpPromptInfo).empty;
        errdefer {
            for (out.items) |p| p.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const name = switch (item.object.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const desc: []const u8 = blk: {
                if (item.object.get("description")) |d| break :blk switch (d) {
                    .string => |s| s,
                    else => "",
                };
                break :blk "";
            };
            try out.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .description = try self.allocator.dupe(u8, desc),
            });
        }
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn freePrompts(self: *McpClient, prompts: []McpPromptInfo) void {
        for (prompts) |p| p.deinit(self.allocator);
        self.allocator.free(prompts);
    }

    /// `prompts/get` — returns owned JSON string of `messages` array (or full result).
    pub fn getPrompt(self: *McpClient, name: []const u8, arguments: ?std.json.Value) ![]u8 {
        return self.getPromptOpts(name, arguments, .{});
    }

    pub fn getPromptOpts(self: *McpClient, name: []const u8, arguments: ?std.json.Value, opts: CallOpts) ![]u8 {
        self.mutex.lock(self.io) catch return error.McpLockFailed;
        defer self.mutex.unlock(self.io);
        if (!self.initialized) return error.NotInitialized;
        try checkDeadline(opts.deadline_ms);

        const id = self.allocId();
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(self.allocator);
        try req_buf.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try req_buf.print(self.allocator, "{d}", .{id});
        try req_buf.appendSlice(self.allocator, ",\"method\":\"prompts/get\",\"params\":{\"name\":");
        try appendJsonString(&req_buf, self.allocator, name);
        if (arguments) |args| {
            try req_buf.appendSlice(self.allocator, ",\"arguments\":");
            const aj = try std.json.Stringify.valueAlloc(self.allocator, args, .{});
            defer self.allocator.free(aj);
            try req_buf.appendSlice(self.allocator, aj);
        }
        try req_buf.appendSlice(self.allocator, "}}");

        try self.transport.writeMessage(req_buf.items);
        const resp = try self.readMatching(id, opts.deadline_ms);
        defer self.allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;
        if (parsed.value.object.get("error") != null) return error.McpError;
        const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
        if (result == .object) {
            if (result.object.get("messages")) |msgs| {
                return try std.json.Stringify.valueAlloc(self.allocator, msgs, .{});
            }
        }
        return try std.json.Stringify.valueAlloc(self.allocator, result, .{});
    }

    fn allocId(self: *McpClient) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Read messages until one with matching id.
    /// Notifications are skipped; other ids are buffered for later `readMatching`.
    fn readMatching(self: *McpClient, want_id: i64, deadline_ms: ?i64) ![]u8 {
        if (self.pending_by_id.fetchRemove(want_id)) |kv| {
            return kv.value;
        }

        var spins: usize = 0;
        while (spins < 64) : (spins += 1) {
            try checkDeadline(deadline_ms);
            const msg = try self.transport.readMessage(self.allocator);
            errdefer self.allocator.free(msg);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch {
                self.allocator.free(msg);
                continue;
            };
            defer parsed.deinit();
            if (parsed.value != .object) {
                self.allocator.free(msg);
                continue;
            }
            // Notification: has method, no id
            const has_method = parsed.value.object.get("method") != null;
            const id_val = parsed.value.object.get("id");
            if (has_method and id_val == null) {
                self.allocator.free(msg);
                continue;
            }
            if (id_val) |ivid| {
                const got: i64 = switch (ivid) {
                    .integer => |i| i,
                    .float => |f| @intFromFloat(f),
                    else => {
                        self.allocator.free(msg);
                        continue;
                    },
                };
                if (got == want_id) return msg;
                // Buffer for a later request with this id.
                if (self.pending_by_id.count() >= max_pending_responses) {
                    self.allocator.free(msg);
                    continue;
                }
                if (self.pending_by_id.fetchRemove(got)) |old| {
                    self.allocator.free(old.value);
                }
                try self.pending_by_id.put(got, msg);
                continue;
            }
            self.allocator.free(msg);
        }
        return error.ResponseTimeout;
    }
};

fn checkDeadline(deadline_ms: ?i64) !void {
    const d = deadline_ms orelse return;
    if (time_util.nowMillis() > d) return error.ToolTimeout;
}

const StdioTransport = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Owned here so `McpClient.start` return-by-value cannot dangle.
    framing: enum { unknown, ndjson, content_length } = .unknown,
    /// Carry bytes after a Content-Length body or partial NDJSON line.
    carry: std.ArrayList(u8) = .empty,

    fn transport(self: *StdioTransport) Transport {
        return .{
            .ptr = self,
            .writeMessageFn = writeMessage,
            .readMessageFn = readMessage,
            .closeFn = close,
        };
    }

    fn writeMessage(ptr: *anyopaque, json: []const u8) anyerror!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        const stdin = self.child.stdin orelse return error.TransportClosed;
        if (self.framing == .content_length) {
            var hdr_buf: [64]u8 = undefined;
            const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{json.len});
            try std.Io.File.writeStreamingAll(stdin, self.io, hdr);
            try std.Io.File.writeStreamingAll(stdin, self.io, json);
        } else {
            // NDJSON or unknown: line-delimited (many servers accept this for initialize)
            try std.Io.File.writeStreamingAll(stdin, self.io, json);
            try std.Io.File.writeStreamingAll(stdin, self.io, "\n");
        }
    }

    fn readMore(self: *StdioTransport) !usize {
        const stdout = self.child.stdout orelse return error.TransportClosed;
        var chunk: [4096]u8 = undefined;
        const buffers = [_][]u8{chunk[0..]};
        const n = std.Io.File.readStreaming(stdout, self.io, &buffers) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return err,
        };
        if (n > 0) try self.carry.appendSlice(self.allocator, chunk[0..n]);
        return n;
    }

    fn takePrefix(self: *StdioTransport, allocator: std.mem.Allocator, len: usize) ![]u8 {
        const out = try allocator.dupe(u8, self.carry.items[0..len]);
        const remain = self.carry.items[len..];
        const keep = try self.allocator.dupe(u8, remain);
        self.carry.clearRetainingCapacity();
        try self.carry.appendSlice(self.allocator, keep);
        self.allocator.free(keep);
        return out;
    }

    fn readMessage(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));

        while (true) {
            // Content-Length only when header is at the start of the buffer (not mid-JSON).
            if (std.mem.startsWith(u8, self.carry.items, "Content-Length:") or
                std.mem.startsWith(u8, self.carry.items, "content-length:"))
            {
                if (std.mem.indexOf(u8, self.carry.items, "\r\n\r\n")) |hdr_end_rel| {
                    const hdr_end = hdr_end_rel + 4;
                    const hdr = self.carry.items[0..hdr_end];
                    if (parseContentLength(hdr)) |body_len| {
                        while (self.carry.items.len < hdr_end + body_len) {
                            if (try self.readMore() == 0) return error.TransportClosed;
                        }
                        self.framing = .content_length;
                        const body = try allocator.dupe(u8, self.carry.items[hdr_end .. hdr_end + body_len]);
                        errdefer allocator.free(body);
                        const remain = self.carry.items[hdr_end + body_len ..];
                        const keep = try self.allocator.dupe(u8, remain);
                        self.carry.clearRetainingCapacity();
                        try self.carry.appendSlice(self.allocator, keep);
                        self.allocator.free(keep);
                        return body;
                    }
                    // Malformed header: fall through to NDJSON
                } else {
                    if (try self.readMore() == 0) {
                        if (self.carry.items.len == 0) return error.TransportClosed;
                    } else continue;
                }
            }

            // NDJSON line
            if (std.mem.indexOfScalar(u8, self.carry.items, '\n')) |nl| {
                if (self.framing == .unknown) self.framing = .ndjson;
                var end = nl;
                if (end > 0 and self.carry.items[end - 1] == '\r') end -= 1;
                const line = try allocator.dupe(u8, self.carry.items[0..end]);
                const remain = self.carry.items[nl + 1 ..];
                const keep = try self.allocator.dupe(u8, remain);
                self.carry.clearRetainingCapacity();
                try self.carry.appendSlice(self.allocator, keep);
                self.allocator.free(keep);
                if (line.len == 0) {
                    allocator.free(line);
                    continue;
                }
                return line;
            }

            if (try self.readMore() == 0) {
                if (self.carry.items.len == 0) return error.TransportClosed;
                const line = try self.takePrefix(allocator, self.carry.items.len);
                return line;
            }
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        self.carry.deinit(self.allocator);
        if (self.child.stdin) |s| {
            s.close(self.io);
            self.child.stdin = null;
        }
        self.child.kill(self.io);
        _ = self.child.wait(self.io) catch {};
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

fn parseContentLength(hdr: []const u8) ?usize {
    const key = "Content-Length:";
    const idx = std.mem.indexOf(u8, hdr, key) orelse return null;
    var i = idx + key.len;
    while (i < hdr.len and (hdr[i] == ' ' or hdr[i] == '\t')) : (i += 1) {}
    var n: usize = 0;
    while (i < hdr.len and hdr[i] >= '0' and hdr[i] <= '9') : (i += 1) {
        n = n * 10 + (hdr[i] - '0');
    }
    return n;
}

fn expectJsonRpcOk(allocator: std.mem.Allocator, line: []const u8, id: i64) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("error") != null) return error.McpError;
    if (parsed.value.object.get("id")) |ivid| {
        const got: i64 = switch (ivid) {
            .integer => |i| i,
            else => return error.InvalidResponse,
        };
        if (got != id) return error.IdMismatch;
    }
    if (parsed.value.object.get("result") == null) return error.InvalidResponse;
}

fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn extractCallResult(allocator: std.mem.Allocator, result: std.json.Value) !std.json.Value {
    if (result != .object) return try cloneJson(allocator, result);
    if (result.object.get("content")) |content| {
        if (content == .array) {
            var text_buf = std.ArrayList(u8).empty;
            defer text_buf.deinit(allocator);
            for (content.array.items) |part| {
                if (part != .object) continue;
                if (part.object.get("type")) |t| {
                    if (t != .string or !std.mem.eql(u8, t.string, "text")) continue;
                }
                if (part.object.get("text")) |tx| {
                    if (tx == .string) {
                        if (text_buf.items.len > 0) try text_buf.append(allocator, '\n');
                        try text_buf.appendSlice(allocator, tx.string);
                    }
                }
            }
            const joined = try text_buf.toOwnedSlice(allocator);
            if (joined.len > 0 and (joined[0] == '{' or joined[0] == '[')) {
                if (std.json.parseFromSlice(std.json.Value, allocator, joined, .{})) |p| {
                    defer p.deinit();
                    allocator.free(joined);
                    return try cloneJson(allocator, p.value);
                } else |_| {}
            }
            return .{ .string = joined };
        }
    }
    return try cloneJson(allocator, result);
}

fn cloneJson(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            errdefer out.deinit();
            for (arr.items) |item| try out.append(try cloneJson(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = std.json.ObjectMap{};
            errdefer freeJson(allocator, .{ .object = out });
            var it = obj.iterator();
            while (it.next()) |e| {
                try out.put(allocator, try allocator.dupe(u8, e.key_ptr.*), try cloneJson(allocator, e.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

pub fn freeJson(allocator: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            var a = arr;
            for (a.items) |item| freeJson(allocator, item);
            a.deinit();
        },
        .object => |obj| {
            var o = obj;
            var it = o.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                freeJson(allocator, e.value_ptr.*);
            }
            o.deinit(allocator);
        },
        else => {},
    }
}

test "McpClient initialize listTools callTool skips notification" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeTransport.init(allocator);
    defer fake.deinit();

    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"test","version":"1"}}}
    );
    // notification between requests
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info"}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"msg":{"type":"string"}},"required":["msg"]}}],"nextCursor":"p2"}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"ok\":true,\"msg\":\"hi\"}"}]}}
    );

    var client = McpClient.initWithTransport(allocator, io, fake.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }

    try client.initialize();
    const tools = try client.listTools();
    defer client.freeTools(tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);

    var args = std.json.ObjectMap{};
    defer freeJson(allocator, .{ .object = args });
    try args.put(allocator, try allocator.dupe(u8, "msg"), .{ .string = try allocator.dupe(u8, "hi") });
    const result = try client.callTool("echo", .{ .object = args });
    defer freeJson(allocator, result);
    try std.testing.expect(result.object.get("ok").?.bool);
}

test "parseContentLength" {
    try std.testing.expectEqual(@as(?usize, 12), parseContentLength("Content-Length: 12\r\n\r\n"));
}

test "McpClient resources and prompts" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeTransport.init(allocator);
    defer fake.deinit();

    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"t","version":"1"}}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":2,"result":{"resources":[{"uri":"file:///a.txt","name":"a","description":"doc","mimeType":"text/plain"}]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":3,"result":{"contents":[{"uri":"file:///a.txt","mimeType":"text/plain","text":"hello resource"}]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":4,"result":{"prompts":[{"name":"greet","description":"Say hi"}]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":5,"result":{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}]}}
    );

    var client = McpClient.initWithTransport(allocator, io, fake.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }
    try client.initialize();

    const resources = try client.listResources();
    defer client.freeResources(resources);
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualStrings("file:///a.txt", resources[0].uri);

    const text = try client.readResource("file:///a.txt");
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello resource", text);

    const prompts = try client.listPrompts();
    defer client.freePrompts(prompts);
    try std.testing.expectEqual(@as(usize, 1), prompts.len);

    const msgs = try client.getPrompt("greet", null);
    defer allocator.free(msgs);
    try std.testing.expect(std.mem.indexOf(u8, msgs, "hi") != null);
}

test "McpClient buffers out-of-order response ids" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeTransport.init(allocator);
    defer fake.deinit();

    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"t","version":"1"}}}
    );
    // id=3 arrives before id=2 (listTools) — must be buffered, not dropped.
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}
    );
    try fake.enqueueResponse(
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"x","description":"","inputSchema":{}}]}}
    );

    var client = McpClient.initWithTransport(allocator, io, fake.transport());
    defer {
        client.owns_transport_close = false;
        client.deinit();
    }
    try client.initialize();
    const tools = try client.listTools();
    defer client.freeTools(tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqual(@as(usize, 1), client.pending_by_id.count());
}
