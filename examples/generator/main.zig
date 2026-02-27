const std = @import("std");
const zfinal = @import("zfinal");

/// 代码生成器示例 - 从数据库表自动生成 Model 代码
///
/// 本示例演示如何使用 ZFinal 的代码生成器从现有数据库表
/// 自动生成 Model 代码，加速开发。
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 连接数据库 (SQLite)
    const db_path = "generator_demo.db";
    const config = zfinal.DBConfig.sqlite(db_path);
    var db = try zfinal.DB.init(allocator, config);
    defer db.deinit();

    std.debug.print("==============================================\n", .{});
    std.debug.print("  🔧 ZFinal 代码生成器演示\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Database: {s}\n", .{db_path});
    std.debug.print("\n", .{});

    // 创建示例表 (users)
    std.debug.print("Creating sample tables...\n", .{});

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    user_name TEXT NOT NULL UNIQUE,
        \\    email TEXT NOT NULL,
        \\    password_hash TEXT NOT NULL,
        \\    age INTEGER,
        \\    is_active BOOLEAN DEFAULT 1,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TEXT
        \\)
    );

    // 创建示例表 (posts)
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    title TEXT NOT NULL,
        \\    content TEXT,
        \\    user_id INTEGER NOT NULL,
        \\    view_count INTEGER DEFAULT 0,
        \\    is_published BOOLEAN DEFAULT 0,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    published_at TEXT,
        \\    FOREIGN KEY (user_id) REFERENCES users(id)
        \\)
    );

    // 创建示例表 (comments)
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS comments (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    post_id INTEGER NOT NULL,
        \\    user_id INTEGER NOT NULL,
        \\    content TEXT NOT NULL,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (post_id) REFERENCES posts(id),
        \\    FOREIGN KEY (user_id) REFERENCES users(id)
        \\)
    );

    // 创建 models 目录
    try createModelsDir();

    // 显示数据库中的表
    std.debug.print("\nTables in database:\n", .{});
    std.debug.print("  - users\n", .{});
    std.debug.print("  - posts\n", .{});
    std.debug.print("  - comments\n", .{});
    std.debug.print("\n", .{});

    // 运行生成器
    std.debug.print("Generating Model code...\n", .{});

    var generator = zfinal.Generator.init(allocator, &db, "models");
    try generator.generateAll();

    std.debug.print("\n✅ Model 生成完成！\n", .{});
    std.debug.print("\nGenerated files:\n", .{});
    std.debug.print("  models/user.zig\n", .{});
    std.debug.print("  models/post.zig\n", .{});
    std.debug.print("  models/comment.zig\n", .{});
    std.debug.print("\n", .{});

    // 展示生成的代码示例
    std.debug.print("Generated code preview (user.zig):\n", .{});
    std.debug.print("-----------------------------------\n", .{});
    try showGeneratedCodePreview("models/user.zig");
    std.debug.print("\n", .{});

    std.debug.print("Usage:\n", .{});
    std.debug.print("  1. Copy generated models to your project\n", .{});
    std.debug.print("  2. Use generated Model for CRUD operations:\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("     // Query all users\n", .{});
    std.debug.print("     const users = try UserModel.findAll(&db, allocator);\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("     // Find by ID\n", .{});
    std.debug.print("     const user = try UserModel.findById(&db, 1, allocator);\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("     // Create new user\n", .{});
    std.debug.print("     var newUser = UserModel.Instance{\n", .{});
    std.debug.print("         .data = User{\n", .{});
    std.debug.print("             .user_name = \"alice\",\n", .{});
    std.debug.print("             .email = \"alice@example.com\",\n", .{});
    std.debug.print("             .password_hash = \"...\",\n", .{});
    std.debug.print("             .age = 25\n", .{});
    std.debug.print("         }\n", .{});
    std.debug.print("     };\n", .{});
    std.debug.print("     try newUser.save(&db);\n", .{});
    std.debug.print("\n", .{});
}

fn createModelsDir() !void {
    // 创建 models 目录
    std.fs.cwd().makeDir("models") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn showGeneratedCodePreview(path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        std.debug.print("(File not generated yet)\n", .{});
        return;
    };
    defer file.close();

    var buf: [2000]u8 = undefined;
    const n = try file.read(&buf);
    std.debug.print("{s}", .{buf[0..n]});
}
