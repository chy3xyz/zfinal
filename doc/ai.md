# Business AI Runtime — `zfinal.ai`

> LLM 对话 / Agent **产品能力**（OpenAI 兼容 chat + tools + ReAct）。  
> 写 ZFinal 框架 / 用 `zf` 生成代码：见 [aichat.md](aichat.md) 与 `zfinal.aichat.ZfTool`。  
> 本模块**不含**默认 shell、外部 MCP client，也不含 ZfTool。

## 与 `zfinal.aichat` 的分工

| 命名空间 | 用途 |
|----------|------|
| `zfinal.ai` | 业务运行时：`AiProvider` / `SkillRegistry` / `Agent` / 配额·审计·记忆 |
| `zfinal.aichat` | Curl 同步/流式聊天、SSE 格式化、**ZfTool**（`crud:sql` / `crud:zent` 清单） |

应用侧集成聊天与工具，用 `zfinal.ai`。框架代码生成仍走 `aichat`。

## 核心 API

| 类型 | 作用 |
|------|------|
| `AiProvider` | OpenAI 兼容 `chat` / `chatWith` / **`chatStream`**（SSE）；`buildMessages` / `countTokens` / `fitsBudget`；解析 `tool_calls`；可选 `enableRateLimit` |
| `SkillRegistry` | 注册 Zig skill；`dispatch` / `dispatchWith`（白名单 + 协作超时）；`toOpenAiFunctionsAlloc`；`names` |
| `Agent` | ReAct：`provider` + `registry` → `run`；`hooks` / `metrics` / `audit` / `run_audit` / `retriever` / `quota` / `budget` / `handle` / `context` |
| `AgentHandle` | 协作式 cancel / pause / stepsDone（步进边界检查） |
| `ContextManager` | 超长对话自动压缩（可选 summarizer；否则丢弃旧段） |
| `AiRuntime` | 一键持有 HttpClient + Provider + Registry（可选 audit / **run_audit** / quota / memory + memory skills） |
| `MemoryStore` | 进程内记忆（复合键）；`recall` / `forget` / `formatContext`；`dumpJson`/`loadJson`/`saveToFile`/`loadFromFile` |
| `registerMemorySkills` | `memory_remember` / `get` / `recall` / `forget`（`userdata=*MemoryStore`） |
| `registerBusinessSkills` | 受控 `db.query` / `entity.lookup` / `entity.list`（`userdata=*BusinessCtx`，`*DB` + 实体白名单） |
| `ApprovalFlow` / `registerApprovalSkills` | 审批链；`attachDb`；`lookup`；`resolveForTenant`；`default_sla_ms`；`on_resolve` |
| `checkApprovalSla` | pending 审批 warn/breach 扫描（接 cron/Trigger） |
| `registerApprovalHttp` / `bindApprovalHttp` | `GET /approvals/pending`、`POST .../:id/approve|reject` |
| `AgentAuditLog` | 环形工具级审计 |
| `RunAuditStore` | 运行级审计；ring + JSON；`attachDb` → `ai_run_audit` |
| `TokenQuota` / `Budget` | 租户配额（`attachDb` → `ai_token_quota`、JSON、Prometheus）/ 任务级预算 |
| `Retriever` | RAG 注入接口；自带 `KeywordRetriever` 演示（非向量库） |
| `toSkillsJson` / `toOpenApi` | Skill 目录 / OpenAPI 导出 |
| `Workflow` | 多步编排：`llm` / `skill` / `agent` / `approval`；DAG；checkpoint；**JSONL+SQLite journal**；门控指标 |
| `Hierarchy` | planner 拆子任务 → `Io.Group` 并行执行 → 聚合 |
| `Trigger` | cron / event / webhook 统一 `fire`；`registerCron` → `CronPlugin` |
| `registerScheduleSkills` | Agent 可调度**预注册**命名任务（`CronPlugin.scheduleWith`） |
| `AiMetrics` | 合并 provider/agent/quota/workflow Prometheus 文本 |

