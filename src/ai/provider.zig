//! OpenAI-compatible chat provider with tool_calls (business AI runtime).
//! Transport: zfinal HttpClient (dedicated Threaded Io + connection pool).
//! Streaming: `chatStream` via HttpClient.requestStream + SSE `data:` lines.

const std = @import("std");
const HttpClient = @import("../plugin/http_client.zig").HttpClient;
const tokenizer = @import("tokenizer.zig");
const io_instance = @import("../io_instance.zig");
const key_pool_mod = @import("key_pool.zig");

pub const KeyPool = key_pool_mod.KeyPool;
pub const KeyPoolConfig = key_pool_mod.KeyPoolConfig;
pub const TokenBucket = key_pool_mod.TokenBucket;

pub const AiProvider = struct {
    allocator: std.mem.Allocator,
    http: *HttpClient,
    endpoint: []const u8,
    api_key: []const u8,
    model: []const u8,
    max_output_tokens: usize = 4096,
    temperature: f64 = 0.7,
    metrics: Metrics = .{},
    /// Simple client-side token bucket (optional; ignored when `key_pool` is set).
    rate_limit: ?TokenBucket = null,
    /// Multi-key pool for high concurrency (optional).
    key_pool: ?*KeyPool = null,

    pub const Metrics = struct {
        total_requests: usize = 0,
        total_prompt_tokens: usize = 0,
        total_completion_tokens: usize = 0,
        error_count: usize = 0,
        tool_call_responses: usize = 0,
        rate_limited_count: usize = 0,
        retries_total: usize = 0,
        key_rotations: usize = 0,
        key_cooldowns: usize = 0,
        all_keys_exhausted: usize = 0,

        pub fn toPrometheusFormat(self: Metrics, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(allocator,
                \\# HELP zfinal_ai_provider_requests_total Chat completion requests.
                \\# TYPE zfinal_ai_provider_requests_total counter
                \\zfinal_ai_provider_requests_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_prompt_tokens_total Prompt tokens.
                \\# TYPE zfinal_ai_provider_prompt_tokens_total counter
                \\zfinal_ai_provider_prompt_tokens_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_completion_tokens_total Completion tokens.
                \\# TYPE zfinal_ai_provider_completion_tokens_total counter
                \\zfinal_ai_provider_completion_tokens_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_errors_total Provider errors.
                \\# TYPE zfinal_ai_provider_errors_total counter
                \\zfinal_ai_provider_errors_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_retries_total Transient retries.
                \\# TYPE zfinal_ai_provider_retries_total counter
                \\zfinal_ai_provider_retries_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_key_rotations_total Key pool rotations after 429/401.
                \\# TYPE zfinal_ai_provider_key_rotations_total counter
                \\zfinal_ai_provider_key_rotations_total{{provider="{s}"}} {d}
                \\# HELP zfinal_ai_provider_all_keys_exhausted_total Acquire failures when pool empty.
                \\# TYPE zfinal_ai_provider_all_keys_exhausted_total counter
                \\zfinal_ai_provider_all_keys_exhausted_total{{provider="{s}"}} {d}
                \\
            , .{
                name, self.total_requests,
                name, self.total_prompt_tokens,
                name, self.total_completion_tokens,
                name, self.error_count,
                name, self.retries_total,
                name, self.key_rotations,
                name, self.all_keys_exhausted,
            });
        }
    };

    pub const ToolCall = struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    pub const ChatMsg = struct {
        role: []const u8,
        content: []const u8 = "",
        name: ?[]const u8 = null,
        tool_call_id: ?[]const u8 = null,
        tool_calls: []const ToolCall = &.{},
    };

    pub const ChatOpts = struct {
        tools_json: ?[]const u8 = null,
        /// Request `stream:true` for `chatStream`.
        stream: bool = false,
        /// Extra attempts after the first try for 429/502/503/504 and connection errors.
        max_retries: u8 = 2,
        /// Initial backoff in ms (doubles each retry).
        retry_backoff_ms: u64 = 200,
    };

    pub const ChatResponse = struct {
        content: []const u8 = "",
        role: []const u8 = "assistant",
        tool_calls: []ToolCall = &.{},
        prompt_tokens: usize = 0,
        completion_tokens: usize = 0,
        model: []const u8 = "",
    };

    pub const StreamDelta = struct {
        content_delta: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
        tool_arguments_delta: ?[]const u8 = null,
        done: bool = false,
    };
    pub const OnDelta = *const fn (*anyopaque, StreamDelta) anyerror!void;

    pub const StreamToolCallDelta = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,

        pub fn deinit(self: StreamToolCallDelta, allocator: std.mem.Allocator) void {
            if (self.id) |s| allocator.free(s);
            if (self.name) |s| allocator.free(s);
            if (self.arguments) |s| allocator.free(s);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        http: *HttpClient,
        endpoint: []const u8,
        api_key: []const u8,
        model: []const u8,
    ) AiProvider {
        return .{
            .allocator = allocator,
            .http = http,
            .endpoint = endpoint,
            .api_key = api_key,
            .model = model,
        };
    }

    /// Enable a simple token-bucket rate limit (tokens_per_sec capacity + refill).
    pub fn enableRateLimit(self: *AiProvider, io: std.Io, tokens_per_sec: u32) void {
        const tps: f64 = @floatFromInt(@max(tokens_per_sec, 1));
        self.rate_limit = TokenBucket.init(io, tps, tps);
    }

    pub fn deinit(self: *AiProvider) void {
        self.* = undefined;
    }

    pub fn freeResponse(self: *AiProvider, resp: *ChatResponse) void {
        if (resp.content.len > 0) self.allocator.free(resp.content);
        for (resp.tool_calls) |tc| {
            self.allocator.free(tc.id);
            self.allocator.free(tc.name);
            self.allocator.free(tc.arguments);
        }
        if (resp.tool_calls.len > 0) self.allocator.free(resp.tool_calls);
        resp.* = .{};
    }

    /// Assemble chat messages: optional system + memory notes + history + user.
    /// Caller owns the returned slice (contents are borrowed).
    pub fn buildMessages(
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        memories: []const []const u8,
        history: []const ChatMsg,
        user_msg: []const u8,
    ) ![]ChatMsg {
        var count: usize = 0;
        if (system_prompt != null) count += 1;
        count += memories.len;
        count += history.len;
        count += 1;

        var msgs = try allocator.alloc(ChatMsg, count);
        var idx: usize = 0;
        if (system_prompt) |sp| {
            msgs[idx] = .{ .role = "system", .content = sp };
            idx += 1;
        }
        for (memories) |mem| {
            msgs[idx] = .{ .role = "system", .content = mem };
            idx += 1;
        }
        for (history) |h| {
            msgs[idx] = h;
            idx += 1;
        }
        msgs[idx] = .{ .role = "user", .content = user_msg };
        return msgs;
    }

    pub fn countTokens(_: *AiProvider, messages: []const ChatMsg) usize {
        return tokenizer.estimateMessages(messages);
    }

    /// True when estimated prompt + max_output fits under ~80% of `context_limit`.
    pub fn fitsBudget(self: *AiProvider, messages: []const ChatMsg, context_limit: usize) bool {
        const est = tokenizer.estimateMessages(messages);
        return est + self.max_output_tokens < (context_limit * 4 / 5);
    }

    fn acquireRate(self: *AiProvider) !void {
        if (self.key_pool != null) return; // per-key RPM handled in KeyPool.acquire
        if (self.rate_limit) |*rl| {
            if (!rl.tryAcquire()) {
                self.metrics.rate_limited_count += 1;
                return error.RateLimited;
            }
        }
    }

    fn authHeaderFor(self: *AiProvider, key: []const u8, auth_buf: *[512]u8) ![]const u8 {
        _ = self;
        if (std.mem.startsWith(u8, key, "Bearer ")) return key;
        return try std.fmt.bufPrint(auth_buf, "Bearer {s}", .{key});
    }

    fn resolveKey(self: *AiProvider) !struct { key: []const u8, acquired: ?key_pool_mod.Acquired } {
        if (self.key_pool) |pool| {
            const a = pool.acquire() catch |err| {
                if (err == error.AllKeysExhausted) {
                    self.metrics.all_keys_exhausted += 1;
                    self.metrics.rate_limited_count += 1;
                    return error.AllKeysExhausted;
                }
                return err;
            };
            return .{ .key = a.key, .acquired = a };
        }
        return .{ .key = self.api_key, .acquired = null };
    }

    fn finishKey(self: *AiProvider, acquired: ?key_pool_mod.Acquired, err: ?anyerror) void {
        const a = acquired orelse return;
        const pool = self.key_pool orelse return;
        if (err) |e| {
            if (e == error.RateLimited) {
                pool.markRateLimited(a);
                self.metrics.key_cooldowns += 1;
                self.metrics.key_rotations += 1;
            } else if (e == error.AuthError) {
                pool.markBad(a);
                self.metrics.key_cooldowns += 1;
                self.metrics.key_rotations += 1;
            }
        }
        pool.release(a);
    }

    pub fn chat(self: *AiProvider, messages: []const ChatMsg) !ChatResponse {
        return self.chatWith(messages, .{});
    }

    pub fn chatWith(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) !ChatResponse {
        try self.acquireRate();
        var attempt: u8 = 0;
        const max_attempts = opts.max_retries + 1;
        var backoff = opts.retry_backoff_ms;
        while (true) {
            const result = self.chatWithUnlocked(messages, opts);
            if (result) |resp| return resp else |err| {
                attempt += 1;
                if (attempt >= max_attempts or !isRetryable(err)) return err;
                self.metrics.retries_total += 1;
                std.Io.sleep(io_instance.io, std.Io.Duration.fromMilliseconds(@intCast(backoff)), .real) catch {};
                backoff = @min(backoff *% 2, 5_000);
            }
        }
    }

    fn isRetryable(err: anyerror) bool {
        return err == error.RateLimited or err == error.UpstreamError or err == error.ConnectionError or err == error.AllKeysExhausted;
    }

    fn chatWithUnlocked(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) !ChatResponse {
        const resolved = self.resolveKey() catch |err| {
            if (err == error.AllKeysExhausted) return error.RateLimited;
            return err;
        };
        const body = try self.buildRequestBody(messages, opts);
        defer self.allocator.free(body);

        var auth_buf: [512]u8 = undefined;
        const auth = try self.authHeaderFor(resolved.key, &auth_buf);

        var headers: [2]std.http.Header = .{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth },
        };

        var http_resp = self.http.requestWith(.POST, self.endpoint, body, &headers) catch {
            self.finishKey(resolved.acquired, error.ConnectionError);
            self.metrics.error_count += 1;
            return error.ConnectionError;
        };
        defer http_resp.deinit();

        self.metrics.total_requests += 1;
        if (http_resp.status < 200 or http_resp.status >= 300) {
            self.metrics.error_count += 1;
            const mapped = mapHttpStatus(http_resp.status);
            self.finishKey(resolved.acquired, mapped);
            return mapped;
        }

        const parsed = self.parseResponse(http_resp.body) catch |err| {
            self.finishKey(resolved.acquired, err);
            return err;
        };
        self.finishKey(resolved.acquired, null);
        if (parsed.tool_calls.len > 0) self.metrics.tool_call_responses += 1;
        return parsed;
    }

    /// Stream chat completions (`stream:true`) via HttpClient.requestStream + SSE.
    /// Falls back to buffered chat if the transport fails before useful data.
    pub fn chatStream(
        self: *AiProvider,
        messages: []const ChatMsg,
        opts: ChatOpts,
        cb_ctx: *anyopaque,
        on_delta: OnDelta,
    ) !ChatResponse {
        try self.acquireRate();

        const resolved = self.resolveKey() catch |err| {
            if (err == error.AllKeysExhausted) return error.RateLimited;
            return err;
        };

        var o = opts;
        o.stream = true;
        const body = try self.buildRequestBody(messages, o);
        defer self.allocator.free(body);

        var auth_buf: [512]u8 = undefined;
        const auth = try self.authHeaderFor(resolved.key, &auth_buf);

        var headers: [3]std.http.Header = .{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "authorization", .value = auth },
        };

        var acc = StreamAccum.init(self.allocator, cb_ctx, on_delta);
        defer acc.deinit();

        var http_resp = self.http.requestStream(.POST, self.endpoint, body, &headers, &acc, StreamAccum.onChunk) catch {
            self.finishKey(resolved.acquired, null);
            o.stream = false;
            var resp = try self.chatWithUnlocked(messages, o);
            errdefer self.freeResponse(&resp);
            if (resp.content.len > 0) {
                try on_delta(cb_ctx, .{ .content_delta = resp.content });
            }
            for (resp.tool_calls) |tc| {
                try on_delta(cb_ctx, .{ .tool_name = tc.name, .tool_arguments_delta = tc.arguments });
            }
            try on_delta(cb_ctx, .{ .done = true });
            return resp;
        };
        defer http_resp.deinit();

        self.metrics.total_requests += 1;
        if (http_resp.status < 200 or http_resp.status >= 300) {
            self.metrics.error_count += 1;
            const mapped = mapHttpStatus(http_resp.status);
            self.finishKey(resolved.acquired, mapped);
            return mapped;
        }

        try acc.flush();
        if (!acc.saw_done) {
            try on_delta(cb_ctx, .{ .done = true });
        }

        const content = try self.allocator.dupe(u8, acc.content.items);
        errdefer self.allocator.free(content);
        const tool_calls = try acc.takeToolCalls(self.allocator);
        self.finishKey(resolved.acquired, null);
        if (tool_calls.len > 0) self.metrics.tool_call_responses += 1;
        self.metrics.total_prompt_tokens += acc.prompt_tokens;
        self.metrics.total_completion_tokens += acc.completion_tokens;
        return .{
            .content = content,
            .role = "assistant",
            .tool_calls = tool_calls,
            .prompt_tokens = acc.prompt_tokens,
            .completion_tokens = acc.completion_tokens,
        };
    }

    /// Extract `choices[0].delta.content` from one OpenAI SSE JSON payload.
    pub fn extractStreamDeltaContent(allocator: std.mem.Allocator, json: []const u8) !?[]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const choices = parsed.value.object.get("choices") orelse return null;
        if (choices != .array or choices.array.items.len == 0) return null;
        const c0 = choices.array.items[0];
        if (c0 != .object) return null;
        const delta = c0.object.get("delta") orelse return null;
        if (delta != .object) return null;
        const content = delta.object.get("content") orelse return null;
        return switch (content) {
            .string => |s| try allocator.dupe(u8, s),
            else => null,
        };
    }

    /// Extract streamed `delta.tool_calls` fragments (caller frees each via `deinit`).
    pub fn extractStreamToolCallDeltas(allocator: std.mem.Allocator, json: []const u8) ![]StreamToolCallDelta {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return &.{};
        defer parsed.deinit();
        if (parsed.value != .object) return &.{};
        const choices = parsed.value.object.get("choices") orelse return &.{};
        if (choices != .array or choices.array.items.len == 0) return &.{};
        const c0 = choices.array.items[0];
        if (c0 != .object) return &.{};
        const delta = c0.object.get("delta") orelse return &.{};
        if (delta != .object) return &.{};
        const tcs = delta.object.get("tool_calls") orelse return &.{};
        if (tcs != .array or tcs.array.items.len == 0) return &.{};

        var list = try allocator.alloc(StreamToolCallDelta, tcs.array.items.len);
        var n: usize = 0;
        errdefer {
            for (list[0..n]) |d| d.deinit(allocator);
            allocator.free(list);
        }
        for (tcs.array.items) |item| {
            if (item != .object) continue;
            var d: StreamToolCallDelta = .{};
            if (item.object.get("index")) |idx| {
                d.index = switch (idx) {
                    .integer => |i| if (i < 0) 0 else @intCast(i),
                    else => 0,
                };
            }
            if (item.object.get("id")) |idv| {
                if (idv == .string) d.id = try allocator.dupe(u8, idv.string);
            }
            if (item.object.get("function")) |fnv| {
                if (fnv == .object) {
                    if (fnv.object.get("name")) |nv| {
                        if (nv == .string) d.name = try allocator.dupe(u8, nv.string);
                    }
                    if (fnv.object.get("arguments")) |av| {
                        if (av == .string) d.arguments = try allocator.dupe(u8, av.string);
                    }
                }
            }
            list[n] = d;
            n += 1;
        }
        if (n == 0) {
            allocator.free(list);
            return &.{};
        }
        if (n < list.len) list = try allocator.realloc(list, n);
        return list;
    }

    pub fn buildRequestBody(self: *AiProvider, messages: []const ChatMsg, opts: ChatOpts) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        const a = self.allocator;

        try buf.appendSlice(a, "{\"model\":\"");
        try escapeJson(a, &buf, self.model);
        try buf.appendSlice(a, "\",\"messages\":[");
        for (messages, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(a, ",");
            try buf.appendSlice(a, "{\"role\":\"");
            try buf.appendSlice(a, m.role);
            try buf.appendSlice(a, "\"");
            if (m.tool_call_id) |tid| {
                try buf.appendSlice(a, ",\"tool_call_id\":\"");
                try escapeJson(a, &buf, tid);
                try buf.appendSlice(a, "\"");
            }
            if (m.name) |n| {
                try buf.appendSlice(a, ",\"name\":\"");
                try escapeJson(a, &buf, n);
                try buf.appendSlice(a, "\"");
            }
            try buf.appendSlice(a, ",\"content\":\"");
            try escapeJson(a, &buf, m.content);
            try buf.appendSlice(a, "\"");
            if (m.tool_calls.len > 0) {
                try buf.appendSlice(a, ",\"tool_calls\":[");
                for (m.tool_calls, 0..) |tc, ti| {
                    if (ti > 0) try buf.appendSlice(a, ",");
                    try buf.appendSlice(a, "{\"id\":\"");
                    try escapeJson(a, &buf, tc.id);
                    try buf.appendSlice(a, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try escapeJson(a, &buf, tc.name);
                    try buf.appendSlice(a, "\",\"arguments\":\"");
                    try escapeJson(a, &buf, tc.arguments);
                    try buf.appendSlice(a, "\"}}");
                }
                try buf.appendSlice(a, "]");
            }
            try buf.appendSlice(a, "}");
        }
        try buf.appendSlice(a, "]");
        if (opts.tools_json) |tools| {
            try buf.appendSlice(a, ",\"tools\":");
            try buf.appendSlice(a, tools);
        }
        try buf.appendSlice(a, ",\"max_tokens\":");
        try buf.print(a, "{d}", .{self.max_output_tokens});
        try buf.appendSlice(a, ",\"temperature\":");
        try buf.print(a, "{d}", .{self.temperature});
        if (opts.stream) {
            try buf.appendSlice(a, ",\"stream\":true}");
        } else {
            try buf.appendSlice(a, ",\"stream\":false}");
        }
        return try buf.toOwnedSlice(a);
    }

    pub fn parseResponse(self: *AiProvider, body: []const u8) !ChatResponse {
        var resp = ChatResponse{};
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) {
            resp.content = try self.allocator.dupe(u8, "");
            return resp;
        }
        try self.fillFromJson(&resp, parsed.value.object);
        self.metrics.total_prompt_tokens += resp.prompt_tokens;
        self.metrics.total_completion_tokens += resp.completion_tokens;
        return resp;
    }

    fn fillFromJson(self: *AiProvider, resp: *ChatResponse, root: std.json.ObjectMap) !void {
        if (root.get("usage")) |usage_v| {
            if (usage_v == .object) {
                const u = usage_v.object;
                resp.prompt_tokens = jsonInt(u.get("prompt_tokens"));
                resp.completion_tokens = jsonInt(u.get("completion_tokens"));
            }
        }
        if (root.get("model")) |m| {
            if (m == .string) resp.model = m.string;
        }
        const choices = root.get("choices") orelse {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        };
        if (choices != .array or choices.array.items.len == 0) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        const choice0 = choices.array.items[0];
        if (choice0 != .object) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        const msg = choice0.object.get("message") orelse {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        };
        if (msg != .object) {
            resp.content = try self.allocator.dupe(u8, "");
            return;
        }
        if (msg.object.get("content")) |c| {
            switch (c) {
                .string => |s| resp.content = try self.allocator.dupe(u8, s),
                else => resp.content = try self.allocator.dupe(u8, ""),
            }
        } else {
            resp.content = try self.allocator.dupe(u8, "");
        }
        if (msg.object.get("tool_calls")) |tcs| {
            if (tcs == .array and tcs.array.items.len > 0) {
                var list = try self.allocator.alloc(ToolCall, tcs.array.items.len);
                var n: usize = 0;
                errdefer {
                    for (list[0..n]) |tc| {
                        self.allocator.free(tc.id);
                        self.allocator.free(tc.name);
                        self.allocator.free(tc.arguments);
                    }
                    self.allocator.free(list);
                }
                for (tcs.array.items) |item| {
                    if (item != .object) continue;
                    const id = if (item.object.get("id")) |v| switch (v) {
                        .string => |s| s,
                        else => "",
                    } else "";
                    const fn_obj = item.object.get("function") orelse continue;
                    if (fn_obj != .object) continue;
                    const name = if (fn_obj.object.get("name")) |v| switch (v) {
                        .string => |s| s,
                        else => continue,
                    } else continue;
                    const args = if (fn_obj.object.get("arguments")) |v| switch (v) {
                        .string => |s| s,
                        else => "{}",
                    } else "{}";
                    list[n] = .{
                        .id = try self.allocator.dupe(u8, id),
                        .name = try self.allocator.dupe(u8, name),
                        .arguments = try self.allocator.dupe(u8, args),
                    };
                    n += 1;
                }
                if (n == 0) {
                    self.allocator.free(list);
                } else if (n < list.len) {
                    resp.tool_calls = try self.allocator.realloc(list, n);
                } else {
                    resp.tool_calls = list;
                }
            }
        }
    }
};

