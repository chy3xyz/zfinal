const std = @import("std");
fn getIo() std.Io {
    return @import("../io_instance.zig").io;
}

/// Server metrics for health checks and monitoring.
pub const Metrics = struct {
    /// When the server started (Unix timestamp in seconds).
    start_time: i64,
    /// Total number of accepted connections.
    total_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total number of HTTP requests processed.
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Requests by status category.
    responses_2xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    responses_3xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    responses_4xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    responses_5xx: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Ring buffer for recent errors (last N errors). Access via recordError only.
    recent_errors: std.ArrayList(ErrorEntry),
    max_error_entries: usize = 50,
    allocator: std.mem.Allocator,

    pub const ErrorEntry = struct {
        timestamp: i64,
        message: []const u8,
        path: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{
            .start_time = std.Io.Timestamp.now(getIo(), .real).toSeconds(),
            .recent_errors = std.ArrayList(ErrorEntry).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Metrics) void {
        for (self.recent_errors.items) |entry| {
            self.allocator.free(entry.message);
            self.allocator.free(entry.path);
        }
        self.recent_errors.deinit(self.allocator);
    }

    pub fn recordConnection(self: *Metrics) void {
        _ = self.total_connections.fetchAdd(1, .monotonic);
    }

    pub fn recordRequest(self: *Metrics, http_status: u16) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        switch (http_status / 100) {
            2 => _ = self.responses_2xx.fetchAdd(1, .monotonic),
            3 => _ = self.responses_3xx.fetchAdd(1, .monotonic),
            4 => _ = self.responses_4xx.fetchAdd(1, .monotonic),
            else => _ = self.responses_5xx.fetchAdd(1, .monotonic),
        }
    }

    /// Record an error (best-effort, may drop entries under contention).
    pub fn recordError(self: *Metrics, message: []const u8, path: []const u8) void {
        // Best-effort: if allocation fails, skip recording.
        const msg_copy = self.allocator.dupe(u8, message) catch return;
        const path_copy = self.allocator.dupe(u8, path) catch {
            self.allocator.free(msg_copy);
            return;
        };

        if (self.recent_errors.items.len >= self.max_error_entries) {
            const old = self.recent_errors.orderedRemove(0);
            self.allocator.free(old.message);
            self.allocator.free(old.path);
        }

        self.recent_errors.append(self.allocator, .{
            .timestamp = std.Io.Timestamp.now(getIo(), .real).toSeconds(),
            .message = msg_copy,
            .path = path_copy,
        }) catch {
            self.allocator.free(msg_copy);
            self.allocator.free(path_copy);
        };
    }

    pub fn uptime(self: *const Metrics) i64 {
        return std.Io.Timestamp.now(getIo(), .real).toSeconds() - self.start_time;
    }

    /// Returns health status: "ok" if recent 5xx < threshold, "degraded" otherwise.
    pub fn healthStatus(self: *const Metrics) []const u8 {
        if (self.responses_5xx.load(.monotonic) > 0) return "degraded";
        return "ok";
    }
};

/// Generate a health endpoint handler for the given metrics instance.
/// Usage (must be comptime): `app.get("/health", comptime zfinal.healthHandlerFor(&metrics))`
pub fn healthHandlerFor(metrics: *Metrics) type {
    return struct {
        pub fn handler(ctx: *anyopaque) anyerror!void {
            const Context = @import("context.zig").Context;
            const c: *Context = @ptrCast(@alignCast(ctx));

            const health_status = if (metrics.responses_5xx.load(.monotonic) == 0) "ok" else "degraded";
            const payload = .{
                .status = health_status,
                .uptime_sec = metrics.uptime(),
                .connections = metrics.total_connections.load(.monotonic),
                .total_requests = metrics.total_requests.load(.monotonic),
                .responses_2xx = metrics.responses_2xx.load(.monotonic),
                .responses_4xx = metrics.responses_4xx.load(.monotonic),
                .responses_5xx = metrics.responses_5xx.load(.monotonic),
            };

            c.res_status = .ok;
            try c.renderJson(payload);
        }
    }.handler;
}
