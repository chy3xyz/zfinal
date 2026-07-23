const std = @import("std");
const Metrics = @import("../core/metrics.zig").Metrics;

/// Export in-memory `Metrics` as Prometheus text or JSON.
pub const MetricsExporter = struct {
    /// Prometheus exposition format (text/plain; version=0.0.4).
    pub fn toPrometheus(metrics: *const Metrics, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        const head = try std.fmt.allocPrint(allocator,
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
            \\# HELP zfinal_request_duration_ms Request latency histogram (ms).
            \\# TYPE zfinal_request_duration_ms histogram
            \\zfinal_request_duration_ms_bucket{{le="5"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="20"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="50"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="100"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="250"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="1000"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="5000"}} {d}
            \\zfinal_request_duration_ms_bucket{{le="+Inf"}} {d}
            \\zfinal_request_duration_ms_sum {d}
            \\zfinal_request_duration_ms_count {d}
            \\
        , .{
            metrics.uptime(),
            metrics.total_connections.load(.monotonic),
            metrics.total_requests.load(.monotonic),
            metrics.responses_2xx.load(.monotonic),
            metrics.responses_3xx.load(.monotonic),
            metrics.responses_4xx.load(.monotonic),
            metrics.responses_5xx.load(.monotonic),
            cumBucket(metrics, 0),
            cumBucket(metrics, 1),
            cumBucket(metrics, 2),
            cumBucket(metrics, 3),
            cumBucket(metrics, 4),
            cumBucket(metrics, 5),
            cumBucket(metrics, 6),
            cumBucket(metrics, 7),
            metrics.latency_sum_ms.load(.monotonic),
            metrics.total_requests.load(.monotonic),
        });
        defer allocator.free(head);
        try out.appendSlice(allocator, head);

        const routes = try std.fmt.allocPrint(allocator,
            \\# HELP zfinal_requests_by_route_total Coarse path-class request counts.
            \\# TYPE zfinal_requests_by_route_total counter
            \\zfinal_requests_by_route_total{{route="health"}} {d}
            \\zfinal_requests_by_route_total{{route="metrics"}} {d}
            \\zfinal_requests_by_route_total{{route="api"}} {d}
            \\zfinal_requests_by_route_total{{route="admin"}} {d}
            \\zfinal_requests_by_route_total{{route="static"}} {d}
            \\zfinal_requests_by_route_total{{route="other"}} {d}
            \\# HELP zfinal_request_duration_by_route_ms Coarse path-class latency (ms).
            \\# TYPE zfinal_request_duration_by_route_ms summary
            \\zfinal_request_duration_by_route_ms_sum{{route="health"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="health"}} {d}
            \\zfinal_request_duration_by_route_ms_sum{{route="metrics"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="metrics"}} {d}
            \\zfinal_request_duration_by_route_ms_sum{{route="api"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="api"}} {d}
            \\zfinal_request_duration_by_route_ms_sum{{route="admin"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="admin"}} {d}
            \\zfinal_request_duration_by_route_ms_sum{{route="static"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="static"}} {d}
            \\zfinal_request_duration_by_route_ms_sum{{route="other"}} {d}
            \\zfinal_request_duration_by_route_ms_count{{route="other"}} {d}
            \\
        , .{
            metrics.route_hits[0].load(.monotonic),
            metrics.route_hits[1].load(.monotonic),
            metrics.route_hits[2].load(.monotonic),
            metrics.route_hits[3].load(.monotonic),
            metrics.route_hits[4].load(.monotonic),
            metrics.route_hits[5].load(.monotonic),
            metrics.route_latency_sum_ms[0].load(.monotonic),
            metrics.route_latency_count[0].load(.monotonic),
            metrics.route_latency_sum_ms[1].load(.monotonic),
            metrics.route_latency_count[1].load(.monotonic),
            metrics.route_latency_sum_ms[2].load(.monotonic),
            metrics.route_latency_count[2].load(.monotonic),
            metrics.route_latency_sum_ms[3].load(.monotonic),
            metrics.route_latency_count[3].load(.monotonic),
            metrics.route_latency_sum_ms[4].load(.monotonic),
            metrics.route_latency_count[4].load(.monotonic),
            metrics.route_latency_sum_ms[5].load(.monotonic),
            metrics.route_latency_count[5].load(.monotonic),
        });
        defer allocator.free(routes);
        try out.appendSlice(allocator, routes);

        return try out.toOwnedSlice(allocator);
    }

    fn cumBucket(metrics: *const Metrics, idx: usize) u64 {
        var sum: u64 = 0;
        var i: usize = 0;
        while (i <= idx) : (i += 1) {
            sum += metrics.latency_bucket_counts[i].load(.monotonic);
        }
        return sum;
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
    m.recordRoute("/api/me");
    m.recordRouteLatencyMs("/api/me", 12);

    const text = try MetricsExporter.toPrometheus(&m, a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "zfinal_connections_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "code=\"2xx\"}} 1") != null or std.mem.indexOf(u8, text, "code=\"2xx\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5xx") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zfinal_request_duration_by_route_ms_sum{route=\"api\"} 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zfinal_request_duration_by_route_ms_count{route=\"api\"} 1") != null);

    const json = try MetricsExporter.toJson(&m, a);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"connections\":1") != null);
}