const StreamAccum = struct {
    allocator: std.mem.Allocator,
    cb_ctx: *anyopaque,
    on_delta: AiProvider.OnDelta,
    carry: std.ArrayList(u8),
    content: std.ArrayList(u8),
    pending_tools: std.ArrayList(PendingTool),
    saw_done: bool = false,
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,

    const PendingTool = struct {
        index: usize,
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        arguments: std.ArrayList(u8) = .empty,

        fn deinit(self: *PendingTool, allocator: std.mem.Allocator) void {
            self.id.deinit(allocator);
            self.name.deinit(allocator);
            self.arguments.deinit(allocator);
        }
    };

    fn init(allocator: std.mem.Allocator, cb_ctx: *anyopaque, on_delta: AiProvider.OnDelta) StreamAccum {
        return .{
            .allocator = allocator,
            .cb_ctx = cb_ctx,
            .on_delta = on_delta,
            .carry = .empty,
            .content = .empty,
            .pending_tools = .empty,
        };
    }

    fn deinit(self: *StreamAccum) void {
        self.carry.deinit(self.allocator);
        self.content.deinit(self.allocator);
        for (self.pending_tools.items) |*t| t.deinit(self.allocator);
        self.pending_tools.deinit(self.allocator);
    }

    fn onChunk(ctx: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *StreamAccum = @ptrCast(@alignCast(ctx));
        try self.carry.appendSlice(self.allocator, chunk);
        try self.drainLines(false);
    }

    fn flush(self: *StreamAccum) !void {
        try self.drainLines(true);
    }

    fn drainLines(self: *StreamAccum, final: bool) !void {
        while (true) {
            const nl = std.mem.indexOfScalar(u8, self.carry.items, '\n') orelse {
                if (final and self.carry.items.len > 0) {
                    try self.handleLine(std.mem.trim(u8, self.carry.items, "\r"));
                    self.carry.clearRetainingCapacity();
                }
                return;
            };
            var line = self.carry.items[0..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try self.handleLine(line);
            const rest = self.carry.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.carry.items[0..rest], self.carry.items[nl + 1 ..]);
            try self.carry.resize(self.allocator, rest);
        }
    }

    fn handleLine(self: *StreamAccum, line: []const u8) !void {
        if (line.len == 0) return;
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (std.mem.eql(u8, payload, "[DONE]")) {
            self.saw_done = true;
            try self.on_delta(self.cb_ctx, .{ .done = true });
            return;
        }
        if (extractIntField(payload, "\"prompt_tokens\":")) |n| self.prompt_tokens = n;
        if (extractIntField(payload, "\"completion_tokens\":")) |n| self.completion_tokens = n;

        const delta = try AiProvider.extractStreamDeltaContent(self.allocator, payload);
        if (delta) |d| {
            defer self.allocator.free(d);
            if (d.len > 0) {
                try self.content.appendSlice(self.allocator, d);
                try self.on_delta(self.cb_ctx, .{ .content_delta = d });
            }
        }

        const tcds = try AiProvider.extractStreamToolCallDeltas(self.allocator, payload);
        defer {
            for (tcds) |d| d.deinit(self.allocator);
            if (tcds.len > 0) self.allocator.free(tcds);
        }
        for (tcds) |d| {
            try self.mergeToolDelta(d);
            try self.on_delta(self.cb_ctx, .{
                .tool_name = d.name,
                .tool_arguments_delta = d.arguments,
            });
        }
    }

    fn mergeToolDelta(self: *StreamAccum, d: AiProvider.StreamToolCallDelta) !void {
        const slot = try self.ensurePending(d.index);
        if (d.id) |id| {
            slot.id.clearRetainingCapacity();
            try slot.id.appendSlice(self.allocator, id);
        }
        if (d.name) |name| {
            try slot.name.appendSlice(self.allocator, name);
        }
        if (d.arguments) |args| {
            try slot.arguments.appendSlice(self.allocator, args);
        }
    }

    fn ensurePending(self: *StreamAccum, index: usize) !*PendingTool {
        for (self.pending_tools.items) |*t| {
            if (t.index == index) return t;
        }
        try self.pending_tools.append(self.allocator, .{ .index = index });
        return &self.pending_tools.items[self.pending_tools.items.len - 1];
    }

    fn takeToolCalls(self: *StreamAccum, allocator: std.mem.Allocator) ![]AiProvider.ToolCall {
        if (self.pending_tools.items.len == 0) return &.{};
        const out = try allocator.alloc(AiProvider.ToolCall, self.pending_tools.items.len);
        errdefer allocator.free(out);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.name);
                allocator.free(tc.arguments);
            }
        }
        for (self.pending_tools.items) |*t| {
            out[n] = .{
                .id = try allocator.dupe(u8, t.id.items),
                .name = try allocator.dupe(u8, t.name.items),
                .arguments = try allocator.dupe(u8, t.arguments.items),
            };
            n += 1;
        }
        for (self.pending_tools.items) |*t| t.deinit(self.allocator);
        self.pending_tools.clearRetainingCapacity();
        return out;
    }
};

