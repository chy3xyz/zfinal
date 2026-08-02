//! Business AI runtime: OpenAI-compatible chat + tools + ReAct agent.
//! Orthogonal to `zfinal.aichat` (Curl/SSE/ZfTool codegen layer).

pub const Tool = @import("skill.zig").Tool;
pub const Param = @import("skill.zig").Param;
pub const SkillContext = @import("skill.zig").SkillContext;
pub const SkillRegistry = @import("skill.zig").SkillRegistry;
pub const DispatchOpts = @import("skill.zig").DispatchOpts;
pub const freeValue = @import("skill.zig").freeValue;

pub const AiProvider = @import("provider.zig").AiProvider;

pub const Agent = @import("agent.zig").Agent;
pub const AgentResult = @import("agent.zig").AgentResult;
pub const AgentHooks = @import("agent.zig").AgentHooks;
pub const AgentMetrics = @import("agent.zig").AgentMetrics;
pub const ToolApproval = @import("agent.zig").ToolApproval;

pub const AgentHandle = @import("handle.zig").AgentHandle;
pub const ContextManager = @import("context.zig").ContextManager;
pub const SummarizeFn = @import("context.zig").SummarizeFn;

pub const MemoryStore = @import("memory.zig").MemoryStore;
pub const MemoryEntry = @import("memory.zig").MemoryEntry;
pub const registerMemorySkills = @import("memory_skills.zig").registerMemorySkills;

pub const EntitySpec = @import("business.zig").EntitySpec;
pub const BusinessCtx = @import("business.zig").BusinessCtx;
pub const registerBusinessSkills = @import("business.zig").registerBusinessSkills;
pub const validateSqlFragment = @import("business.zig").validateSqlFragment;

pub const ApprovalFlow = @import("approval.zig").ApprovalFlow;
pub const ApprovalCtx = @import("approval.zig").ApprovalCtx;
pub const ApprovalStep = @import("approval.zig").ApprovalStep;
pub const ApprovalResult = @import("approval.zig").ApprovalResult;
pub const ApprovalStatus = @import("approval.zig").ApprovalStatus;
pub const ApprovalDecision = @import("approval.zig").ApprovalDecision;
pub const ResolveStatus = @import("approval.zig").ResolveStatus;
pub const ResolveHookFn = @import("approval.zig").ResolveHookFn;
pub const PendingItem = @import("approval.zig").PendingItem;
pub const registerApprovalSkills = @import("approval.zig").registerApprovalSkills;
pub const defaultApprovalPolicy = @import("approval.zig").defaultPolicy;
pub const ToolGate = @import("approval.zig").ToolGate;

pub const bindApprovalHttp = @import("approval_http.zig").bind;
pub const bindApprovalHttpWith = @import("approval_http.zig").bindWith;
pub const unbindApprovalHttp = @import("approval_http.zig").unbind;
pub const registerApprovalHttp = @import("approval_http.zig").register;
pub const ApprovalHttpOpts = @import("approval_http.zig").HttpOpts;

pub const checkApprovalSla = @import("sla.zig").checkApprovalSla;
pub const checkApprovalSlaWithHook = @import("sla.zig").checkApprovalSlaWithHook;
pub const checkApprovalSlaDedup = @import("sla.zig").checkApprovalSlaDedup;
pub const SlaLevel = @import("sla.zig").SlaLevel;
pub const SlaHit = @import("sla.zig").SlaHit;
pub const SlaHitFn = @import("sla.zig").SlaHitFn;
pub const SlaNotifyGate = @import("sla.zig").SlaNotifyGate;

pub const AgentAuditLog = @import("audit.zig").AgentAuditLog;
pub const AuditEvent = @import("audit.zig").AuditEvent;
pub const AuditKind = @import("audit.zig").AuditKind;

pub const RunAuditStore = @import("run_audit.zig").RunAuditStore;
pub const RunAuditEntry = @import("run_audit.zig").RunAuditEntry;
pub const RunKind = @import("run_audit.zig").RunKind;

