const std = @import("std");
const zfinal = @import("zfinal");

/// 验证码演示 - 展示如何使用验证码功能
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建验证码管理器
    var captcha_manager = zfinal.CaptchaManager.init(allocator);
    defer captcha_manager.deinit();

    captcha_manager.setTTL(300); // 5 分钟有效期
    captcha_manager.setLength(4); // 4 位验证码

    // 创建应用
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(8080);

    // 路由 - 使用内联函数捕获 captcha_manager
    const Handlers = struct {
        var cm: *zfinal.CaptchaManager = undefined,

        fn getCaptchaHandler(ctx: *zfinal.Context) !void {
            // 生成 session ID
            const session_id = try zfinal.RandomKit.uuid(ctx.allocator);
            defer ctx.allocator.free(session_id);

            // 生成验证码 - 支持多种类型
            const captcha_type = zfinal.CaptchaType.alphanumeric;
            const captcha = try cm.generate(captcha_type, session_id);
            defer captcha.deinit();

            // 在实际应用中，这里应该返回图片
            // 这里演示返回 JSON 格式的验证码信息
            try ctx.renderJson(.{
                .session_id = session_id,
                .code = captcha.code, // 实际应返回图片，这里用于验证
                .captcha_type = @tagName(captcha_type),
                .message = "验证码已生成，有效期5分钟",
            });
        },

        fn verifyHandler(ctx: *zfinal.Context) !void {
            const session_id = ctx.getParam("session_id") orelse {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "Missing session_id" });
                return;
            };

            const code = ctx.getParam("code") orelse {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{ .@"error" = "Missing code" });
                return;
            };

            // 验证验证码
            const valid = try cm.validate(session_id, code);

            if (valid) {
                try ctx.renderJson(.{
                    .success = true,
                    .message = "验证码验证成功！",
                });
            } else {
                ctx.res_status = .bad_request;
                try ctx.renderJson(.{
                    .success = false,
                    .message = "验证码错误或已过期",
                });
            }
        },
    };

    Handlers.cm = &captcha_manager;

    try app.get("/captcha", Handlers.getCaptchaHandler);
    try app.post("/verify", Handlers.verifyHandler);

    // 启动信息
    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🔐 Captcha Demo - 验证码演示\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: http://localhost:8080\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Usage:\n", .{});
    std.debug.print("1. Get captcha:\n", .{});
    std.debug.print("   curl http://localhost:8080/captcha\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("2. Verify captcha:\n", .{});
    std.debug.print("   curl -X POST http://localhost:8080/verify \\\n", .{});
    std.debug.print("     -d 'session_id=YOUR_SESSION_ID&code=ABCD'\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Captcha Types (修改代码使用):\n", .{});
    std.debug.print("  - numeric: 纯数字 (如 1234)\n", .{});
    std.debug.print("  - alpha: 纯字母 (如 ABCD)\n", .{});
    std.debug.print("  - alphanumeric: 字母+数字 (如 A1B2)\n", .{});
    std.debug.print("  - math: 数学运算 (如 3+5=8)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Full example:\n", .{});
    std.debug.print("   # 获取验证码\n", .{});
    std.debug.print("   SESSION_ID=$(curl -s http://localhost:8080/captcha | jq -r '.session_id')\n", .{});
    std.debug.print("   CODE=$(curl -s http://localhost:8080/captcha | jq -r '.code')\n", .{});
    std.debug.print("   \n", .{});
    std.debug.print("   # 验证\n", .{});
    std.debug.print("   curl -X POST http://localhost:8080/verify \\\n", .{});
    std.debug.print("     -d \"session_id=$SESSION_ID&code=$CODE\"\n", .{});
    std.debug.print("\n", .{});

    try app.start();
}
