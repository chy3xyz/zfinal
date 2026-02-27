const std = @import("std");
const zfinal = @import("zfinal");

/// 初始化数据库表
pub fn initDatabase(db: *zfinal.DB) !void {
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
