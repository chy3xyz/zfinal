const std = @import("std");
const builtin = @import("builtin");
const io_instance = @import("../io_instance.zig");

/// Compile-time log level floor. Build with `zig build -Dlog-level=debug`.
/// When running `zig test` directly, defaults to .info.
pub const LOG_LEVEL: LogLevel = if (@hasDecl(@import("root"), "build_options"))
    parseLevelStr(@import("build_options").log_level)
else
    .info;

fn parseLevelStr(s: []const u8) LogLevel {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "err")) return .err;
    return .info;
}

/// Log level enumeration
pub const LogLevel = enum(u2) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Log backend — where log output goes.
pub const Backend = union(enum) {
    /// Write to stderr (default)
    stderr,
    /// Custom writer (for files, testing, sockets, etc.)
    writer: *std.Io.Writer,

    pub fn default() Backend {
        return .stderr;
    }
};

/// A structured key-value field for log entries.
pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,

        pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .string => |s| try writer.writeAll(s),
                .int => |i| try writer.print("{d}", .{i}),
                .float => |f| try writer.print("{d}", .{f}),
                .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            }
        }
    };
};

/// Structured logger with pluggable backends and compile-time level filtering.
pub const Logger = struct {
    allocator: std.mem.Allocator,
    min_level: LogLevel = .info,
    backend: Backend = .stderr,
    /// Prefix added to every log line (e.g. service name).
    prefix: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Logger {
        return .{ .allocator = allocator };
    }

    pub fn setLevel(self: *Logger, level: LogLevel) void {
        self.min_level = level;
    }

    pub fn setBackend(self: *Logger, backend: Backend) void {
        self.backend = backend;
    }

    fn shouldLog(self: *const Logger, level: LogLevel) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level) and
            @intFromEnum(level) >= @intFromEnum(LOG_LEVEL);
    }

    fn writeOutput(self: *Logger, data: []const u8) void {
        switch (self.backend) {
            .stderr => std.debug.print("{s}", .{data}),
            .writer => |w| w.writeAll(data) catch {},
        }
    }

    /// Log a message with structured key=value fields (slice form).
    pub fn logSlice(self: *Logger, level: LogLevel, msg: []const u8, fields: []const Field) void {
        if (!self.shouldLog(level)) return;
        self.writeLogLine(level, msg, fields);
    }

    /// Log a message with structured key=value fields (comptime tuple form).
    pub fn log(self: *Logger, level: LogLevel, comptime msg: []const u8, fields: anytype) void {
        if (!self.shouldLog(level)) return;
        const field_array = comptimeFieldsToSlice(fields);
        self.writeLogLine(level, msg, &field_array);
    }

    fn comptimeFieldsToSlice(fields: anytype) [fields.len]Field {
        var result: [fields.len]Field = undefined;
        inline for (fields, 0..) |f, i| {
            result[i] = f;
        }
        return result;
    }

    fn writeLogLine(self: *Logger, level: LogLevel, msg: []const u8, fields: []const Field) void {
        const level_str = level.asString();
        const now_sec = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;

        const wrote = std.fmt.bufPrint(buf[pos..], "[{d}] [{s}] ", .{ now_sec, level_str }) catch return;
        pos += wrote.len;

        if (self.prefix.len > 0) {
            const p = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{self.prefix}) catch return;
            pos += p.len;
        }

        const msg_wrote = std.fmt.bufPrint(buf[pos..], "{s}", .{msg}) catch return;
        pos += msg_wrote.len;

        for (fields) |field| {
            const sep = std.fmt.bufPrint(buf[pos..], " ", .{}) catch return;
            pos += sep.len;
            const key = std.fmt.bufPrint(buf[pos..], "{s}=", .{field.key}) catch return;
            pos += key.len;
            const val = switch (field.value) {
                .string => |s| std.fmt.bufPrint(buf[pos..], "{s}", .{s}) catch return,
                .int => |i| std.fmt.bufPrint(buf[pos..], "{d}", .{i}) catch return,
                .float => |f| std.fmt.bufPrint(buf[pos..], "{d}", .{f}) catch return,
                .bool => |b| std.fmt.bufPrint(buf[pos..], "{s}", .{if (b) "true" else "false"}) catch return,
            };
            pos += val.len;
        }

        const nl = std.fmt.bufPrint(buf[pos..], "\n", .{}) catch return;
        pos += nl.len;

        self.writeOutput(buf[0..pos]);
    }

    /// Log with format string (convenience for simple messages).
    pub fn logFmt(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!self.shouldLog(level)) return;

        const level_str = level.asString();
        const now_sec = std.Io.Timestamp.now(io_instance.io, .real).toSeconds();

        var buf: [4096]u8 = undefined;
        var msg_buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "format error";

        const line = std.fmt.bufPrint(&buf, "[{d}] [{s}] {s}\n", .{ now_sec, level_str, msg }) catch return;
        self.writeOutput(line);
    }

    pub fn debug(self: *Logger, comptime msg: []const u8, fields: anytype) void {
        self.log(.debug, msg, fields);
    }

    pub fn info(self: *Logger, comptime msg: []const u8, fields: anytype) void {
        self.log(.info, msg, fields);
    }

    pub fn warn(self: *Logger, comptime msg: []const u8, fields: anytype) void {
        self.log(.warn, msg, fields);
    }

    pub fn err(self: *Logger, comptime msg: []const u8, fields: anytype) void {
        self.log(.err, msg, fields);
    }

    /// Convenience: log with format string.
    pub fn debugFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.debug, fmt, args);
    }
    pub fn infoFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.info, fmt, args);
    }
    pub fn warnFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.warn, fmt, args);
    }
    pub fn errFmt(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.logFmt(.err, fmt, args);
    }
};

