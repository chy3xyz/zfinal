const std = @import("std");
const zfinal = @import("zfinal");
const Config = @import("config/config.zig");
const Routes = @import("config/routes.zig");
const DbInit = @import("config/db_init.zig");
const Interceptors = @import("interceptor/interceptors.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化数据库
    const db_config = Config.DBConfig.get();
    var db = try zfinal.DB.init(allocator, db_config);
    defer db.deinit();

    // 创建表
    try DbInit.initDatabase(&db);

    // 创建应用
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(Config.ServerConfig.port);

    // 添加全局拦截器
    try app.addGlobalInterceptor(Interceptors.LoggingInterceptor);

    // 配置路由
    try Routes.configRoutes(&app);

    // 打印启动信息
    printStartupInfo();

    // 启动服务器
    try app.start();
}

fn printStartupInfo() void {
    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🚀 Blog Application Started!\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: http://localhost:8080\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("API Endpoints:\n", .{});
    std.debug.print("  GET    /                           - 首页\n", .{});
    std.debug.print("  GET    /api/users                  - 用户列表\n", .{});
    std.debug.print("  GET    /api/users/:id              - 用户详情\n", .{});
    std.debug.print("  POST   /api/users                  - 创建用户\n", .{});
    std.debug.print("  GET    /api/posts                  - 文章列表\n", .{});
    std.debug.print("  GET    /api/posts/:id              - 文章详情\n", .{});
    std.debug.print("  POST   /api/posts                  - 创建文章\n", .{});
    std.debug.print("  PUT    /api/posts/:id              - 更新文章\n", .{});
    std.debug.print("  DELETE /api/posts/:id              - 删除文章\n", .{});
    std.debug.print("  GET    /api/posts/:post_id/comments - 评论列表\n", .{});
    std.debug.print("  POST   /api/posts/:post_id/comments - 创建评论\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Test commands:\n", .{});
    std.debug.print("  curl http://localhost:8080/\n", .{});
    std.debug.print("  curl http://localhost:8080/api/posts\n", .{});
    std.debug.print("  curl -X POST http://localhost:8080/api/users \\\n", .{});
    std.debug.print("    -d 'username=alice&email=alice@example.com&password=secret123'\n", .{});
    std.debug.print("\n", .{});
}
