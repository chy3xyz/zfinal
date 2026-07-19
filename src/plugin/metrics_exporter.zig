const std = @import("std");
const Metrics = @import("../core/metrics.zig").Metrics;

/// Export in-memory `Metrics` as Prometheus text or JSON.
pub const MetricsExporter = struct {
    /// Prometheus exposition format (text/plain; version=0.0.4).
    pub fn toPrometheus(metrics: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator,
            \\# HELP zfinal_uptime_seconds Process uptime in seconds.
            \\# TYPE zfinal_uptime_seconds gauge
            \\zfinal_uptime_seconds {d}
            \\# HELP zfinal_connections_total Accepted connections.
            \\# TYPE zfinal_connections_total counter
            \\zfinal_connections_total {d}
            \\# HELP zfinal_requests_total HTTP requests processed.
            \\# TYPE zfinal_requests_total counter
            \\zfinal_requests_total {d}
            \\# HELP zfinal_responses_total HTTP responses by class.
            \\# TYPE zfinal_responses_total counter
            \\zfinal_responses_total{{code="2xx"}} {d}
            \\zfinal_responses_total{{code="3xx"}} {d}
            \\zfinal_responses_total{{code="4xx"}} {d}
            \\zfinal_responses_total{{code="5xx"}} {d}
            \\
        , .{
            metrics.uptime(),
            metrics.total_connections.load(.monotonic),
            metrics.total_requests.load(.monotonic),
            metrics.responses_2xx.load(.monotonic),
            metrics.responses_3xx.load(.monotonic),
            metrics.responses_4xx.load(.monotonic),
            metrics.responses_5xx.load(.monotonic),
        });
    }

    pub fn toJson(metrics: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        const payload = .{
            .uptime_sec = metrics.uptime(),
            .connections = metrics.total_connections.load(.monotonic),
            .total_requests = metrics.total_requests.load(.monotonic),
            .responses_2xx = metrics.responses_2xx.load(.monotonic),
            .responses_3xx = metrics.responses_3xx.load(.monotonic),
            .responses_4xx = metrics.responses_4xx.load(.monotonic),
            .responses_5xx = metrics.responses_5xx.load(.monotonic),
            .status = metrics.healthStatus(),
        };
        return try std.json.Stringify.valueAlloc(allocator, payload, .{});
    }
};

test "metrics exporter: prometheus contains counters" {
    const a = std.testing.allocator;
    var m = Metrics.init(a);
    defer m.deinit();
    m.recordConnection();
    m.recordRequest(200);
    m.recordRequest(500);

    const text = try MetricsExporter.toPrometheus(&m, a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "zfinal_connections_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code=\"2xx\"}} 1") != null or std.mem.indexOf(u8, text, "code=\"2xx\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5xx") != null);

    const json = try MetricsExporter.toJson(&m, a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connections\":1") != null);
}