pub const Budget = @import("budget.zig").Budget;
pub const ExceedMode = @import("budget.zig").ExceedMode;

pub const Retriever = @import("retriever.zig").Retriever;
pub const RetrievedChunk = @import("retriever.zig").RetrievedChunk;
pub const KeywordRetriever = @import("retriever.zig").KeywordRetriever;

pub const TokenQuota = @import("quota.zig").TokenQuota;

pub const estimateTokens = @import("tokenizer.zig").estimateTokens;
pub const estimateMessages = @import("tokenizer.zig").estimateMessages;

pub const toSkillsJson = @import("skill_export.zig").toSkillsJson;
pub const toOpenApi = @import("skill_export.zig").toOpenApi;
pub const OpenApiOpts = @import("skill_export.zig").OpenApiOpts;

pub const Workflow = @import("workflow.zig").Workflow;
pub const WorkflowResult = @import("workflow.zig").WorkflowResult;
pub const WorkflowMetrics = @import("workflow.zig").WorkflowMetrics;
pub const WorkflowJournal = @import("workflow.zig").WorkflowJournal;
pub const JournalLine = @import("workflow.zig").JournalLine;
pub const Step = @import("workflow.zig").Step;
pub const StepKind = @import("workflow.zig").StepKind;
pub const StepRecord = @import("workflow.zig").StepRecord;
pub const StepStatus = @import("workflow.zig").StepStatus;
pub const RunStatus = @import("workflow.zig").RunStatus;
pub const EscalateReason = @import("workflow.zig").EscalateReason;
pub const VerifyFn = @import("workflow.zig").VerifyFn;
pub const EscalateFn = @import("workflow.zig").EscalateFn;

pub const ScheduledTask = @import("schedule.zig").ScheduledTask;
pub const ScheduleCtx = @import("schedule.zig").ScheduleCtx;
pub const registerScheduleSkills = @import("schedule.zig").registerScheduleSkills;

pub const Trigger = @import("trigger.zig").Trigger;
pub const TriggerFn = @import("trigger.zig").TriggerFn;
pub const TriggerResult = @import("trigger.zig").TriggerResult;

pub const AiMetrics = @import("observability.zig").AiMetrics;

pub const AiConfig = @import("module.zig").AiConfig;
pub const AiRuntime = @import("module.zig").AiRuntime;

pub const Hierarchy = @import("hierarchy.zig").Hierarchy;
pub const HierarchyResult = @import("hierarchy.zig").HierarchyResult;
pub const SubTask = @import("hierarchy.zig").SubTask;
pub const SubTaskResult = @import("hierarchy.zig").SubTaskResult;
pub const HierarchyStatus = @import("hierarchy.zig").Status;
pub const PlannerFn = @import("hierarchy.zig").PlannerFn;
pub const ExecutorFn = @import("hierarchy.zig").ExecutorFn;

pub const time_util = @import("time_util.zig");

test {
    _ = @import("skill.zig");
    _ = @import("provider.zig");
    _ = @import("agent.zig");
    _ = @import("audit.zig");
    _ = @import("quota.zig");
    _ = @import("memory.zig");
    _ = @import("memory_skills.zig");
    _ = @import("business.zig");
    _ = @import("approval.zig");
    _ = @import("approval_http.zig");
    _ = @import("sla.zig");
    _ = @import("budget.zig");
    _ = @import("tokenizer.zig");
    _ = @import("retriever.zig");
    _ = @import("module.zig");
    _ = @import("handle.zig");
    _ = @import("context.zig");
    _ = @import("skill_export.zig");
    _ = @import("observability.zig");
    _ = @import("workflow.zig");
    _ = @import("workflow_journal.zig");
    _ = @import("schedule.zig");
    _ = @import("hierarchy.zig");
    _ = @import("trigger.zig");
    _ = @import("run_audit.zig");
}