## 快速集成

```zig
const std = @import("std");
const zfinal = @import("zfinal");

fn ping(ctx: *zfinal.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
    return .{ .string = try ctx.allocator.dupe(u8, "pong") };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var runtime = try zfinal.ai.AiRuntime.init(allocator, std.Io.Threaded.init(allocator, .{}).io(), .{
        .endpoint = "https://api.deepseek.com/v1/chat/completions",
        .api_key = "sk-...",
        .model = "deepseek-chat",
        .enable_audit = true,
    });
    defer runtime.deinit();

    try runtime.register(.{
        .name = "ping",
        .description = "Health check",
        .parameters = &.{},
        .handler = ping,
    });

    var skill_ctx = zfinal.ai.SkillContext{ .allocator = allocator };
    var result = try runtime.run("ping the system", &skill_ctx, &.{"ping"});
    defer result.deinit(allocator);
    std.debug.print("{s}\n", .{result.answer});
}
```

更细粒度时自行组装：

```zig
var http = try zfinal.HttpClient.init(allocator, "");
defer http.deinit();
var provider = zfinal.ai.AiProvider.init(allocator, &http, endpoint, key, model);
defer provider.deinit();

var registry = zfinal.ai.SkillRegistry.init(allocator, io);
defer registry.deinit();
try registry.register(...);

var agent = zfinal.ai.Agent{
    .provider = &provider,
    .registry = &registry,
    .allowlist = &.{"ping"},
    .tool_timeout_ms = 5_000,
};
var result = try agent.run(allocator, goal, &skill_ctx, 8);
defer result.deinit(allocator);
```

**约定**：skill handler 返回的 `json.Value` 中字符串必须用 `ctx.allocator` dupe；调用方（Agent）会 `freeValue`。

## Workflow 编排

```zig
const steps = [_]zfinal.ai.Step{
    .{ .name = "fetch", .kind = .{ .skill = .{ .name = "lookup", .args = .{ .object = .{} } } } },
    .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-1", .amount = 99999 } }, .depends_on = &.{"fetch"} },
    .{ .name = "decide", .kind = .{ .agent = .{ .goal = "summarize", .max_steps = 5 } }, .depends_on = &.{"review"} },
};
var wf = zfinal.ai.Workflow.init(&registry, &steps);
wf.provider = &provider;
wf.approval_flow = &flow; // required for `.approval` steps
wf.metrics = &wf_metrics;
wf.io = io;           // optional: enable parallel DAG waves
wf.max_parallel = 4;
var result = try wf.run(allocator, &skill_ctx);
defer result.deinit();
// result.status == .pending_human → dump checkpoint, human resolves, then:
// var resumed = try wf.runFromCheckpoint(allocator, &skill_ctx, ck);

const ck = try zfinal.ai.Workflow.dumpCheckpoint(&result, allocator);
defer allocator.free(ck);
try zfinal.ai.Workflow.saveCheckpoint(&result, allocator, io, "wf.ckpt.json");

// Optional JSONL journal (lightweight WAL)
var journal = try zfinal.ai.WorkflowJournal.init(allocator, io, "wf-journal");
defer journal.deinit();
try journal.attachDb(db); // optional: dual-write ai_workflow_journal
wf.journal = &journal;
wf.run_id = "run-42";
// after pending_human + human approve:
// var resumed = try wf.resumeFromJournal(allocator, &skill_ctx, "run-42");
```

`.approval` 升级会停在 `pending_human`（step output 含 `run_id`）。`runFromCheckpoint` / `resumeFromJournal` 会查 `ApprovalFlow.lookup`：未审 / unknown → 继续挂起；**reject → `.failed`**；approve → 跳过门继续跑。

## Hierarchy（规划 + 并行子任务）

