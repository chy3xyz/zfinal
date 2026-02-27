const std = @import("std");
const zfinal = @import("zfinal");

/// 全局状态 - 用于在示例中共享数据库连接等资源
pub const State = struct {
    db: *zfinal.DB,
    allocator: std.mem.Allocator,
};

/// 全局状态实例
pub var global_state: ?State = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize ZFinal
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    // Configure Database (SQLite)
    const db_config = zfinal.DBConfig.sqlite("pocketbase_lite.db");

    // Initialize Global DB
    var db = try zfinal.DB.init(allocator, db_config);
    errdefer db.deinit();

    // Initialize global state
    global_state = State{
        .db = &db,
        .allocator = allocator,
    };
    defer global_state = null;

    // Initialize System Tables
    try initSystemTables();

    // Register Routes
    try registerRoutes(&app);

    // Start Server
    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  📦 PocketBase Lite Demo\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: http://localhost:8090\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Admin UI:\n", .{});
    std.debug.print("  GET  /              → Redirect to admin\n", .{});
    std.debug.print("  GET  /admin/login   → Admin login page\n", .{});
    std.debug.print("  POST /admin/login   → Login (email=admin@example.com, password=password)\n", .{});
    std.debug.print("  GET  /admin/dashboard → Admin dashboard\n", .{});
    std.debug.print("  GET  /admin/collections → Manage collections\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("REST API:\n", .{});
    std.debug.print("  GET    /api/collections                    → List all collections\n", .{});
    std.debug.print("  GET    /api/collections/:name/records     → List records\n", .{});
    std.debug.print("  GET    /api/collections/:name/records/:id → Get single record\n", .{});
    std.debug.print("  POST   /api/collections/:name/records     → Create record\n", .{});
    std.debug.print("  PATCH  /api/collections/:name/records/:id → Update record\n", .{});
    std.debug.print("  DELETE /api/collections/:name/records/:id → Delete record\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("API Authentication:\n", .{});
    std.debug.print("  Include header: Authorization: Bearer <token>\n", .{});
    std.debug.print("  Default token stored in database\n", .{});
    std.debug.print("\n", .{});

    app.setPort(8090);
    try app.start();
}

fn initSystemTables() !void {
    const db = global_state.?.db;

    // Admin Table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS _admins (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  email TEXT UNIQUE NOT NULL,
        \\  password_hash TEXT NOT NULL,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Create default admin if not exists
    // Password: "password" (SHA256 hash)
    try db.exec(
        \\INSERT OR IGNORE INTO _admins (email, password_hash) 
        \\VALUES ('admin@example.com', '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8')
    );

    // API Tokens Table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS _api_tokens (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  token TEXT UNIQUE NOT NULL,
        \\  user_id TEXT,
        \\  expires_at INTEGER,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // Create a default API token for testing
    const Token = @import("src/auth/token.zig");
    const check_sql = try std.fmt.allocPrintZ(global_state.?.allocator, "SELECT COUNT(*) as count FROM _api_tokens", .{});
    defer global_state.?.allocator.free(check_sql);
    var rs = try db.query(check_sql);
    defer rs.deinit();

    var needs_token = true;
    if (rs.next()) {
        const row = rs.getCurrentRowMap().?;
        if (row.get("count")) |count_str| {
            const count = try std.fmt.parseInt(i64, count_str, 10);
            needs_token = count == 0;
        }
    }

    if (needs_token) {
        const token = try Token.createToken("demo_user", null, db, global_state.?.allocator);
        std.debug.print("Default API token: {s}\n", .{token});
    }

    // Collections metadata table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS _collections (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT UNIQUE NOT NULL,
        \\  type TEXT DEFAULT 'base',
        \\  system INTEGER DEFAULT 0,
        \\  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    );
}

fn registerRoutes(app: *zfinal.ZFinal) !void {
    // === Admin Routes (UI) ===
    const AdminAuth = @import("src/controller/admin/auth_controller.zig");
    const AdminCollection = @import("src/controller/admin/collection_controller.zig");
    const AdminRecord = @import("src/controller/admin/record_controller.zig");

    // Root redirects to admin
    try app.get("/", AdminAuth.index);

    // Admin authentication
    try app.get("/admin/login", AdminAuth.loginPage);
    try app.post("/admin/login", AdminAuth.login);
    try app.get("/admin/logout", AdminAuth.logout);
    try app.get("/admin/dashboard", AdminAuth.dashboard);

    // Admin collection management
    try app.get("/admin/collections", AdminCollection.list);
    try app.post("/admin/collections", AdminCollection.create);
    try app.post("/admin/collections/:name/delete", AdminCollection.delete);

    // Admin record management
    try app.get("/admin/collections/:table/records", AdminRecord.list);
    try app.post("/admin/collections/:table/records", AdminRecord.create);
    try app.post("/admin/collections/:table/records/:id/delete", AdminRecord.delete);

    // === Public API Routes (JSON) ===
    const CollectionAPI = @import("src/controller/api/collection_api.zig");
    const RecordAPI = @import("src/controller/api/record_api.zig");

    // Collections
    try app.get("/api/collections", CollectionAPI.list);

    // Records CRUD with API auth
    try app.get("/api/collections/:name/records", RecordAPI.list);
    try app.get("/api/collections/:name/records/:id", RecordAPI.get);
    try app.post("/api/collections/:name/records", RecordAPI.create);
    try app.patch("/api/collections/:name/records/:id", RecordAPI.update);
    try app.delete("/api/collections/:name/records/:id", RecordAPI.delete);
}
