# JSON 响应信封最佳实践

> **版本**：对齐 v0.20.9+ · 修订 **2026-07-31**  
> **相关**：[`http_ergonomics.md`](http_ergonomics.md) · [`architecture_best_practices.md`](architecture_best_practices.md) · [best_practices.md](best_practices.md) · ADR-013 · `src/core/http_error.zig`

**一模块只选一种信封。** 框架默认是 **REST / HttpError**；需要中式 BFF（ThinkPHP / ruoyi / ZigShop）时用 **zapi**，但成败形状必须统一，禁止半套。

---

## 1. 两套信封，怎么选

| | **A. REST / HttpError（默认）** | **B. zapi `{code,msg,data}`** |
|--|--------------------------------|-------------------------------|
| 适用 | 公开 API、OpenAPI、多语言客户端、Axum 风格 | 管理后台、与 PHP/Java 旧前端对齐 |
| 成功 | HTTP 2xx + `{ "ok": true, … }` 或 `{ "data": … }` | HTTP 2xx + `{ "code": 0, "msg": "ok", "data": … }` |
| 失败 | HTTP 4xx/5xx + `{ "err", "msg", "detail"? }` | HTTP 4xx/5xx（仍建议设）+ `{ "code": N, "msg": "…", "data": null }` |
| 主信号 | **HTTP status**；body 里 `err` 是机器码 | body 里 **数字 `code`**；HTTP status 辅助 |
| 框架支持 | `return error.NotFound` → `dispatch` 自动渲染 | **应用层**自行 `renderJson`（框架暂不改默认） |

### 选型规则

1. **新公共 API / OpenAPI 项目** → 选 **A**，不要改 `http_error.render`。
2. **迁移 ruoyi / ThinkPHP / ZigShop 前端** → 选 **B**，在 **handler 成功路径与错误路径都**包成 zapi；不要只改错误体。
3. **同一进程两个模块** → 允许各选一套，但 **同一 URL 前缀下禁止混用**（前端无法统一解析）。

---

## 2. 默认信封 A（框架行为）

`Server.dispatch` 捕获 `HttpError` 后调用 `http_error.render`：

```json
{ "err": "not_found", "msg": "Not Found" }
```

有 `setDetail` 时：

```json
{ "err": "bad_request", "msg": "Bad Request", "detail": "id" }
```

| 字段 | 含义 |
|------|------|
| `err` | 稳定机器码：`bad_request` / `unauthorized` / …（见 `codeOf`） |
| `msg` | 人类可读默认文案；有 `detail` 时 `msg` 仍为默认文案，细节在 `detail` |
| `detail` | 可选；字段名、头名等（静态或请求期切片，**非 owned**） |

### 实践

```zig
// 推荐：返回错误，由 dispatch 渲染
return error.NotFound;

// 推荐：带细节
zfinal.http_error.setDetail(ctx, "id");
return error.BadRequest;

// 禁止：先 renderJson(.{ .err = … }) 再 return error.*（双写被 markResponded 挡掉）
```

生成 CRUD：`failHttp(ctx, error.NotFound, "id")` → `setDetail` + `return err`。

OpenAPI：`components.schemas.HttpError` 描述的就是这套字段。改字段名等于破坏契约。

---

## 3. zapi 信封 B（应用约定）

标准形状（与 ZigShop / 常见中式 BFF 对齐）：

```json
// 成功
{ "code": 0, "msg": "ok", "data": { "id": 1 } }

// 失败（建议仍设 HTTP status，便于网关/探针）
{ "code": 404, "msg": "Not Found", "data": null }
```

### `code` 语义（必须在项目内写死一种）

| 方案 | 规则 | 何时用 |
|------|------|--------|
| **HTTP 对齐** | 失败 `code == @intFromEnum(status)`；成功 `0` | 新 BFF、简单 |
| **业务码** | 成功 `0`；失败 `40401` 等（百位段自管） | 兼容旧 PHP 数字码 |
| **禁止** | 成功体用 `{ok:true}`、失败体用 `{code,msg,data}` | 前端要写两套解析 |

### 推荐包装（示意，放在应用 `src/response.zig`）

```zig
pub fn ok(ctx: *zfinal.Context, data: anytype) !void {
    try ctx.renderJson(.{ .code = 0, .msg = "ok", .data = data });
}

pub fn fail(ctx: *zfinal.Context, status: std.http.Status, code: i32, msg: []const u8) !void {
    ctx.res_status = status;
    try ctx.renderJson(.{ .code = code, .msg = msg, .data = null });
}
```

拦截器 / `HttpError` 默认仍走信封 A。若全站 zapi：

- 在 **ai-edit-zone** 里统一走 `ok` / `fail`；或
- 自定义全局 after / fallback 把错误重写（成本更高，需自测 OpenAPI）。

**不要**只改 `http_error.zig` 注释却不改成功路径——那是半套信封，比现状更差。

---

## 4. 折中（数字码 + 保留机器字段）

若既要数字码又要 OpenAPI 机器字段：

```json
{ "code": 404, "msg": "Not Found", "err": "not_found", "detail": "id" }
```

- HTTP status 仍设为 404。
- `code` 与 status 对齐时，网关与前端都能用。
- 这是 **应用层扩展**，不是当前框架默认；引入前更新 OpenAPI 与客户端。

---

## 5. 反模式

| 反模式 | 为何不行 |
|--------|----------|
| 错误改成 `{code,msg,data:{}}`，成功仍是 `{ok:true}` | 两套解析 |
| `data: {}` 代替 `detail` | 丢掉字段级信息 |
| 成功 `code: 200`、失败也用 200 + body code | 探针/CDN 误判 |
| Handler 手搓 `renderJson(.{ .err = … })` | 与 `HttpError` / OpenAPI 分叉；`zf check` WARN |
| 临时 `createJwtAuthInterceptor(&.{…})` | cfg UAF（见 [http_ergonomics.md](http_ergonomics.md)） |

---

## 6. 与生成代码 / 检查的关系

| 工具 | 期望 |
|------|------|
| `zf crud:sql` | 成功 `{ok,id}` / `{data,…}`；失败 `failHttp` → 信封 A |
| `zf openapi` | `HttpError` = `err` + `msg` + optional `detail` |
| `zf check` | WARN 手搓 `.err =` 信封；生产契约见 `PRODUCTION_AUDIT` |

全站改 zapi：改 codegen 模板或 handler zone，并同步 OpenAPI；不要只改一处。

---

## 7. 速查

```
公开 REST API ──────────────► 信封 A（默认 HttpError）
管理后台 / 旧前端数字码 ─────► 信封 B（zapi，成败统一）
既要数字又要 err 机器码 ─────► 折中四字段（应用扩展）
同一路由前缀混 A+B ─────────► 禁止
```
