const std = @import("std");
const aichat = @import("aichat.zig");
const testing = std.testing;

test "aichat: ChatMessage and ChatResult construction" {
    const msg: aichat.ChatMessage = .{
        .role = "user",
        .content = "Hello",
    };
    try testing.expectEqualStrings("user", msg.role);
    try testing.expectEqualStrings("Hello", msg.content);

    const result: aichat.ChatResult = .{
        .content = "Hi there!",
        .model_name = "deepseek-chat",
        .prompt_tokens = 5,
        .completion_tokens = 8,
        .total_tokens = 13,
    };
    try testing.expectEqualStrings("Hi there!", result.content);
    try testing.expectEqualStrings("deepseek-chat", result.model_name.?);
    try testing.expectEqual(@as(i64, 13), result.total_tokens);
}

test "aichat: buildSyncRequestBody produces valid JSON" {
    const allocator = std.testing.allocator;
    const messages = &.{
        aichat.ChatMessage{ .role = "system", .content = "You are a helpful assistant." },
        aichat.ChatMessage{ .role = "user", .content = "Hi" },
    };

    const body = try aichat.buildSyncRequestBody(allocator, "deepseek-chat", messages, 0.7, 2048);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "deepseek-chat") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.7") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":2048") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Hi\"") != null);

    const parsed = try std.json.parseFromSlice(struct {
        model: []const u8,
        messages: []struct {
            role: []const u8,
            content: []const u8,
        },
        stream: bool,
        temperature: f64,
        max_tokens: i64,
    }, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try testing.expectEqualStrings("deepseek-chat", parsed.value.model);
    try testing.expectEqual(@as(usize, 2), parsed.value.messages.len);
    try testing.expectEqualStrings("system", parsed.value.messages[0].role);
    try testing.expectEqualStrings("You are a helpful assistant.", parsed.value.messages[0].content);
    try testing.expectEqualStrings("user", parsed.value.messages[1].role);
    try testing.expectEqualStrings("Hi", parsed.value.messages[1].content);
    try testing.expectEqual(false, parsed.value.stream);
}

test "aichat: buildStreamingRequestBody sets stream=true" {
    const allocator = std.testing.allocator;
    const messages = &.{aichat.ChatMessage{ .role = "user", .content = "Hello" }};

    const body = try aichat.buildStreamingRequestBody(allocator, "deepseek-chat", messages, 0.5, 1024);
    defer allocator.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.5") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1024") != null);
}

test "aichat: formatSSERaw produces valid SSE" {
    const allocator = std.testing.allocator;

    const sse = try aichat.formatSSERaw(allocator, "Hello world!");
    defer allocator.free(sse);

    try testing.expect(std.mem.startsWith(u8, sse, "data: "));
    try testing.expect(std.mem.indexOf(u8, sse, "data: [DONE]") != null);
    try testing.expect(std.mem.indexOf(u8, sse, "\n\n") != null);
    try testing.expect(std.mem.indexOf(u8, sse, "Hello world!") != null);

    try testing.expectEqual('\n', sse[sse.len - 1]);
}

test "aichat: formatSSE produces valid SSE from tokens" {
    const allocator = std.testing.allocator;
    const tokens = &.{ "Hello", " ", "world", "!" };

    const sse = try aichat.formatSSE(allocator, tokens);
    defer allocator.free(sse);

    var count: usize = 0;
    var spliter = std.mem.splitScalar(u8, sse, '\n');
    while (spliter.next()) |line| {
        if (std.mem.startsWith(u8, line, "data:")) count += 1;
    }
    try testing.expect(count >= 5);

    try testing.expect(std.mem.indexOf(u8, sse, "data: [DONE]") != null);

    var token_count: usize = 0;
    spliter = std.mem.splitScalar(u8, sse, '\n');
    while (spliter.next()) |line| {
        if (std.mem.startsWith(u8, line, "data: {")) token_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), token_count);
}

test "aichat: countTokensEst sums per-token char/4" {
    const tokens = &.{ "Hello", "world", "this is a test message" };
    const est = aichat.countTokensEst(tokens);
    const expected: i64 = @divTrunc(@as(i64, @intCast(tokens[0].len)), 4) +
        @divTrunc(@as(i64, @intCast(tokens[1].len)), 4) +
        @divTrunc(@as(i64, @intCast(tokens[2].len)), 4);
    try testing.expectEqual(expected, est);
    try testing.expectEqual(@as(i64, 7), est);
}

test "aichat: countTokensEst empty tokens returns 0" {
    const tokens: []const []const u8 = &.{};
    const est = aichat.countTokensEst(tokens);
    try testing.expectEqual(@as(i64, 0), est);
}

test "aichat: chatSync with invalid URL returns error" {
    const allocator = std.testing.allocator;
    const messages = &.{aichat.ChatMessage{ .role = "user", .content = "Hi" }};

    const result = aichat.chatSync(
        "https://127.0.0.1:99999",
        "sk-invalid-no-real-key",
        "deepseek-chat",
        messages,
        0.7,
        10,
        allocator,
    );

    try testing.expectError(error.ConnectionFailed, result);
}

test "aichat: CurlAiClient init and client" {
    var client = aichat.CurlAiClient.init();
    const ai_client = client.client();

    ai_client.deinit(ai_client.context);
    try testing.expect(true);
}

test "aichat: SYSTEM_PROMPT_TEMPLATE contains date placeholder" {
    const template = aichat.SYSTEM_PROMPT_TEMPLATE;
    try testing.expect(std.mem.indexOf(u8, template, "%s") != null);
    try testing.expect(std.mem.indexOf(u8, template, "今天是") != null);
}

test "aichat: DEFAULT_SYSTEM_PROMPT is non-empty" {
    const prompt = aichat.DEFAULT_SYSTEM_PROMPT;
    try testing.expect(prompt.len > 0);
    try testing.expect(std.mem.indexOf(u8, prompt, "助手") != null);
}
