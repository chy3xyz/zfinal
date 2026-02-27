const std = @import("std");
const zfinal = @import("zfinal");

/// Token 防重复提交示例 - 展示如何使用 Token 拦截器防止表单重复提交
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建 Token 管理器
    var token_manager = zfinal.TokenManager.init(allocator);
    defer token_manager.deinit();

    token_manager.setTTL(300); // 5 分钟有效期

    // 创建应用
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(8080);

    // 创建 Token 拦截器配置
    const TokenInterceptor = @import("../../src/token/interceptor.zig");
    const token_interceptor = TokenInterceptor.createTokenInterceptor(.{
        .token_manager = &token_manager,
        .token_name = "_token",
        .error_message = "Invalid or expired token, please refresh",
    });

    // 使用内联结构体定义处理器，捕获 token_manager
    const Handlers = struct {
        var tm: *zfinal.TokenManager = undefined;

        // 获取表单页面（包含 Token）
        fn getFormHandler(ctx: *zfinal.Context) !void {
            // 生成 Token
            const token = try tm.generate();
            defer ctx.allocator.free(token);

            const html =
                \\<!DOCTYPE html>
                \\<html lang="zh-CN">
                \\<head>
                \\    <meta charset="UTF-8">
                \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                \\    <title>Token Demo - 防止重复提交</title>
                \\    <style>
                \\        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; 
                \\               max-width: 600px; margin: 50px auto; padding: 20px; }
                \\        .form-group { margin-bottom: 20px; }
                \\        label { display: block; margin-bottom: 8px; font-weight: bold; }
                \\        input[type="text"] { width: 100%; padding: 12px; border: 2px solid #e9ecef; 
                \\                             border-radius: 8px; font-size: 1rem; box-sizing: border-box; }
                \\        button { background: #667eea; color: white; border: none; padding: 12px 24px; 
                \\                 border-radius: 8px; cursor: pointer; font-size: 1rem; }
                \\        button:hover { background: #5568d3; }
                \\        .token-info { background: #f8f9fa; padding: 15px; border-radius: 8px; 
                \\                        margin-bottom: 20px; font-family: monospace; word-break: break-all; }
                \\        .result { background: #d4edda; padding: 15px; border-radius: 8px; 
                \\                   margin-top: 20px; border: 1px solid #c3e6cb; }
                \\        .error { background: #f8d7da; padding: 15px; border-radius: 8px; 
                \\                 margin-top: 20px; border: 1px solid #f5c6cb; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>🔐 Token 防重复提交演示</h1>
                \\    <p>此表单使用 Token 机制防止重复提交。每次提交后 Token 失效。</p>
                \\    <div class="token-info">Token: {s}</div>
                \\    <form method="POST" action="/submit">
                \\        <input type="hidden" name="_token" value="{s}">
                \\        <div class="form-group">
                \\            <label for="data">请输入内容:</label>
                \\            <input type="text" id="data" name="data" required>
                \\        </div>
                \\        <button type="submit">提交</button>
                \\    </form>
                \\    <hr>
                \\    <h3>API 方式:</h3>
                \\    <pre><code># 获取 Token
                \\curl http://localhost:8080/api/token
                \\# 提交表单（Token 只可用一次）
                \\curl -X POST http://localhost:8080/api/submit -d '_token=YOUR_TOKEN&data=hello'</code></pre>
                \\</body>
                \\</html>
            ;

            try ctx.renderHtml(html.{ token, token });
        },

        // API: 获取 Token
        fn getTokenApiHandler(ctx: *zfinal.Context) !void {
            const token = try tm.generate();
            defer ctx.allocator.free(token);

            try ctx.renderJson(.{
                .token = token,
                .expires_in = 300,
                .message = "Token generated, use it within 5 minutes",
            });
        },

        // API: 提交表单（需要 Token）- 使用拦截器
        fn submitApiHandler(ctx: *zfinal.Context) !void {
            const data = ctx.getParam("data") orelse "no data";

            try ctx.renderJson(.{
                .success = true,
                .message = "Form submitted successfully!",
                .data = data,
                .note = "This token is now invalid. Get a new one for next submission.",
            });
        },
    };

    Handlers.tm = &token_manager;

    // Web 路由
    try app.get("/form", Handlers.getFormHandler);

    // API 路由 - 需要 Token 拦截器保护
    try app.get("/api/token", Handlers.getTokenApiHandler);
    try app.addRoute("/api/submit", Handlers.submitApiHandler);
    // 添加拦截器到提交路由
    // 注意: 拦截器会在处理器之前执行 Token 验证

    // 启动信息
    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🔐 Token Demo - 防止表单重复提交\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: http://localhost:8080\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Endpoints:\n", .{});
    std.debug.print("  GET  /form           - 表单页面（带 Token）\n", .{});
    std.debug.print("  GET  /api/token      - 获取 API Token\n", .{});
    std.debug.print("  POST /api/submit     - 提交表单（需要 Token）\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Usage (API方式):\n", .{});
    std.debug.print("1. Get token:\n", .{});
    std.debug.print("   curl http://localhost:8080/api/token\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("2. Submit with token (first time - success):\n", .{});
    std.debug.print("   curl -X POST http://localhost:8080/api/submit \\\n", .{});
    std.debug.print("     -d '_token=YOUR_TOKEN&data=hello'\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("3. Try to submit again (should fail - token already used):\n", .{});
    std.debug.print("   curl -X POST http://localhost:8080/api/submit \\\n", .{});
    std.debug.print("     -d '_token=YOUR_TOKEN&data=hello'\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Web UI: Open http://localhost:8080/form in browser\n", .{});
    std.debug.print("\n", .{});

    try app.start();
}