```zig
const T = struct {
    fn plan(a: std.mem.Allocator, _: *zfinal.ai.SkillContext, _: []const u8, out: *std.ArrayList(zfinal.ai.SubTask)) !void {
        try out.append(a, .{ .name = "a", .goal = "fetch A" });
        try out.append(a, .{ .name = "b", .goal = "fetch B" });
    }
    fn exec(a: std.mem.Allocator, _: *zfinal.ai.SkillContext, task: zfinal.ai.SubTask, out: *zfinal.ai.SubTaskResult) !void {
        out.name = try a.dupe(u8, task.name);
        out.ok = true;
        out.output = try a.dupe(u8, "ok");
    }
};
var h = zfinal.ai.Hierarchy.init(allocator, io, T.plan, T.exec);
h.max_parallel = 4;
var hr = try h.run(allocator, &skill_ctx, "top goal");
defer hr.deinit();
```

## Trigger（事件 / cron 统一入口）

```zig
const T = struct {
    fn run(a: std.mem.Allocator, _: *zfinal.ai.SkillContext, input: []const u8, out: *zfinal.ai.TriggerResult) !void {
        out.ok = true;
        out.run_id = try a.dupe(u8, "r1");
        out.message = try a.dupe(u8, input);
    }
};
var trigger = zfinal.ai.Trigger.init(allocator, io, T.run, skill_ctx);
defer trigger.deinit();
_ = try trigger.fire(allocator, "{\"event\":\"order.paid\"}");
try trigger.registerCron(&cron, "nightly", "0 2 * * *", "{}");
```

## 受控业务查询

```zig
const entities = [_]zfinal.ai.EntitySpec{
    .{ .name = "product", .table = "products", .pk = "id", .tenant_column = "tenant_id" },
};
var biz = zfinal.ai.BusinessCtx{ .db = db, .entities = &entities };
try zfinal.ai.registerBusinessSkills(&registry);
skill_ctx.userdata = @ptrCast(&biz);
skill_ctx.tenant_id = 7;
// Agent allowlist: db.query / entity.lookup / entity.list
```

## 轻量审批门

```zig
var flow = zfinal.ai.ApprovalFlow.init(allocator, io, zfinal.ai.defaultApprovalPolicy);
defer flow.deinit();
try flow.attachDb(db); // optional: persist pending in ai_approval_pending
flow.default_sla_ms = 24 * 60 * 60 * 1000; // 24h deadline on escalate
flow.on_resolve = myResolveHook;
const steps = [_]zfinal.ai.ApprovalStep{.{ .name = "manager" }};
var ap_ctx = zfinal.ai.ApprovalCtx{ .flow = &flow, .steps = &steps };
try zfinal.ai.registerApprovalSkills(&registry);

// Cron / Trigger tick:
var hits = std.ArrayList(zfinal.ai.SlaHit).empty;
defer { for (hits.items) |h| h.deinit(allocator); hits.deinit(allocator); }
_ = try zfinal.ai.checkApprovalSla(&flow, allocator, 60 * 60 * 1000, &hits);

const gate = zfinal.ai.ToolGate{ .gated = &.{"db.query"} };
agent.hooks = .{ .ctx = @ptrCast(@constCast(&gate)), .on_tool_request = zfinal.ai.ToolGate.hook };

zfinal.ai.bindApprovalHttp(&flow);
try zfinal.ai.registerApprovalHttp(&router);
```

## Schedule skills（受控 cron）

```zig
var cron = zfinal.CronPlugin.init(allocator);
defer cron.deinit();
const tasks = [_]zfinal.ai.ScheduledTask{
    .{ .name = "ping", .description = "noop", .task = myTask, .context = &userdata },
};
var sched_ctx = zfinal.ai.ScheduleCtx{ .cron = &cron, .tasks = &tasks };
try zfinal.ai.registerScheduleSkills(&registry);
skill_ctx.userdata = &sched_ctx;
// Agent allowlist: list_schedulable_tasks / schedule_job / list_jobs / cancel_job
```

## 离线 / 在线 demo

