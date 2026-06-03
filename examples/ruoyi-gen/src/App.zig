const std = @import("std");
const zfinal = @import("zfinal");

pub const App = struct {
    allocator: std.mem.Allocator,
    zf: zfinal.ZFinal,
    pool: zfinal.ConnectionPool,

    /// Initialize database + pool + ZFinal instance.
    pub fn init(
        allocator: std.mem.Allocator,
        db_cfg: zfinal.DBConfig,
        server_cfg: zfinal.ServerConfig,
    ) !App {
        var db = try zfinal.DB.init(allocator, db_cfg);
        errdefer db.deinit();
        try ensureSchema(&db);
        var zf = zfinal.ZFinal.init(allocator);
        zf.config = server_cfg;

        return .{
            .allocator = allocator,
            .zf = zf,
            .pool = zfinal.ConnectionPool.init(allocator, db_cfg, 8),
        };
    }

    pub fn deinit(self: *App) void {
        self.pool.deinit();
        self.zf.deinit();
    }

    pub fn start(self: *App) !void {
        try self.zf.start();
    }

    // ── Route registration helpers ──

    pub fn get(self: *App, path: []const u8, handler: anytype) !void {
        try self.zf.get(path, handler);
    }

    pub fn post(self: *App, path: []const u8, handler: anytype) !void {
        try self.zf.post(path, handler);
    }

    pub fn put(self: *App, path: []const u8, handler: anytype) !void {
        try self.zf.put(path, handler);
    }

    pub fn delete(self: *App, path: []const u8, handler: anytype) !void {
        try self.zf.delete(path, handler);
    }

    pub fn patch(self: *App, path: []const u8, handler: anytype) !void {
        try self.zf.patch(path, handler);
    }

    pub fn addGlobalMiddleware(self: *App, mw: zfinal.Interceptor) !void {
        try self.zf.addGlobalInterceptor(mw);
    }
};

// ── Schema migration ──
// Dev: auto-create tables. Production: use zf migrate.
fn ensureSchema(db: *zfinal.DB) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS users (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT," ++
        "name TEXT NOT NULL," ++
        "created_at DATETIME DEFAULT CURRENT_TIMESTAMP)");
}