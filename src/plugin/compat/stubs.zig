const std = @import("std");

// ============================================================
// Java/Spring → ZFinal Compatibility Stubs
//
// Each stub defines the interface matching what Java developers
// expect, with clear status: Stub | Partial | Complete.
//
// During migration, AI reads these stubs and:
// 1. Maps Java imports to ZFinal equivalents
// 2. Implements missing features where feasible
// 3. Reports gaps with clear fallback suggestions
// ============================================================

/// @deprecated Use `zfinal.CircuitBreaker` — implementation moved to plugin/circuit_breaker.zig
pub const CircuitBreaker = @import("../circuit_breaker.zig").CircuitBreaker;

/// @deprecated Use `zfinal.ConfigClient`
pub const ConfigClient = @import("../config_client.zig").ConfigClient;

/// @deprecated Use `zfinal.HttpClient`
pub const HttpClient = @import("../http_client.zig").HttpClient;

/// @deprecated Use `zfinal.BeanValidator`
pub const BeanValidator = @import("../bean_validator.zig").BeanValidator;

/// @deprecated Use `zfinal.TaskScheduler`
pub const TaskScheduler = @import("../task_scheduler.zig").TaskScheduler;

/// Status: Stub. Java: Spring Cloud Gateway / Zuul.
/// Fallback: nginx/caddy reverse proxy.
pub const ApiGateway = struct {
    routes: std.ArrayList(GatewayRoute),

    pub const GatewayRoute = struct { path: []const u8, target: []const u8, strip_prefix: bool = true };

    pub fn init(allocator: std.mem.Allocator) ApiGateway {
        _ = allocator;
        return .{ .routes = std.ArrayList(GatewayRoute).empty };
    }
    pub fn deinit(self: *ApiGateway) void {
        self.routes.deinit();
    }

    pub fn addRoute(_: *ApiGateway, _: GatewayRoute) !void {
        return error.NotImplemented;
    }
    pub fn handle(_: *ApiGateway, _: anytype) !void {
        return error.NotImplemented;
    }
};

/// @deprecated Use `zfinal.MessageQueue` or `zfinal.QueueClient`
pub const MessageQueue = @import("../message_queue.zig").MessageQueue;

/// Status: Stub. Java: Spring Session / Redis Session.
/// ZFinal has in-memory SessionStore. Missing: Redis-backed, JDBC-backed, clustered.
pub const DistributedSession = struct {
    pub fn init(_: std.mem.Allocator) DistributedSession {
        return .{};
    }
    pub fn get(_: *DistributedSession, _: []const u8) !?[]const u8 {
        return error.NotImplemented;
    }
    pub fn set(_: *DistributedSession, _: []const u8, _: []const u8, _: u64) !void {
        return error.NotImplemented;
    }
    pub fn delete(_: *DistributedSession, _: []const u8) !void {}
};

/// @deprecated Use `zfinal.OAuth2Client`
pub const OAuth2Client = @import("../oauth2.zig").OAuth2Client;

/// Status: Partial. Java: Jackson ObjectMapper / Gson.
/// ZFinal has JsonKit (parse + stringify). Missing: polymorphic types, custom serializers, JsonView.
pub const ObjectMapper = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ObjectMapper {
        return .{ .allocator = allocator };
    }

    pub fn readValue(self: *ObjectMapper, comptime T: type, json: []const u8) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, json, .{});
        defer parsed.deinit();
        return parsed.value;
    }

    pub fn writeValue(self: *ObjectMapper, value: anytype) ![]const u8 {
        return try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    }

    pub fn readTree(_: *ObjectMapper, _: []const u8) !JsonNode {
        return error.NotImplemented;
    }
    pub const JsonNode = struct { value: std.json.Value };
};

/// @deprecated Use `zfinal.MetricsExporter` — implementation moved to plugin/metrics_exporter.zig
pub const MetricsExporter = @import("../metrics_exporter.zig").MetricsExporter;