fn mapHttpStatus(status: u16) anyerror {
    return switch (status) {
        401, 403 => error.AuthError,
        429 => error.RateLimited,
        500, 502, 503, 504 => error.UpstreamError,
        else => error.ProviderError,
    };
}

fn jsonInt(v: ?std.json.Value) usize {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn extractIntField(body: []const u8, field: []const u8) ?usize {
    const start = std.mem.indexOf(u8, body, field) orelse return null;
    const vs = start + field.len;
    var i: usize = vs;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len) return null;
    var n: usize = 0;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        n = n * 10 + (body[i] - '0');
    }
    return n;
}

fn escapeJson(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

test "AiProvider parseResponse tool_calls" {
    const a = std.testing.allocator;
    var client = try HttpClient.init(a, "");
    defer client.deinit();
    var provider = AiProvider.init(a, &client, "http://example/v1/chat/completions", "sk-test", "m");
    defer provider.deinit();

    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"ping","arguments":"{}"}}]}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}
    ;
    var resp = try provider.parseResponse(body);
    defer provider.freeResponse(&resp);
    try std.testing.expectEqual(@as(usize, 1), resp.tool_calls.len);
    try std.testing.expectEqualStrings("ping", resp.tool_calls[0].name);
    try std.testing.expectEqual(@as(usize, 3), resp.prompt_tokens);
}

