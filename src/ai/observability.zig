//! Merge provider/agent/quota/workflow Prometheus series for a single `/metrics` scrape.

const std = @import("std");
const AgentMetrics = @import("agent.zig").AgentMetrics;
const TokenQuota = @import("quota.zig").TokenQuota;
const AiProvider = @import("provider.zig").AiProvider;
const WorkflowMetrics = @import("workflow.zig").WorkflowMetrics;

pub const AiMetrics = struct {
    provider: ?*AiProvider.Metrics = null,
    agent: ?*AgentMetrics = null,
    quota: ?*TokenQuota = null,
    workflow: ?*WorkflowMetrics = null,
    provider_name: []const u8 = "provider",
    agent_name: []const u8 = "agent",
    workflow_name: []const u8 = "wf",

    pub fn toPrometheusFormat(self: *AiMetrics, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        if (self.provider) |pm| {
            const part = try pm.toPrometheusFormat(allocator, self.provider_name);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        if (self.agent) |am| {
            const part = try am.toPrometheusFormat(allocator, self.agent_name);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        if (self.quota) |q| {
            const part = try q.toPrometheusFormat(allocator);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        if (self.workflow) |wm| {
            const part = try wm.toPrometheusFormat(allocator, self.workflow_name);
            defer allocator.free(part);
            try buf.appendSlice(allocator, part);
            try buf.appendSlice(allocator, "\n");
        }
        return buf.toOwnedSlice(allocator);
    }
};

test "AiMetrics merges agent quota and workflow series" {
    const allocator = std.testing.allocator;
    var agent = AgentMetrics{ .runs = 2, .steps = 5, .tool_calls = 3 };
    var quota = TokenQuota.init(allocator, std.testing.io, 100);
    defer quota.deinit();
    try quota.record(1, 30, 30);
    var wf = WorkflowMetrics{ .runs = 3, .completed_steps = 7 };

    var ai_metrics = AiMetrics{ .agent = &agent, .quota = &quota, .workflow = &wf };
    const out = try ai_metrics.toPrometheusFormat(allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "zfinal_ai_agent_runs_total{agent=\"agent\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zfinal_ai_token_quota_used{tenant_id=\"1\"} 60") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zfinal_ai_workflow_runs_total{workflow=\"wf\"} 3") != null);
}
