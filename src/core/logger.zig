const std = @import("std");
const io_instance = @import("../io_instance.zig");

/// Log level enumeration
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Structured logger for production use
pub const Logger = struct {
    allocator: std.mem.Allocator,
    min_level: LogLevel,
    json_format: bool,

    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{
            .allocator = allocator,
            .min_level = .info,
            .json_format = false,
        };
    }

    pub fn initJson(allocator: std.mem.Allocator) Logger {
        return .{
            .allocator = allocator,
            .min_level = .info,
            .json_format = true,
        };
    }

    pub fn setLevel(self: *Logger, level: LogLevel) void {
        self.min_level = level;
    }

    fn shouldLog(self: *const Logger, level: LogLevel) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLog(level)) return;

        if (self.json_format) {
            self.logJson(level, fmt, args);
        } else {
            self.logText(level, fmt, args);
        }
    }

    fn logText(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const level_str = level.asString();
        const now = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "format error";

        std.debug.print("[{d}] [{s}] {s}\n", .{ now, level_str, msg });
    }

    fn logJson(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        const level_str = level.asString();
        const now = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "format error";

        // Escape quotes in message
        var esc_buf: [2048]u8 = undefined;
        var esc_pos: usize = 0;
        for (msg) |c| {
            if (c == '"' or c == '\\') {
                if (esc_pos < esc_buf.len - 1) {
                    esc_buf[esc_pos] = '\\';
                    esc_pos += 1;
                }
            }
            if (esc_pos < esc_buf.len) {
                esc_buf[esc_pos] = c;
                esc_pos += 1;
            }
        }
        const esc_msg = esc_buf[0..esc_pos];

        std.debug.print("{{" ++ "\"timestamp\":{d},\"level\":\"{s}\",\"message\":\"{s}\"" ++ "}}\n", .{
            now, level_str, esc_msg,
        });
    }
};

/// Request context logger for HTTP access logs
pub const RequestLogger = struct {
    logger: *Logger,
    request_id: []const u8,
    start_time: i64,

    pub fn init(logger: *Logger, request_id: []const u8) RequestLogger {
        return .{
            .logger = logger,
            .request_id = request_id,
            .start_time = std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds(),
        };
    }

    pub fn logAccess(self: *RequestLogger, method: []const u8, path: []const u8, status: u16) void {
        const duration = std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds() - self.start_time;
        self.logger.info("[{s}] {s} {s} {d} {d}ms", .{
            self.request_id,
            method,
            path,
            status,
            duration,
        });
    }
};

/// Global logger instance (set by application)
pub var global_logger: ?Logger = null;

/// Initialize global logger
pub fn initGlobalLogger(logger: Logger) void {
    global_logger = logger;
}

/// Get global logger or a no-op fallback
pub fn getLogger() *Logger {
    if (global_logger) |*gl| {
        return gl;
    }
    // Fallback: initialize a default logger on first use
    // This is a bit of a hack but works for single-threaded init
    global_logger = Logger.init(std.heap.page_allocator);
    return &global_logger.?;
}

test "logger basic" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.debug);

    logger.debug("test debug {d}", .{1});
    logger.info("test info {s}", .{"hello"});
    logger.warn("test warn {}", .{true});
    logger.err("test err {}", .{error.Failed});
}

test "logger json format" {
    var logger = Logger.initJson(std.testing.allocator);
    logger.setLevel(.info);

    logger.info("user login: {s}", .{"alice"});
}