test "AiProvider StreamAccum parses SSE lines" {
    const a = std.testing.allocator;
    const Ctx = struct {
        parts: std.ArrayList([]const u8),
        done: bool = false,
        allocator: std.mem.Allocator,

        fn onDelta(ctx: *anyopaque, d: AiProvider.StreamDelta) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (d.done) {
                self.done = true;
                return;
            }
            if (d.content_delta) |c| {
                try self.parts.append(self.allocator, try self.allocator.dupe(u8, c));
            }
        }
    };
    var ctx = Ctx{ .parts = .empty, .allocator = a };
    defer {
        for (ctx.parts.items) |p| a.free(p);
        ctx.parts.deinit(a);
    }

    var acc = StreamAccum.init(a, &ctx, Ctx.onDelta);
    defer acc.deinit();

    const chunk1 = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n";
    const chunk2 = "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\ndata: [DONE]\n";
    try StreamAccum.onChunk(&acc, chunk1);
    try StreamAccum.onChunk(&acc, chunk2);
    try acc.flush();

    try std.testing.expect(ctx.done);
    try std.testing.expectEqual(@as(usize, 2), ctx.parts.items.len);
    try std.testing.expectEqualStrings("Hel", ctx.parts.items[0]);
    try std.testing.expectEqualStrings("lo", ctx.parts.items[1]);
    try std.testing.expectEqualStrings("Hello", acc.content.items);
}

