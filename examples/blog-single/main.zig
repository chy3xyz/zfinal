const std = @import("std");
const zfinal = @import("zfinal");

// ============ Models ============

pub const User = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
    created_at: ?[]const u8 = null,
};

pub const Post = struct {
    title: []const u8,
    content: []const u8,
    author_id: i64,
    published: bool = false,
    created_at: ?[]const u8 = null,
};

pub const Comment = struct {
    post_id: i64,
    author_id: i64,
    content: []const u8,
    created_at: ?[]const u8 = null,
};

pub const UserModel = zfinal.Model(User, "users");
pub const PostModel = zfinal.Model(Post, "posts");
pub const CommentModel = zfinal.Model(Comment, "comments");

// ============ Controllers ============

/// 用户控制器
pub const UserController = struct {
    /// 用户列表
    pub fn index(ctx: *zfinal.Context) !void {
        // TODO: 实现分页查询
        try ctx.renderJson(.{
            .message = "User list",
            .users = .{},
        });
    }

    /// 获取用户详情
    pub fn show(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing user ID" });
            return;
        };

        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Invalid user ID" });
            return;
        };

        // TODO: 从数据库查询用户
        try ctx.renderJson(.{
            .id = id,
            .username = "demo_user",
            .email = "demo@example.com",
        });
    }

    /// 创建用户
    pub fn create(ctx: *zfinal.Context) !void {
        const username = (try ctx.getPara("username")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing username" });
            return;
        };

        const email = (try ctx.getPara("email")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing email" });
            return;
        };

        const password = (try ctx.getPara("password")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing password" });
            return;
        };

        // 验证
        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("username", username);
        try validator.validateEmail("email", email);
        try validator.validateMinLength("password", password, 6);
        try validator.validateMaxLength("password", password, 100);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        // TODO: 保存到数据库
        try ctx.renderJson(.{
            .message = "User created",
            .username = username,
            .email = email,
        });
    }
};

/// 文章控制器
pub const PostController = struct {
    /// 文章列表
    pub fn index(ctx: *zfinal.Context) !void {
        const page = try ctx.getParaToIntDefault("page", 1);
        const page_size = try ctx.getParaToIntDefault("page_size", 10);

        try ctx.renderJson(.{
            .message = "Post list",
            .page = page,
            .page_size = page_size,
            .posts = .{},
        });
    }

    /// 获取文章详情
    pub fn show(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Invalid post ID" });
            return;
        };

        try ctx.renderJson(.{
            .id = id,
            .title = "Sample Post",
            .content = "This is a sample blog post.",
            .author_id = 1,
            .published = true,
        });
    }

    /// 创建文章
    pub fn create(ctx: *zfinal.Context) !void {
        const title = (try ctx.getPara("title")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing title" });
            return;
        };

        const content = (try ctx.getPara("content")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing content" });
            return;
        };

        // 验证
        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("title", title);
        try validator.validateMinLength("title", title, 1);
        try validator.validateMaxLength("title", title, 200);
        try validator.validateRequired("content", content);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "Post created",
            .title = title,
        });
    }

    /// 更新文章
    pub fn update(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const title = (try ctx.getPara("title"));
        const content = (try ctx.getPara("content"));

        try ctx.renderJson(.{
            .message = "Post updated",
            .id = id_str,
            .title = title,
            .content = content,
        });
    }

    /// 删除文章
    pub fn delete(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Post deleted",
            .id = id_str,
        });
    }
};

/// 评论控制器
pub const CommentController = struct {
    /// 获取文章的评论
    pub fn index(ctx: *zfinal.Context) !void {
        const post_id = ctx.getPathParam("post_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Comments for post",
            .post_id = post_id,
            .comments = .{},
        });
    }

    /// 创建评论
    pub fn create(ctx: *zfinal.Context) !void {
        const post_id = ctx.getPathParam("post_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing post ID" });
            return;
        };

        const content = (try ctx.getPara("content")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing content" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Comment created",
            .post_id = post_id,
            .content = content,
        });
    }
};

// ============ Interceptors ============

/// 日志拦截器
fn loggingBefore(ctx: *zfinal.Context) !bool {
    const method = @tagName(ctx.req.head.method);
    const path = ctx.req.head.target;
    std.debug.print("[{s}] {s}\n", .{ method, path });
    return true;
}

pub const LoggingInterceptor = zfinal.Interceptor{
    .name = "logging",
    .before = loggingBefore,
};

/// 认证拦截器（示例）
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "Unauthorized" });
        return error.Unauthorized;
    }
    return true;
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};

// ============ Main Application ============

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化数据库
    const config = zfinal.DBConfig.sqlite("blog.db");
    var db = try zfinal.DB.init(allocator, config);
    defer db.deinit();

    // 创建表
    try initDatabase(&db);

    // 创建应用
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(8080);

    // 添加全局拦截器
    try app.addGlobalInterceptor(LoggingInterceptor);

    // ============ 路由配置 ============

    // 首页
    try app.get("/", indexHandler);

    // 用户路由
    try app.get("/api/users", UserController.index);
    try app.get("/api/users/:id", UserController.show);
    try app.post("/api/users", UserController.create);

    // 文章路由（RESTful）
    try app.get("/api/posts", PostController.index);
    try app.get("/api/posts/:id", PostController.show);
    try app.post("/api/posts", PostController.create);
    try app.put("/api/posts/:id", PostController.update);
    try app.delete("/api/posts/:id", PostController.delete);

    // 评论路由
    try app.get("/api/posts/:post_id/comments", CommentController.index);
    try app.post("/api/posts/:post_id/comments", CommentController.create);

    // 启动服务器
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
    std.debug.print("  curl http://localhost:8080/api/posts/1\n", .{});
    std.debug.print("  curl -X POST http://localhost:8080/api/users \\\n", .{});
    std.debug.print("    -d 'username=alice&email=alice@example.com&password=secret123'\n", .{});
    std.debug.print("\n", .{});

    try app.start();
}

/// 首页处理器
fn indexHandler(ctx: *zfinal.Context) !void {
    try ctx.renderJson(.{
        .message = "Welcome to zfinal Blog!",
        .version = "0.1.0",
        .endpoints = .{
            .users = "/api/users",
            .posts = "/api/posts",
        },
    });
}

/// 初始化数据库
fn initDatabase(db: *zfinal.DB) !void {
    // 创建用户表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT NOT NULL UNIQUE,
        \\    email TEXT NOT NULL UNIQUE,
        \\    password TEXT NOT NULL,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // 创建文章表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    title TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    author_id INTEGER NOT NULL,
        \\    published BOOLEAN DEFAULT 0,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (author_id) REFERENCES users(id)
        \\)
    );

    // 创建评论表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS comments (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    post_id INTEGER NOT NULL,
        \\    author_id INTEGER NOT NULL,
        \\    content TEXT NOT NULL,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (post_id) REFERENCES posts(id),
        \\    FOREIGN KEY (author_id) REFERENCES users(id)
        \\)
    );

    std.debug.print("✅ Database initialized\n", .{});
}
