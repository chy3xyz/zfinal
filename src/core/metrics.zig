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
    /// Latency histogram buckets (ms): ≤5, ≤20, ≤50, ≤100, ≤250, ≤1000, ≤5000, +Inf.
    latency_bucket_counts: [8]std.atomic.Value(u64) = .{
        .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0), .init(0),
    },
    latency_sum_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Coarse path-class counters: health, metrics, api, other.
    route_hits: [4]std.atomic.Value(u64) = .{
        .init(0), .init(0), .init(0), .init(0),
    },
    /// Per route-class latency sum/count for Prometheus averages.
    route_latency_sum_ms: [4]std.atomic.Value(u64) = .{
        .init(0), .init(0), .init(0), .init(0),
    },
    route_latency_count: [4]std.atomic.Value(u64) = .{
        .init(0), .init(0), .init(0), .init(0),
    },
    /// Ring buffer for recent errors (last N errors). Protected by `error_mutex`.
    recent_errors: std.ArrayList(ErrorEntry),
    error_mutex: std.Io.Mutex = .init,
    max_error_entries: usize = 50,
    allocator: std.mem.Allocator,

    pub const latency_bounds_ms = [_]u64{ 5, 20, 50, 100, 250, 1000, 5000 };

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

    /// Record request latency into fixed histogram buckets (milliseconds).
    pub fn recordLatencyMs(self: *Metrics, duration_ms: u64) void {
        _ = self.latency_sum_ms.fetchAdd(duration_ms, .monotonic);
        var idx: usize = 0;
        while (idx < latency_bounds_ms.len) : (idx += 1) {
            if (duration_ms <= latency_bounds_ms[idx]) {
                _ = self.latency_bucket_counts[idx].fetchAdd(1, .monotonic);
                return;
            }
        }
        _ = self.latency_bucket_counts[latency_bounds_ms.len].fetchAdd(1, .monotonic);
    }

    pub const route_labels = [_][]const u8{ "health", "metrics", "api", "other" };

    /// Coarse route class to keep Prometheus cardinality bounded.
    pub fn recordRoute(self: *Metrics, path: []const u8) void {
        const idx = routeClass(path);
        _ = self.route_hits[idx].fetchAdd(1, .monotonic);
    }

    pub fn recordRouteLatencyMs(self: *Metrics, path: []const u8, duration_ms: u64) void {
        const idx = routeClass(path);
        _ = self.route_latency_sum_ms[idx].fetchAdd(duration_ms, .monotonic);
        _ = self.route_latency_count[idx].fetchAdd(1, .monotonic);
    }

    pub fn routeClass(path: []const u8) usize {
        if (std.mem.eql(u8, path, "/health") or std.mem.startsWith(u8, path, "/health/")) return 0;
        if (std.mem.eql(u8, path, "/metrics") or std.mem.startsWith(u8, path, "/metrics/")) return 1;
        if (std.mem.startsWith(u8, path, "/api")) return 2;
        return 3;
    }

    /// Record an error (best-effort, may drop entries under contention).
    pub fn recordError(self: *Metrics, message: []const u8, path: []const u8) void {
        self.error_mutex.lockUncancelable(getIo());
        defer self.error_mutex.unlock(getIo());

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
/// `metrics` must be a comptime-known pointer (typically a global).
/// Usage: `app.get("/health", zfinal.healthHandlerFor(&g_metrics))`
pub fn healthHandlerFor(comptime metrics: *Metrics) *const fn (*@import("context.zig").Context) anyerror!void {
    return struct {
        fn handler(ctx: *@import("context.zig").Context) anyerror!void {
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

            ctx.res_status = .ok;
            try ctx.renderJson(payload);
        }
    }.handler;
}

/// Named probe used by `healthHandlerWithChecks`.
pub const HealthCheck = struct {
    name: []const u8,
    /// Return true when the dependency is healthy.
    check: *const fn () bool,
};

/// Health JSON including named probes (e.g. DB ping). Overall status is
/// `ok` only when metrics 5xx==0 and every probe returns true.
pub fn healthHandlerWithChecks(
    comptime metrics: *Metrics,
    comptime checks: []const HealthCheck,
) *const fn (*@import("context.zig").Context) anyerror!void {
    return struct {
        fn handler(ctx: *@import("context.zig").Context) anyerror!void {
            var all_ok = metrics.responses_5xx.load(.monotonic) == 0;
            var probe_buf: [16]struct { name: []const u8, ok: bool } = undefined;
            const n = @min(checks.len, probe_buf.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const ok = checks[i].check();
                probe_buf[i] = .{ .name = checks[i].name, .ok = ok };
                if (!ok) all_ok = false;
            }

            const health_status: []const u8 = if (all_ok) "ok" else "degraded";
            // Fixed-shape JSON for ≤16 probes; unused slots omitted via slice.
            const probes = probe_buf[0..n];
            const payload = .{
                .status = health_status,
                .uptime_sec = metrics.uptime(),
                .connections = metrics.total_connections.load(.monotonic),
                .total_requests = metrics.total_requests.load(.monotonic),
                .responses_2xx = metrics.responses_2xx.load(.monotonic),
                .responses_4xx = metrics.responses_4xx.load(.monotonic),
                .responses_5xx = metrics.responses_5xx.load(.monotonic),
                .probes = probes,
            };
            ctx.res_status = if (all_ok) .ok else .service_unavailable;
            try ctx.renderJson(payload);
        }
    }.handler;
}

/// Prometheus `/metrics` handler for a comptime-known Metrics pointer.
pub fn metricsHandlerFor(comptime metrics: *Metrics) *const fn (*@import("context.zig").Context) anyerror!void {
    const Exporter = @import("../plugin/metrics_exporter.zig").MetricsExporter;
    return struct {
        fn handler(ctx: *@import("context.zig").Context) anyerror!void {
            const text = try Exporter.toPrometheus(metrics, ctx.allocator);
            defer ctx.allocator.free(text);
            try ctx.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
            ctx.res_status = .ok;
            try ctx.renderText(text);
        }
    }.handler;
}
