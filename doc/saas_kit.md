# SaaS Kit / zfsaas（ZFinal 业务框）

> **版本**：对齐 v0.20.15+ · 示例路径 [`examples/zfsaas/`](../examples/zfsaas/)  
> **定位**：可复制的 **org 多租户 SaaS** — Zig 后端 + SolidStart 前端同仓。

## 布局

```
examples/zfsaas/
  backend/     # ZFinal API  (原 saas-kit)
  frontend/    # SolidStart   (原 zsaas-start / saas-solidjs)
  scripts/dev.sh
  README.md
```

## 1. 跑起来

```bash
# 双进程（API :8080 + UI :3000）
./examples/zfsaas/scripts/dev.sh

# 或
zig build run-zfsaas          # alias: zig build run-saas-kit
cd examples/zfsaas/frontend && npm i && npm run dev

zig build test-zfsaas
```

默认 SQLite 文件 `saas-kit.db`；`CORS_ORIGIN` 默认 `http://localhost:3000`。

## 2. 领域模型

对齐 zsaas-start `Schema.ts`：

| 表 | 作用 |
|----|------|
| `users` / `auth_tokens` | 账号、密码重置 |
| `organizations` / `memberships` | 租户 + `admin` \| `member` |
| `invitations` | 邀请（`token_hash`） |
| `subscriptions` / `stripe_webhook_events` | 订阅状态与 webhook 幂等 |
| `todo` | 样例业务表，**强制 `org_id` 谓词** |

租户键是 **TEXT `org_id`**。JWT：`sub` = user id，`aud` = 当前 org，`role` = 成员角色。可选请求头 `X-Org-Id` 必须与 `aud` 一致。

## 3. API 契约

统一信封：`{ "ok": bool, "data": ..., "error": ... }`。

| 能力 | Method / Path | 鉴权 |
|------|---------------|------|
| 注册 | `POST /api/auth/sign-up` | 公开 → `{ token, user, org_id, role }` |
| 登录 | `POST /api/auth/sign-in` | 公开 |
| 我 | `GET /api/auth/me` | Bearer |
| 密码重置 | `POST /api/auth/password-reset/request\|confirm` | 公开（dev 返回 `dev_token`） |
| Org 列表/创建/切换 | `GET\|POST /api/orgs`，`POST /api/orgs/switch` | Bearer |
| 邀请 | `POST /api/orgs/:id/invites` | Bearer + org admin |
| 接受邀请 | `POST /api/invites/accept` | Bearer |
| 订阅 | `GET /api/billing/subscription` | Bearer + org 成员 |
| Checkout | `POST /api/billing/checkout` | 同上；无密钥则 mock URL 并置 `active` |
| Webhook | `POST /api/billing/webhook` | 验签（无密钥跳过）；body 见下 |
| Todo CRUD | `/api/todos` | Bearer + org 成员；**写操作需 active/trialing** |
| Health | `GET /api/health` | 公开 |

Mock webhook JSON（本地/CI）：

```json
{ "id": "evt_1", "type": "customer.subscription.updated", "org_id": "<org>", "status": "active" }
```

## 4. 与 SolidStart 前端对接

前端已在 [`examples/zfsaas/frontend`](../examples/zfsaas/frontend)，薄封装：`src/libs/zfinalClient.ts`。

1. `.env` 设 `ZFINAL_API_URL=http://127.0.0.1:8080`。
2. **Auth**：server actions 改为 `zfinalClient.signIn/signUp`，存 Bearer token。
3. **Org 切换**：`POST /api/orgs/switch`，替换 JWT。
4. **Billing**：Checkout 用后端返回 `url`；Webhook 指 ZFinal `POST /api/billing/webhook`。
5. **业务 CRUD**：调 `/api/...`；服务端已做 `org_id` 过滤与订阅门禁。
6. 未设 `ZFINAL_API_URL` 时前端仍可走原 Drizzle/PGLite 路径（对照用）。

环境变量：