/// HTTP request logger — emits structured access log entries.
pub const RequestLogger = struct {
    logger: *Logger,
    start_time: i64,
    method: []const u8,
    path: []const u8,
    remote_addr: ?[]const u8,

    pub fn begin(logger: *Logger, method: []const u8, path: []const u8, remote_addr: ?[]const u8) RequestLogger {
        return .{
            .logger = logger,
            .start_time = std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds(),
            .method = method,
            .path = path,
            .remote_addr = remote_addr,
        };
    }

    pub fn finish(self: *RequestLogger, status: u16, response_bytes: usize) void {
        const duration = std.Io.Timestamp.now(io_instance.io, .real).toMilliseconds() - self.start_time;
        var fields: [6]Field = undefined;
        var n: usize = 0;
        fields[n] = Field{ .key = "method", .value = .{ .string = self.method } }; n += 1;
        fields[n] = Field{ .key = "path", .value = .{ .string = self.path } }; n += 1;
        fields[n] = Field{ .key = "status", .value = .{ .int = status } }; n += 1;
        fields[n] = Field{ .key = "duration_ms", .value = .{ .int = duration } }; n += 1;
        fields[n] = Field{ .key = "bytes", .value = .{ .int = @intCast(response_bytes) } }; n += 1;
        if (self.remote_addr) |addr| {
            fields[n] = Field{ .key = "ip", .value = .{ .string = addr } }; n += 1;
        }
        self.logger.logSlice(.info, "request", fields[0..n]);
    }
};

/// Global logger instance (set by application at startup).
pub var global_logger: ?Logger = null;

pub fn initGlobalLogger(logger: Logger) void {
    global_logger = logger;
}

pub fn getLogger() *Logger {
    if (global_logger) |*gl| return gl;
    // Fallback: init on first use
    global_logger = Logger.init(std.heap.page_allocator);
    return &global_logger.?;
}

// ============================================================================
// Tests
// ============================================================================

test "logger basic" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.debug);

    logger.debug("test debug", .{});
    logger.info("test info", .{});
    logger.warn("test warn", .{});
    logger.err("test err", .{});
}

test "logger with fields" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.info);

    logger.info("request handled", .{
        Field{ .key = "method", .value = .{ .string = "GET" } },
        Field{ .key = "path", .value = .{ .string = "/api/users" } },
        Field{ .key = "status", .value = .{ .int = 200 } },
        Field{ .key = "duration_ms", .value = .{ .int = 12 } },
    });
}

test "logger level filtering" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.warn);

    logger.debug("should not appear", .{});
    logger.info("should not appear", .{});
    logger.warn("should appear", .{});
    logger.err("should appear", .{});
}

test "logger format convenience" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.info);

    logger.infoFmt("user {s} logged in", .{"alice"});
    logger.errFmt("failed with error: {}", .{@as(u8, 42)});
}

test "request logger" {
    var logger = Logger.init(std.testing.allocator);
    logger.setLevel(.info);

    var rl = RequestLogger.begin(&logger, "POST", "/api/login", "127.0.0.1");
    rl.finish(200, 512);
}

test "backend writer" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    var writer = std.Io.Writer.Allocating.init(allocator);
    var logger = Logger.init(allocator);
    logger.setLevel(.info);
    logger.setBackend(.{ .writer = &writer.writer });
    logger.info("writer log test", .{});

    const output = try writer.toOwnedSlice();
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "writer log test") != null);
}