```bash
# 离线（chat_override + sqlite memory business/approval/trigger）
zig build run-ai-runtime

# 真实 LLM（需网络）
export OPENAI_API_KEY=sk-...
# optional: OPENAI_BASE_URL / OPENAI_MODEL / OPENAI_STREAM=1
zig build run-ai-live -- "Call get_time then greet me"
```

`run-ai-runtime` 覆盖：Workflow（含 `.approval` + checkpoint resume）、Agent、`entity.lookup`/`db.query`、审批 submit→pending→resolve、`attachDb`、memory、Trigger、`RunAuditStore`、`ToolGate`。
## 流式对话

```zig
const Ctx = struct {
    fn onDelta(_: *anyopaque, d: zfinal.ai.AiProvider.StreamDelta) anyerror!void {
        if (d.content_delta) |c| std.debug.print("{s}", .{c});
    }
};
var resp = try provider.chatStream(&msgs, .{}, @ptrFromInt(1), Ctx.onDelta);
defer provider.freeResponse(&resp);
```

`HttpClient.requestStream` 通过 `std.http.Client.fetch` 的 forwarding writer 边收边回调；
传输失败时 `chatStream` 会回退到缓冲式 `chatWith` 并补发 delta。

## 控制与可观测

```zig
var handle = zfinal.ai.AgentHandle.init();
agent.handle = &handle;
// 另一线程/请求：handle.requestCancel();

var ctx_mgr = zfinal.ai.ContextManager.init();
ctx_mgr.max_tokens = 8_000;
agent.context = &ctx_mgr;

const catalog = try zfinal.ai.toSkillsJson(&registry, allocator);
defer allocator.free(catalog);

var metrics = zfinal.ai.AiMetrics{ .agent = &agent.metrics, .quota = &quota };
const prom = try metrics.toPrometheusFormat(allocator);
defer allocator.free(prom);
```

## 安全边界

- **默认不执行**任意 shell / 外部 MCP。需要时自行 `register` 受控 handler。
- 生产务必设 `allowlist`，只暴露列出的工具名。
- `hooks.on_tool_request` → `ToolApproval.allow/deny` 做人机确认门。
- `tool_timeout_ms` / `Tool.timeout_ms` 为**协作式**超时（handler 应 `checkDeadline`），非抢占取消。
- **Approval HTTP**：默认 `require_tenant=true`（缺 `X-Tenant-ID` → 400）。生产再挂 JWT/CSRF
  或 `bindApprovalHttpWith(..., .{ .authorize = … })`。
- **`db.query`**：默认 `BusinessCtx.require_tenant_on_query=true`；有 `tenant_id` 时 SQL 必须含租户列名。
- **Provider**：`ChatOpts.max_retries` 对 429/5xx/连接错误指数退避；失败的 `Agent.run` 会写 `RunAuditStore` `status=failed`。
- **Audit / Trigger / Quota / SLA**：`AgentAuditLog.attachDb` → `ai_tool_audit`；`Trigger.fireIdempotent` + cron 失败日志；
  `TokenQuota.attachDb` / `dumpJson` / `setPeriodMs`；`Workflow` 的 `.agent` 步继承
  `allowlist` / `audit` / `run_audit`；`checkApprovalSlaDedup` 防重复告警。
- **Ports**：`zfinal.Store` / `Cache` / `Outbox` / `Memory*` 与 `Bus` 同级（`examples/ports-l3` re-export）。

## 测试注入

`Agent.chat_override` 可替换 `provider.chatWith`，单测无需真实 LLM：

```zig
agent.chat_override = myMockChat;
agent.chat_override_ctx = &mock_state;
```

## 明确不做（本阶段）

- 完整 EventBus WAL（有 JSONL + SQLite `WorkflowJournal` / checkpoint / pending·audit）
- 向量库 / embedding（通过 `Retriever` 自接）
- zigmodu 业务 pack（工单/退款/风控等）
- ZfTool / codegen skills（仍在 `zfinal.aichat`）
