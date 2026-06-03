# aichat — AI Chat Component

## Overview

`aichat` 是 zfinal 框架的 AI 对话组件，提供与 LLM API（OpenAI 兼容接口，如 DeepSeek、Claude via API、硅基流动等）的集成能力。

**设计原则**：
- **可替换**：通过 `AiClient` trait 抽象 HTTP 客户端实现，默认使用 curl 子进程（`CurlAiClient`），可替换为原生 TCP/TLS、fetch 或任何 HTTP 库
- **无状态**：组件本身不持有 DB 连接或 session 状态 — 这些由 app 层管理
- **SSE 原语**：提供 `formatSSE` / `formatSSERaw` 等工具，app 决定如何与 HTTP 响应管道集成

---

## 类型 (types.zig)

```zig
const aichat = zfinal.aichat;

pub const ChatMessage = struct {
    role: []const u8,      // "system" | "user" | "assistant"
    content: []const u8,
};

pub const ChatResult = struct {
    content: []const u8,
    model_name: ?[]const u8 = null,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
};
```

### 预定义常量

```zig
pub const SYSTEM_PROMPT_TEMPLATE = ...;  // 带 %s 日期占位符的默认提示词
pub const DEFAULT_SYSTEM_PROMPT = ...;   // 简化版默认提示词
```

---

## 客户端接口 (client.zig)

### trait: `AiClient`

```zig
pub const AiClient = struct {
    chatSync:   *const fn (ctx, api_url, api_key, model, messages, temperature, max_tokens, allocator) anyerror!ChatResult,
    chatStream: *const fn (ctx, api_url, api_key, model, messages, temperature, max_tokens, allocator) anyerror![]const []const u8,
    deinit:     *const fn (ctx) void,
};
```

**调用方式**：

```zig
const aichat = zfinal.aichat;

var curl = aichat.CurlAiClient.init();
defer aichat.deinitClient(curl.client());

const result = try aichat.chatSync(
    curl.client(),
    "https://api.deepseek.com",
    "sk-xxx",
    "deepseek-chat",
    &.{.{ .role = "user", .content = "Hello" }},
    0.7,
    1024,
    allocator,
);
// result: ChatResult { .content = "Hello! How can I help...", .total_tokens = 23 }
```

### 默认实现: `CurlAiClient`

使用 curl 子进程调用 HTTPS API，绕过 Zig 原生 HTTP 库在部分环境下的兼容性问题。

```zig
var client = aichat.CurlAiClient.init();
const ai_client = client.client(); // returns AiClient
```

---

## 服务工具 (service.zig)

### `chatSync` — 同步对话

```zig
pub fn chatSync(
    api_url:       []const u8,
    api_key:       []const u8,
    model:         []const u8,
    messages:      []const ChatMessage,
    temperature:   f64,
    max_tokens:    i64,
    allocator:     std.mem.Allocator,
) !ChatResult
```

直接调用 OpenAI 兼容接口（非流式），返回完整响应。

### `buildSyncRequestBody` / `buildStreamingRequestBody`

```zig
pub fn buildSyncRequestBody(allocator, model, messages, temperature, max_tokens) ![]u8
pub fn buildStreamingRequestBody(allocator, model, messages, temperature, max_tokens) ![]u8
```

构建 JSON 请求体（用于 curl 或自定义 HTTP 调用）。

### `formatSSE` / `formatSSERaw`

```zig
pub fn formatSSE(allocator, tokens: []const []const u8) ![]u8
pub fn formatSSERaw(allocator, content: []const u8) ![]u8
```

将 token 数组格式化为 SSE (`text/event-stream`) 格式：

```zig
// formatSSE: 逐 token 发送
for (tokens) |token| {
    try writer.writeAll("data: {\"choices\":[{\"delta\":{\"content\":\"" ++ token ++ "\"}}]}\n\n");
}
try writer.writeAll("data: [DONE]\n\n");

// formatSSERaw: 一次性发送（适合 curl 批量流式输出）
"data: {\"choices\":[{\"delta\":{\"content\":\"完整内容\"}}]}\n\ndata: [DONE]\n\n"
```

### `countTokensEst`

```zig
pub fn countTokensEst(tokens: []const []const u8) i64
```

按 `字符数 / 4` 估算 token 数量（用于 `tokens_used` 字段）。

### `ChatPersistence` trait

会话持久化接口 — 由 app 实现（写入 DB）。

```zig
pub const ChatPersistence = struct {
    context: *anyopaque,
    saveUserMessage:       *const fn (ctx, session_id, content) anyerror!i64,
    saveAssistantMessage:  *const fn (ctx, session_id, content, total_tokens, model_name) anyerror!i64,
    updateSessionTime:     *const fn (ctx, session_id) anyerror!void,
    updateSessionTitle:    *const fn (ctx, session_id, title) anyerror!void,
    getSessionTitle:       *const fn (ctx, session_id) anyerror!?[]const u8,
    deinit:                *const fn (ctx) void,
};
```