| 变量 | 说明 |
|------|------|
| `JWT_SECRET` | HS256 密钥（≥32 字节建议） |
| `SAAS_DB` | SQLite 路径 |
| `PUBLIC_BASE_URL` | Checkout 回跳基址 |
| `CORS_ORIGIN` | 前端源（默认 `http://localhost:3000`） |
| `STRIPE_SECRET` / `STRIPE_WEBHOOK_SECRET` / `STRIPE_PRICE_ID` | 有则 live；缺省 mock |
| `ZFINAL_API_URL` | 前端指向后端 |

邮件：`EmailSender` port，默认 log mock。

## 5. 代码边界

- `todo`：`zf crud:sql todo.sql` 生成 model，service/handler 在 ai-edit-zone / 定制层做 **org 作用域**。
- `auth` / `org` / `billing`：跨表事务 + Argon2id + Stripe，手写 service（勿硬塞纯 CRUD）。
- 拦截器：`RequestId` → JWT（`aud`→`jwt_org`）→ `requireOrgMember`（受保护路由）。纯 Bearer API **默认关 CSRF**。

## 6. 明确不做（本版）

- 不把 SolidStart 源码迁进本仓  
- 平台超管 / 模块市场业务包  
- zent 混用、完整邮件实发  

## ADR-017 重构（v0.20.17）

SaaS Kit 后端已切换到声明式新特性（保持 `{ok, data, error}` 信封不变）：

- **todo 列表**：`service.listByOrg` 改用 `TodoModel.Query`（`textEq("org_id")` + `likeAll(title,message)` + `orderBy(id, desc)`），handler 用 `ctx.bindQuery(&ListFilters)` 绑定 `?q=` 搜索参数。
- **create/update 请求体**：auth / org / todo 全部 handler 用 `ctx.bindJson(&Body)` 取代手写 `parseJsonBody` + `defer deinit`（字符串由请求级 arena 持有，无需手动释放）。
- **body 结构体必填字段给默认值**（`email: []const u8 = ""`），使 `bindJson` 缺失字段走默认值，再由 `validate()` / 业务校验兜底成 400。

收益：每个 create/update handler 少 3 行样板且无泄漏路径；todo 列表获得声明式搜索/排序（列名编译期校验）。

## P0 生产底座（v0.20.17+）

- **全局限流**：`RateLimitHandler` 全局拦截器（默认 300 req/min/IP），超限返回 429 + `audit event=rate_limited`，分配失败 fail-open。
- **健康/指标**：`/health`（探针 JSON）与 `/metrics`（Prometheus）由框架 Metrics 驱动；`/api/health` 保留 SaaS 信封。
- **审计**：`zfinal.auditLog` 事件集扩展了 `email_sent` / `invite_sent` / `subscription_changed`；zfsaas 在登录失败、重置邮件、邀请、checkout 处埋点（实测登录失败输出 `audit event=auth_fail path=/api/auth/sign-in`）。
- **定时任务**：`src/task_runner.zig`（固定间隔线程）——订阅过期降级（60s）、未接受邀请清理（1h），实测 60s 周期运行正常。

## P1 认证完整性（v0.20.17+）

- **Refresh token 轮换 + 吊销**：sign-up/sign-in 返回 `refresh_token`（30 天）；`POST /api/auth/refresh` 轮换（旧 token 作废、签发新 access+refresh）；`POST /api/auth/revoke` 吊销；`auth_tokens` 表驱动，全部单次使用。
- **Email 验证**：sign-up 返回 `dev_verify_token`（mock 邮件）；`POST /api/auth/verify-email` 置 `email_verified_at`；`me` 响应带 `email_verified`；token 24h 单次。
- **框架修复**：读取请求体后 `getHeader` 会触发 `std.http` 的 `.received_head` 断言崩溃（webhook 先读 body 再取签名头必炸）。`Context.cacheHeaders()` 在 dispatch 时快照请求头，`getHeader` 改走缓存——任何"先读 body 再读 header"的 handler 都安全了。
