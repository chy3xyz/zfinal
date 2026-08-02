//! Quick-integrate bootstrap for business AI (provider + registry + optional
//! audit / quota / memory / run_audit).

const std = @import("std");
const HttpClient = @import("../plugin/http_client.zig").HttpClient;
const provider_mod = @import("provider.zig");
const skill_mod = @import("skill.zig");
const agent_mod = @import("agent.zig");
const audit_mod = @import("audit.zig");
const quota_mod = @import("quota.zig");
const memory_mod = @import("memory.zig");
const run_audit_mod = @import("run_audit.zig");
const memory_skills = @import("memory_skills.zig");
const mcp_skills = @import("mcp_skills.zig");
const DB = @import("../db/db.zig").DB;

pub const AiProvider = provider_mod.AiProvider;
pub const SkillRegistry = skill_mod.SkillRegistry;
pub const SkillContext = skill_mod.SkillContext;
pub const Tool = skill_mod.Tool;
pub const Agent = agent_mod.Agent;
pub const AgentResult = agent_mod.AgentResult;
pub const AgentAuditLog = audit_mod.AgentAuditLog;
pub const TokenQuota = quota_mod.TokenQuota;
pub const MemoryStore = memory_mod.MemoryStore;
pub const RunAuditStore = run_audit_mod.RunAuditStore;

pub const AiConfig = struct {
    endpoint: []const u8,
    /// Single key (compat). Used when `api_keys` is empty.
    api_key: []const u8 = "",
    /// Multi-key pool for high concurrency. When non-empty, builds `KeyPool`
    /// (and prepends `api_key` if it is also non-empty and not already listed).
    api_keys: []const []const u8 = &.{},
    /// Per-key RPM for KeyPool (ignored without pool).
    key_rpm: u32 = 60,
    /// Per-key max in-flight requests.
    key_max_inflight: u32 = 8,
    model: []const u8,
    /// Empty base_url on HttpClient — provider posts absolute `endpoint`.
    http_base_url: []const u8 = "",
    system_prompt: []const u8 = "You are a helpful business agent. Prefer tools for factual lookups. When finished, reply with the final answer only.",
    max_steps: usize = 8,
    tool_timeout_ms: ?u64 = 5_000,
    audit_capacity: usize = 128,
    run_audit_capacity: usize = 256,
    default_quota_tokens: usize = 1_000_000,
    enable_audit: bool = true,
    enable_run_audit: bool = true,
    enable_quota: bool = false,
    enable_memory: bool = false,
    /// When memory is enabled, also register memory_* skills on the registry.
    register_memory_skills: bool = true,
};