---

## 完整集成示例

### App 层: `ai_service.zig`

```zig
const std = @import("std");
const zfinal = @import("zfinal");
const aichat = zfinal.aichat;
const system_config = @import(".../system/config/ext/service.zig");
const deps = @import("deps.zig");

pub const ChatMessage = aichat.ChatMessage;
pub const ChatResult = aichat.ChatResult;

// 1. 从 DB 读取 AI 配置
pub fn getAIConfig(allocator: std.mem.Allocator) !system_config.AIConfig {
    return try system_config.getAIConfig(allocator);
}

// 2. 同步对话（用于 /chat/sendSync）
pub fn chatSync(
    allocator: std.mem.Allocator,
    messages: []const ChatMessage,
    system_prompt: []const u8,
) !ChatResult {
    const config = try getAIConfig(allocator);
    defer allocator.free(config.apiKey);

    var all = std.ArrayList(ChatMessage).empty;
    defer all.deinit(allocator);
    try all.append(allocator, .{ .role = "system", .content = system_prompt });
    for (messages) |msg| try all.append(allocator, msg);

    return try aichat.chatSync(
        config.apiUrl,
        config.apiKey,
        config.model,
        all.items,
        config.temperature,
        config.maxTokens,
        allocator,
    );
}

// 3. 流式 SSE（用于 /chat/send）
pub fn chatStream(
    allocator: std.mem.Allocator,
    messages: []const ChatMessage,
    config: system_config.AIConfig,
) ![]const []const u8 {
    var all = std.ArrayList(ChatMessage).empty;
    defer all.deinit(allocator);
    // ... 填充 system + history messages

    var client = aichat.CurlAiClient.init();
    defer aichat.deinitClient(client.client());

    return try aichat.chatStream(
        client.client(),
        config.apiUrl,
        config.apiKey,
        config.model,
        all.items,
        config.temperature,
        config.maxTokens,
        allocator,
    );
}
```

### App 层: Handler

```zig
pub fn chatSend(ctx: *zfinal.Context) !void {
    // ... JWT 认证 + DB 事务

    // 流式 SSE
    const tokens = try chatStream(ctx.allocator, messages.items, config);
    defer {
        for (tokens) |t| ctx.allocator.free(t);
        ctx.allocator.free(tokens);
    }

    const sse = try aichat.formatSSE(ctx.allocator, tokens);
    defer ctx.allocator.free(sse);

    try ctx.setHeader("Content-Type", "text/event-stream");
    try ctx.setHeader("Cache-Control", "no-cache");
    try ctx.renderText(sse);

    // 持久化到 DB
    const full = try std.mem.concat(ctx.allocator, u8, &tokens);
    defer ctx.allocator.free(full);
    const est_tokens = aichat.countTokensEst(tokens);
    _ = try saveAssistantMessage(db, body.sessionId, full, est_tokens, null);
}
```

---

## 自定义 AI 客户端

实现 `AiClient` trait 即可接入任何 LLM：

```zig
const MyModelClient = struct {
    context: MyState,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) MyModelClient {
        return MyModelClient{ .context = .{ .allocator = allocator, .api_key = api_key } };
    }

    pub fn client(self: *MyModelClient) aichat.AiClient {
        return .{
            .context = self,
            .chatSync = doSync,
            .chatStream = doStream,
            .deinit = doDeinit,
        };
    }

    fn doDeinit(_: *anyopaque) void { /* 清理状态 */ }

    fn doSync(ctx: *anyopaque, ...) !aichat.ChatResult {
        const self: *MyModelClient = @ptrCast(@alignCast(ctx));
        // 调用本地模型或自定义 HTTP 库
        return .{
            .content = try self.callLocalModel(...),
            .total_tokens = 0,
        };
    }

    fn doStream(...) ![]const []const u8 { ... }
};
```

---

## 错误处理

```zig
pub fn chatSync(...) !ChatResult {
    return error{
        ConnectionFailed,   // curl/external call 失败
        NoChoice,          // API 响应无 choices 字段
    };
}
```

---

## API 速查

| 导出 | 所在文件 | 说明 |
|---|---|---|
| `ChatMessage`, `ChatResult` | `types.zig` | 核心数据结构 |
| `SYSTEM_PROMPT_TEMPLATE`, `DEFAULT_SYSTEM_PROMPT` | `types.zig` | 预定义提示词 |
| `AiClient`, `CurlAiClient`, `chatSync`, `chatStream`, `deinitClient` | `client.zig` | 客户端 trait + curl 实现 |
| `chatSync`, `buildSyncRequestBody`, `buildStreamingRequestBody` | `service.zig` | 服务工具（直接 HTTP 调用） |
| `formatSSE`, `formatSSERaw`, `countTokensEst` | `service.zig` | SSE 格式化 + token 估算 |
| `ChatPersistence` | `service.zig` | 持久化 trait |
