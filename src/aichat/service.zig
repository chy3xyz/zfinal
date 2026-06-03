const std = @import("std");
const io_instance = @import("../io_instance.zig");
const types = @import("types.zig");
const ChatMessage = types.ChatMessage;
const ChatResult = types.ChatResult;

pub const ChatPersistence = struct {
    context: *anyopaque,

    saveUserMessage: *const fn (
        ctx: *anyopaque,
        session_id: i64,
        content: []const u8,
    ) anyerror!i64,

    saveAssistantMessage: *const fn (
        ctx: *anyopaque,
        session_id: i64,
        content: []const u8,
        total_tokens: i64,
        model_name: ?[]const u8,
    ) anyerror!i64,

    updateSessionTime: *const fn (
        ctx: *anyopaque,
        session_id: i64,
    ) anyerror!void,

    updateSessionTitle: *const fn (
        ctx: *anyopaque,
        session_id: i64,
        title: []const u8,
    ) anyerror!void,

    getSessionTitle: *const fn (
        ctx: *anyopaque,
        session_id: i64,
    ) anyerror!?[]const u8,

    deinit: *const fn (ctx: *anyopaque) void,
};

pub fn buildSystemPrompt(comptime custom: ?[]const u8) []const u8 {
    if (comptime custom) |t| return t;
    return types.DEFAULT_SYSTEM_PROMPT;
}

pub fn buildSystemPromptWithDate(comptime custom: ?[]const u8, date: []const u8) []const u8 {
    if (comptime custom) |t| {
        return std.mem.concat(std.heap.page_allocator, u8, &.{
            t, "\n\n- 今天是：", date,
        }) catch return t;
    }
    const buf: [512]u8 = undefined;
    return std.fmt.bufPrint(&buf, types.SYSTEM_PROMPT_TEMPLATE, .{date}) catch types.DEFAULT_SYSTEM_PROMPT;
}

pub fn buildStreamingRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const ChatMessage,
    temperature: f64,
    max_tokens: i64,
) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = model,
        .messages = messages,
        .stream = true,
        .temperature = temperature,
        .max_tokens = max_tokens,
    }, .{});
}

pub fn buildSyncRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const ChatMessage,
    temperature: f64,
    max_tokens: i64,
) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{
        .model = model,
        .messages = messages,
        .stream = false,
        .temperature = temperature,
        .max_tokens = max_tokens,
    }, .{});
}

pub fn formatSSE(
    allocator: std.mem.Allocator,
    tokens: []const []const u8,
) ![]u8 {
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);

    for (tokens) |token| {
        const chunk = try std.fmt.allocPrint(allocator,
            "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\n",
            .{token},
        );
        errdefer allocator.free(chunk);
        try combined.appendSlice(allocator, chunk);
        allocator.free(chunk);
    }

    try combined.appendSlice(allocator, "data: [DONE]\n\n");
    return try combined.toOwnedSlice(allocator);
}

pub fn formatSSERaw(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\ndata: [DONE]\n\n",
        .{content},
    );
}

pub fn countTokensEst(tokens: []const []const u8) i64 {
    var total: i64 = 0;
    for (tokens) |t| {
        total += @divTrunc(@as(i64, @intCast(t.len)), 4);
    }
    return total;
}

pub fn chatSync(
    api_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    messages: []const ChatMessage,
    temperature: f64,
    max_tokens: i64,
    allocator: std.mem.Allocator,
) !ChatResult {
    const body = try buildSyncRequestBody(allocator, model, messages, temperature, max_tokens);
    defer allocator.free(body);

    const full_url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{api_url});
    defer allocator.free(full_url);

    const auth_hdr = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth_hdr);

    const sh_cmd = try std.mem.concat(allocator, u8, &.{
        \\ curl -s -XPOST 
        , full_url,
        \\ -H 'Content-Type: application/json' -H '
        , auth_hdr,
        \\ ' -d '
        , body,
        \\ ' --max-time 15 -k
    });
    defer allocator.free(sh_cmd);

    const result = std.process.run(allocator, io_instance.io, .{
        .argv = &.{ "sh", "-c", sh_cmd },
    }) catch return error.ConnectionFailed;

    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        return error.ConnectionFailed;
    }

    const parsed = try std.json.parseFromSlice(struct {
        choices: []struct {
            message: struct {
                content: []const u8,
            },
        },
        usage: ?struct {
            prompt_tokens: ?i64,
            completion_tokens: ?i64,
            total_tokens: ?i64,
        } = null,
        model: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const choice = if (parsed.value.choices.len > 0) parsed.value.choices[0] else return error.NoChoice;
    const content = try allocator.dupe(u8, choice.message.content);

    return .{
        .content = content,
        .model_name = if (parsed.value.model) |m| try allocator.dupe(u8, m) else null,
        .prompt_tokens = parsed.value.usage.?.prompt_tokens orelse 0,
        .completion_tokens = parsed.value.usage.?.completion_tokens orelse 0,
        .total_tokens = parsed.value.usage.?.total_tokens orelse 0,
    };
}