pub const AiRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: AiConfig,
    /// Heap-owned so `provider.http` stays valid if this struct is relocated.
    http: *HttpClient,
    provider: AiProvider,
    registry: SkillRegistry,
    audit: ?AgentAuditLog = null,
    run_audit: ?RunAuditStore = null,
    quota: ?TokenQuota = null,
    memory: ?MemoryStore = null,
    /// Owned key pool when multi-key configured.
    key_pool: ?*provider_mod.KeyPool = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: AiConfig) !AiRuntime {
        const http = try allocator.create(HttpClient);
        errdefer allocator.destroy(http);
        http.* = try HttpClient.init(allocator, config.http_base_url);
        errdefer http.deinit();

        const primary_key = blk: {
            if (config.api_keys.len > 0) break :blk config.api_keys[0];
            break :blk config.api_key;
        };
        var provider = AiProvider.init(allocator, http, config.endpoint, primary_key, config.model);
        errdefer provider.deinit();

        var key_pool: ?*provider_mod.KeyPool = null;
        errdefer if (key_pool) |p| {
            p.deinit();
            allocator.destroy(p);
        };

        const pool_keys = try collectKeys(allocator, config.api_key, config.api_keys);
        defer allocator.free(pool_keys);
        if (pool_keys.len > 1 or (pool_keys.len == 1 and config.api_keys.len > 0)) {
            const pool = try allocator.create(provider_mod.KeyPool);
            errdefer allocator.destroy(pool);
            pool.* = try provider_mod.KeyPool.init(allocator, io, .{
                .keys = pool_keys,
                .rpm_per_key = config.key_rpm,
                .max_inflight_per_key = config.key_max_inflight,
            });
            key_pool = pool;
            provider.key_pool = pool;
            // Keep primary api_key for fallback / display.
            if (pool_keys.len > 0) provider.api_key = pool_keys[0];
        }

        var registry = SkillRegistry.init(allocator, io);
        errdefer registry.deinit();

        var runtime: AiRuntime = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http = http,
            .provider = provider,
            .registry = registry,
            .key_pool = key_pool,
        };

        if (config.enable_audit) {
            runtime.audit = try AgentAuditLog.init(allocator, io, config.audit_capacity);
        }
        if (config.enable_run_audit) {
            runtime.run_audit = try RunAuditStore.init(allocator, io, config.run_audit_capacity);
        }
        if (config.enable_quota) {
            runtime.quota = TokenQuota.init(allocator, io, config.default_quota_tokens);
        }
        if (config.enable_memory) {
            runtime.memory = MemoryStore.init(allocator, io);
            if (config.register_memory_skills) {
                try memory_skills.registerMemorySkills(&runtime.registry);
            }
        }

        return runtime;
    }

    pub fn deinit(self: *AiRuntime) void {
        if (self.memory) |*m| m.deinit();
        if (self.quota) |*q| q.deinit();
        if (self.run_audit) |*a| a.deinit();
        if (self.audit) |*a| a.deinit();
        self.registry.deinit();
        self.provider.deinit();
        if (self.key_pool) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.http.deinit();
        self.allocator.destroy(self.http);
        self.* = undefined;
    }

    pub fn register(self: *AiRuntime, tool: Tool) !void {
        try self.registry.register(tool);
    }

    /// Build an Agent wired to this runtime's provider/registry and optional controls.
    pub fn agent(self: *AiRuntime) Agent {
        return .{
            .provider = &self.provider,
            .registry = &self.registry,
            .system_prompt = self.config.system_prompt,
            .tool_timeout_ms = self.config.tool_timeout_ms,
            .audit = if (self.audit) |*a| a else null,
            .run_audit = if (self.run_audit) |*a| a else null,
            .quota = if (self.quota) |*q| q else null,
        };
    }

    /// SkillContext with userdata pointing at MemoryStore when enabled.
    pub fn skillContext(self: *AiRuntime, allocator: std.mem.Allocator) SkillContext {
        return .{
            .allocator = allocator,
            .userdata = if (self.memory) |*m| @ptrCast(m) else null,
        };
    }

    pub fn run(
        self: *AiRuntime,
        goal: []const u8,
        skill_ctx: *SkillContext,
        allowlist: ?[]const []const u8,
    ) !AgentResult {
        var ag = self.agent();
        ag.allowlist = allowlist;
        if (skill_ctx.userdata == null) {
            if (self.memory) |*m| skill_ctx.userdata = @ptrCast(m);
        }
        return ag.run(self.allocator, goal, skill_ctx, self.config.max_steps);
    }

    /// Dual-write `run_audit` + tool `audit` into SQLite when enabled.
    pub fn attachDb(self: *AiRuntime, db: *DB) !void {
        if (self.run_audit) |*store| try store.attachDb(db);
        if (self.audit) |*log| try log.attachDb(db);
    }

    /// Register tools from an `McpBridge` (client already initialize()'d).
    /// Keep `bridge` (+ underlying client) alive; set `skill_ctx.backend_ptr = bridge`.
    pub fn attachMcp(self: *AiRuntime, bridge: *mcp_skills.McpBridge, opts: mcp_skills.McpImportOpts) !usize {
        return mcp_skills.registerMcpTools(&self.registry, bridge, opts);
    }
};

/// Build owned slice of key pointers (strings borrowed from config). Caller frees the slice only.
fn collectKeys(allocator: std.mem.Allocator, api_key: []const u8, api_keys: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer list.deinit(allocator);

    if (api_key.len > 0) {
        try list.append(allocator, api_key);
    }
    for (api_keys) |k| {
        if (k.len == 0) continue;
        var dup = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, k)) {
                dup = true;
                break;
            }
        }
        if (!dup) try list.append(allocator, k);
    }
    return try list.toOwnedSlice(allocator);
}

test "collectKeys merges api_key and api_keys without dupes" {
    const allocator = std.testing.allocator;
    const keys = try collectKeys(allocator, "sk-a", &.{ "sk-a", "sk-b" });
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("sk-a", keys[0]);
    try std.testing.expectEqualStrings("sk-b", keys[1]);
}