test "AiProvider stream tool_calls merge" {
    const a = std.testing.allocator;
    const j1 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"lookup","arguments":"{\"q\":"}}]}}]}
    ;
    const j2 =
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}
    ;
    const d1 = try AiProvider.extractStreamToolCallDeltas(a, j1);
    defer {
        for (d1) |x| x.deinit(a);
        if (d1.len > 0) a.free(d1);
    }
    try std.testing.expectEqual(@as(usize, 1), d1.len);
    try std.testing.expectEqualStrings("lookup", d1[0].name.?);

    var acc = StreamAccum.init(a, undefined, struct {
        fn nop(_: *anyopaque, _: AiProvider.StreamDelta) anyerror!void {}
    }.nop);
    defer acc.deinit();
    try acc.mergeToolDelta(d1[0]);
    const d2 = try AiProvider.extractStreamToolCallDeltas(a, j2);
    defer {
        for (d2) |x| x.deinit(a);
        if (d2.len > 0) a.free(d2);
    }
    try acc.mergeToolDelta(d2[0]);
    const tcs = try acc.takeToolCalls(a);
    defer {
        for (tcs) |tc| {
            a.free(tc.id);
            a.free(tc.name);
            a.free(tc.arguments);
        }
        if (tcs.len > 0) a.free(tcs);
    }
    try std.testing.expectEqual(@as(usize, 1), tcs.len);
    try std.testing.expectEqualStrings("c1", tcs[0].id);
    try std.testing.expectEqualStrings("lookup", tcs[0].name);
    try std.testing.expectEqualStrings("{\"q\":1}", tcs[0].arguments);
}

