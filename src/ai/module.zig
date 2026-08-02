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
    api_key: []const u8,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: AiConfig) !AiRuntime {
        const http = try allocator.create(HttpClient);
        errdefer allocator.destroy(http);
        http.* = try HttpClient.init(allocator, config.http_base_url);
        errdefer http.deinit();

        var provider = AiProvider.init(allocator, http, config.endpoint, config.api_key, config.model);
        errdefer provider.deinit();

        var registry = SkillRegistry.init(allocator, io);
        errdefer registry.deinit();

        var runtime: AiRuntime = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http = http,
            .provider = provider,
            .registry = registry,
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
};