test "AiProvider buildMessages and fitsBudget" {
    const a = std.testing.allocator;
    const hist = [_]AiProvider.ChatMsg{.{ .role = "assistant", .content = "hi" }};
    const mems = [_][]const u8{"note: prefer zh"};
    const msgs = try AiProvider.buildMessages(a, "sys", &mems, &hist, "user?");
    defer a.free(msgs);
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqualStrings("sys", msgs[0].content);
    try std.testing.expectEqualStrings("note: prefer zh", msgs[1].content);
    try std.testing.expectEqualStrings("hi", msgs[2].content);
    try std.testing.expectEqualStrings("user?", msgs[3].content);

    var client = try HttpClient.init(a, "");
    defer client.deinit();
    var provider = AiProvider.init(a, &client, "http://x", "k", "m");
    defer provider.deinit();
    provider.max_output_tokens = 10;
    try std.testing.expect(provider.fitsBudget(msgs, 10_000));
    try std.testing.expect(!provider.fitsBudget(msgs, 20));
    try std.testing.expect(provider.countTokens(msgs) > 0);
}

test "AiProvider buildRequestBody stream flag" {
    const a = std.testing.allocator;
    var client = try HttpClient.init(a, "");
    defer client.deinit();
    var provider = AiProvider.init(a, &client, "http://x", "k", "m");
    defer provider.deinit();
    const msgs = [_]AiProvider.ChatMsg{.{ .role = "user", .content = "hi" }};
    const body = try provider.buildRequestBody(&msgs, .{ .stream = true });
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}
