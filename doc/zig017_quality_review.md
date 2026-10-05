# ZFinal × Zig 0.17.0 品质提升审查

> **版本基线**：v0.28.2 / Zig **0.17.0**（正式版，仓库根 `.zig-version`）· 审查日期 **2026-10-04**
> **方法**：以 0.17 正式版 std / build API 为基准，5 个只读子审计（Io/并发、内存、性能、安全、构建/CI）+ 主代理复核。
> 每条标注 **✅验证**（源码/探针确认）或 **❓假设**（需 spike/实测）。
> **范围**：`src/` + `tools/zf` + build/CI/示例；不含新功能。
> **相关**：[zfinal_improvements.md](zfinal_improvements.md)（v0.24.0 遗留清单）· [best_practices.md](best_practices.md) · [PRODUCTION_AUDIT.md](../PRODUCTION_AUDIT.md)

## 0. 摘要

0.17 **编译期**适配已完成且全绿（`zig build` 57/57、`zig build test` 443 pass/16 skip/0 fail、release gate PASSED）。
本次审查发现真正的品质空间有两类：**既有缺陷**（部分可达远程 DoS / UAF / 注入，与 0.17 无关但必须修）与**未采用的 0.17 能力**（诊断、热路径、CI 有效性）。

### P0 清单（按建议修复顺序）

| # | 域 | 问题 | 位置 | 证据 |
|---|----|------|------|------|
| P0-1 | 安全 | PocketBase 示例全站 SQL 注入（含 `sqlite3_exec` 堆叠语句） | [record_api.zig:83](examples/pocketbase/src/controller/api/record_api.zig#L83) | ✅ |
| P0-2 | 安全 | 管理员 Cookie 为字面量 `"true"` → 认证绕过 | [auth_controller.zig:74](examples/pocketbase/src/controller/admin/auth_controller.zig#L74) | ✅ |
| P0-3 | 内存 | WS 握手 `catch unreachable`，超长 `Sec-WebSocket-Key` 远程 panic/UB | [handshake.zig:9](src/websocket/handshake.zig#L9) | ✅ |
| P0-4 | 并发 | `WebSocketManager` 快照指针在解锁后被释放 → UAF；且无写锁 | [manager.zig:78-91](src/websocket/manager.zig#L78-L91) · [server.zig:275-280](src/core/server.zig#L275-L280) | ✅ |
| P0-5 | 并发 | MQTT-over-TLS 把栈上 reader/writer 的指针交给 `tls.Client` 后返回 → 悬垂 | [mqtt.zig:95-123](src/plugin/mqtt.zig#L95-L123) | ✅ |
| P0-6 | 安全 | Windows 上 `RandomKit` 退化为时间戳+LCG；`randomBytes` 对外称 CSPRNG | [random_kit.zig:43-63](src/kit/random_kit.zig#L43-L63) | ✅ |
| P0-7 | 内存 | MySQL 流式迭代放行 `MYSQL_DATA_TRUNCATED` → 越界读 4096 栈缓冲 | [mysql.zig:575](src/db/drivers/mysql.zig#L575) · [:901](src/db/drivers/mysql.zig#L901) | ✅ |
| P0-8 | 并发 | 共享 `RedisClient` 无锁：请求/应答交错，限流与会话错乱 | [redis.zig:64-94](src/plugin/redis.zig#L64-L94) | ✅ |
| P0-9 | 并发 | `KafkaProducer` 完全无锁（消费者有锁，不一致） | [robustmq.zig:468-562](src/plugin/robustmq.zig#L468-L562) | ✅ |
| P0-10 | 正确性 | 读 body 后 `head.target` 被 std 置 undefined；`ctx.param()/getPara()` 读悬垂 | [server.zig:356](src/core/server.zig#L356) · [context.zig:316](src/core/context.zig#L316) | ✅ |
| P0-11 | 安全 | AI 业务工具对 `args` 无 tag 检查，类型不符即 panic/UB | [business.zig:80](src/ai/business.zig#L80) | ✅ |
| P0-12 | 安全 | 生产示例默认 JWT secret，未设置时不 fail-closed | [examples/production/main.zig:43](examples/production/main.zig#L43) | ✅ |
| P0-13 | 安全 | token/OAuth2 PKCE 走 P0-6 的弱随机 | [token.zig:54](src/token/token.zig#L54) · [oauth2.zig:80](src/plugin/oauth2.zig#L80) | ✅ |
| P0-14 | 构建 | 3 个 benchmark 强制 ReleaseFast，但导入的 zfinal 仍是 Debug | [build.zig:407](build.zig#L407) | ✅ |
| P0-15 | 构建 | `zf` CLI 的 PG/MySQL introspection 在 CI/release/install.sh 从未编译 | [build.zig:57-58](build.zig#L57-L58) · [ci.yml:78](.github/workflows/ci.yml#L78) | ✅ |

> P0-14/P0-15 说明：`benchmark/BASELINE.md` 的“zfinal 4.5–5.5x”结论方向仍成立（被测的 `getText+parseInt` 路径确实是 Debug 也存在的代码），但基准里的绝对 ns/op **混合了 Debug 框架 + ReleaseFast harness**，不能作为优化前后对比基线，需先修 V1。

---

## 1. 安全

### 1.1 P0（见上表 1/2/6/11/12/13）

**P0-1 PocketBase 示例 SQL 注入**：`db.exec` = `sqlite3_exec`（[sqlite.zig:76-83](src/db/drivers/sqlite.zig#L76-L83)）可执行分号堆叠语句；path 参数不做百分号解码但 **单引号在 URL path 中合法**。
`GET /api/collections/todos/records/x' OR '1'='1' --` 泄露数据；删除路径可 `; DROP TABLE ...`。
同一模式散布 [record_api.zig:268/290](examples/pocketbase/src/controller/api/record_api.zig#L268)、[record_controller.zig:27/180/200](examples/pocketbase/src/controller/admin/record_controller.zig#L27)、[base_model.zig:40/70/88](examples/pocketbase/src/model/base_model.zig#L40)。
**这是 AI codegen 会照抄的参考实现**，而真正的 ORM（`model.zig`）是安全的 → 示例在教错。修：全部改 `queryParams/execParams + ?`，表名白名单。

**P0-2 管理员认证绕过**：[auth_controller.zig:74](examples/pocketbase/src/controller/admin/auth_controller.zig#L74) 写 `admin_session="true"`，各 guard 只比较字面量（[auth_controller.zig:15-17](examples/pocketbase/src/controller/admin/auth_controller.zig#L15-L17)）。`Cookie: admin_session=true` 即管理员。修：服务端不透明会话 id（`src/core/session.zig`）。

**P0-6/P0-13 弱随机**：[random_kit.zig:43-63](src/kit/random_kit.zig#L43-L63) Windows/else 分支非密码学安全，且是 `randomBytes/uuid` 的唯一实现；token/PKCE/request-id 都依赖它。审查还发现 **0.17 移除了 `std.crypto.random`**（正确入口是 `std.Io.random` / `randomSecure`），因此 `hash_kit.zig:65` 是一个从未被分析的潜在编译错误。修：`osRandomBytes → io.random`，删掉平台 switch 与 `@panic`；`hash_kit.generateRandomString` 改用 `RandomKit.randomBytes` + 拒绝采样。**（S0 已修）**

**P0-11 AI 工具 panic**：[business.zig:80](src/ai/business.zig#L80) `(v orelse return &.{}).array` 未判 tag；审计用 0.17.0 ReleaseSafe 探针复现 union panic。修：`if (vv != .array) return error.InvalidArguments;`。

**P0-12 默认 JWT secret**：[examples/production/main.zig:43](examples/production/main.zig#L43)，仅当 `JWT_SECRET` 存在才覆盖，无 fail-closed。修：非 debug 构建下密钥缺失/短于 32 字节拒绝启动。

### 1.2 P1

- **P1-1 静态目录穿越**（❓需实测）：[handler.zig:53-72](src/ext/handler.zig#L53-L72) 前缀判断非目录边界（`/srv/public_backup` 可过），且 [:79](src/ext/handler.zig#L79) 用未解析路径读文件（symlink TOCTOU）。修：`O_NOFOLLOW` + 用已解析 fd 服务。
- **P1-2 限流塌成全局桶**（✅）：[examples/production/main.zig:84-91](examples/production/main.zig#L84-L91) `trust_proxy_headers=false`，但参考部署前面有 nginx → 所有客户端共用代理 IP 桶，一人打满全员被限。修：示例开 trust + `trusted_proxies`，或启动时告警。
- **P1-3 未鉴权发 JWT**（✅）：[handler.zig:75-90](examples/production/src/modules/api/handler.zig#L75-L90) `POST /api/token` 无鉴权签发。修：加登录门槛或移出示例。
- **P1-4 JWT alg 检查是子串搜索**（❓可利用性）：[jwt.zig:307-318](src/auth/jwt.zig#L307-L318) 不解析 JSON、忽略重复 alg、放过 `{"alg":"None","typ":"HS256"}`；secret 无最小长度约束。正面：HMAC 恒定时间比较（[jwt.zig:299-303](src/auth/jwt.zig#L299-L303)）。修：`std.json` 解析 + 精确 alg + ≥32 字节。
- **P1-5 AI SQL guard 可绕**（❓随驱动）：[business.zig:186-191](src/ai/business.zig#L186-L191) 未屏蔽 `#`（MySQL 注释）→ `... WHERE 1=1 # tenant_id` 通过租户校验；只读门槛仅 SELECT 前缀。修：屏蔽 `#`、强制租户谓词、只读 DB 角色。
- **P1-6 会话无 TTL**（✅）：[session.zig](src/core/session.zig#L121-L155) 记录时间但不校验/清理。修：idle/absolute TTL + sweep。
- **P1-7 上传路径/权限**（✅）：[multipart.zig:20-25](src/upload/multipart.zig#L20-L25) `saveTo` 任意路径；`createFile` 跟 umask；parser 无单文件大小/数量上限。修：私有化+校验、显式 0600、限额。
- **P1-8 CORS 不一致**（✅）：[interceptor.zig:219-233](src/interceptor/interceptor.zig#L219-L233) 默认 `*`；allowlist 路径反射 Origin+credentials 但不特判 `"*"`，而 [handler.zig:19](src/ext/handler.zig#L19) 特判。修：单一实现，`*` 与 credentials 互斥。
- **P1-9 安全头不全**（✅）：[security_interceptor.zig:16-22](src/ext/security_interceptor.zig#L16-L22) 无 CSP、含废弃 X-XSS-Protection；鉴权响应无 `Cache-Control: no-store`；HSTS 在明文响应也发。修：补 CSP/no-store，收敛。
- **P1-10 Redis 无 AUTH/TLS，bulk 长度算术无溢出保护**（✅）：[redis.zig:33-45/162-168](src/plugin/redis.zig#L33-L45)。修：AUTH/TLS 选项 + checked 长度。

### 1.3 P2
CSRF token 允许从 query 读取（[token/interceptor.zig:28](src/token/interceptor.zig#L28)）；重复头 `cacheHeaders` last-wins（代理可能取首个，❓）；PocketBase 错误日志打全量 SQL；`src/kit/hash_kit.zig` 只有 MD5/SHA，**无密码哈希原语**（argon2/bcrypt），AI 生成物会退化成快哈希。

---

## 2. 内存 / 资源 / 错误处理

### P0
- **WS 握手 `catch unreachable`**（✅，[handshake.zig:9](src/websocket/handshake.zig#L9)）：`combined_buf[256]`，key > 220 字节溢出 → ReleaseSafe panic / ReleaseFast UB。全仓唯一 `catch unreachable`。修：`Sha1.init()+update(key)+update(guid)+final` 增量哈希，彻底免缓冲。
- **MySQL 截断越界**（✅）：见 P0-7。
- **WS 分片重组无上限 + OOM 帧泄漏**（✅，[websocket.zig:371-392](src/websocket/websocket.zig#L371-L392)）：单帧上限 1 MiB 但 continuation 无限累积；`try appendSlice` 在 `frame.deinit()` 之前，OOM 泄漏。修：总长上限 + `errdefer frame.deinit()`。
- **SQLite `queryIter` bind/alloc 失败泄漏 prepared statement**（✅，[sqlite.zig:194-210](src/db/drivers/sqlite.zig#L194-L210)）：加 `errdefer finalize`。
- **PgIter 泄漏当前 PGresult**（✅，[postgres.zig:352-392/429-446](src/db/drivers/postgres.zig#L352-L392)）：deinit 未 `PQclear(current_res)`。
- **MySQL connect 配置串失败泄漏 MYSQL***（✅，[mysql.zig:41-59](src/db/drivers/mysql.zig#L41-L59)）：`errdefer mysql_close`。
- **`ConnectionPool.init` 部分失败泄漏全部连接**（✅，[pool.zig:36-70](src/db/pool.zig#L36-L70)）：errdefer 只 destroy 结构体。
- **`Row.intAt/floatAt/boolAt` 无边界检查**（✅，[result.zig:131-163](src/db/result.zig#L131-L163)）：与 A4（把它设为 ORM 默认）叠加会放大。
- **`src/deps.zig:13` 吞掉一个池连接**（✅）：`_ = pool.acquire() catch {}` 永久占一个槽。

### P1（同形态：外层 errdefer 不回收逐元素 dupe）
postgres [:226-230]、mysql [:237-243](src/db/drivers/mysql.zig#L237-L243)/[:716-722](src/db/drivers/mysql.zig#L716-L722)、sqlite [:130-137](src/db/drivers/sqlite.zig#L130-L137)/[:203-209](src/db/drivers/sqlite.zig#L203-L209)。
其他：router [:647-651](src/core/router.zig#L647-L651)（segments 泄漏）、[:342-374](src/core/router.zig#L342-L374)（拦截器链未释放）；multipart [:150-157](src/upload/multipart.zig#L150-L157) 与 context [:986-993](src/core/context.zig#L986-L993) 连续 dupe；context [:209-221](src/core/context.zig#L209-L221) `catch break` 使 errdefer 永不触发；template [:98-108](src/template/template.zig#L98-L108)/[:310-313](src/template/template.zig#L310-L313)（重复 `{% block %}` 确定性泄漏）；mcp_client 多处；result [:62-71](src/db/result.zig#L62-L71) OOM 与 NULL 不可区分。
**根因**：缺少 OOM 故障注入（backlog D1）。

### 设计/契约陷阱
- `Template.init` 存借用指针但 `deinit` 总 free（[template.zig:42-70](src/template/template.zig#L42-L70)）→ `init(alloc,"literal")+deinit` 非法释放。
- `McpClient.initWithTransport` 无条件接管调用方 transport 的 close（[:136-145](src/ai/mcp_client.zig#L136-L145)）。
- body 二次读仅 Debug panic，release 静默空（[context.zig:906-910](src/core/context.zig#L906-L910)）→ backlog B1 未闭合。
- `bindJson/parseJson` 把 OOM/传输错误映射成 BadRequest（[context.zig:935-968](src/core/context.zig#L935-L968)）。
- robustmq `putOffsetLocked(...) catch {}` 静默重复投递（[:864-866](src/plugin/robustmq.zig#L864-L866)）；wire 派生计数 `@intCast` 直接分配（[:1850-1869](src/plugin/robustmq.zig#L1850-L1869)）。

---

## 3. 并发 / Io / 取消

- **P0 MQTT-TLS 悬垂**（✅）：[mqtt.zig:95-123](src/plugin/mqtt.zig#L95-L123)；std `tls.Client` 保存 `*Reader/*Writer`（`Client.zig:24,32,918,928`）。修：先落 `self.tls`，再 `Client.init(&self.tls.stream_reader.interface, …)` 原地初始化，并加 TLS 回环测试。
- **P0 WS Manager UAF + 无写锁**（✅）：[manager.zig:78-126](src/websocket/manager.zig#L78-L126)、[server.zig:275-280](src/core/server.zig#L275-L280)；fanout 线程与 handler 线程可交错写帧（[fanout.zig:84-96](src/websocket/fanout.zig#L84-L96)）。修：连接级 refcount/pin + 写锁，归零才 free。
- **P0 Redis 客户端无锁**（✅）：[:64-94](src/plugin/redis.zig#L64-L94)；被三个 store 共享。修：`std.Io.Mutex` 包住一次命令或连接池。
- **P0 KafkaProducer 无锁**（✅）：[:468-562](src/plugin/robustmq.zig#L468-L562)；照抄消费者 `state_mutex/transport_mutex`。
- **P1 取消无法穿透 sockread → 优雅停机可能不生效**（✅）：[sockread.zig:17-99](src/core/sockread.zig#L17-L99) 无 `io.operate` → 无取消点；[server.zig:196-233](src/core/server.zig#L196-L233) 循环不查 shutdown；`read_timeout_ms=0` 时空闲连接可永久钉住 `start()`。修：循环内 `io.checkCancel()`+shutdown 检查，drain 到期 `shutdown(.both)`/`group.cancel`。
- **P1 WS/p2p slowloris**（✅）：[websocket.zig:210-342](src/websocket/websocket.zig#L210-L342)、[p2p.zig:365-385](src/plugin/p2p.zig#L365-L385) 读无 deadline。修：`BufReader` 走 `readSomeTimeout`。
- **P2 写超时注释与实现不符**（✅）：[server.zig:38-42/288-293](src/core/server.zig#L38-L42) 声称 0.17 移除了 `Operation.net_write/operateTimeout`——两者都在（`std/Io.zig:562`，且 `server.zig:333` 自己用 net_write）。现实现只在 drain 前查墙钟，阻塞 `sendmsg` 仍可挂死。修：`io.operateTimeout` 或 `SO_SNDTIMEO`/非阻塞+poll。
- **P2 裸 socket 绕行是否仍必要**（❓重点 spike）：`sockread` 的动机是共享 `Io.Threaded` 下 `net_read` 在 macOS 挂起；审计在 0.17.0 release 源码中**看不到**该现象（仓库注释引用的是 dev 快照）。若 2 线程 `Stream.reader` 压力探针通过，可逐步回到 `std.Io`。注意：**别给 connect 传 timeout**，`netConnectIpPosix` 对非 `.none` 会 `@panic`（`Threaded.zig:12410`），redis 的“无 dial timeout”绕行仍需保留。
- **P2 `async_limit` 会串行化 accept**（✅）：[server.zig:103-105](src/core/server.zig#L103-L105) 用默认 `cpu-1`，耗尽后 `Group.async` 在 accept 循环内联执行 → 新连接被拖住。修：显式放大 `async_limit` 或 accept 用 `concurrent` + 队列；shutdown 用 `Io.Event` 而非 100ms sleep 轮询。
- **P2 p2p 自旋锁前提为假**（✅）：[p2p.zig:47-49](src/plugin/p2p.zig#L47-L49) 称 futex 跨线程不安全，但 `std.testing.io` 就是 `Io.Threaded`，futex 是 OS futex。修：换 `std.Io.Mutex`。
- **P3 池**：connect 在池锁内（[pool.zig:125-132](src/db/pool.zig#L125-L132)）；`checked_out` 存在数据竞争（[:166-170](src/db/pool.zig#L166-L170) vs [:198](src/db/pool.zig#L198)）→ 改原子或持锁；`error.Canceled => continue` 经复核为**安全**（`checkCancel` 不会重复报错），补注释即可。
- **P3 `ThreadPool` 上限失效**（✅）：[thread_pool.zig:102-143](src/core/thread_pool.zig#L102-L143) 入队前查 `active_count`，但 pop 后才自增。
- **P4 NatsClient**（✅）：poll 无 deadline/不可 join、connect 丢同包后续字节、ping/parse 抢读、`subscriptions` 无锁；**P4 QueueClient**（✅）：`unsubscribe` 未持 mailbox 锁即 destroy。

**复核为“非缺陷”**：SIGTERM/EINTR 不会漏（posix read/poll 内部重试）；raw `std.Thread` 内调 `io.sleep` 安全；pool 已无 `pthread_mutex_t`（backlog 该条已过时）。

---

## 4. 性能 / 热路径

- **P0-1 ORM 解码仍是“文本 + parseInt”老路**（✅，且有仓内数据）：[model.zig:246-255](src/db/model.zig#L246-L255) → `row.get` → [result.zig:50-71](src/db/result.zig#L50-L71) 对已 typed 的 cell `bufPrint+dupe`，再 `parseInt`，再 free；PK 解码两次。`benchmark/BASELINE.md:92-98` 已测同模式：16,521 ns/row vs `getInt` 3,677 vs `intAt` 2,980。修：`mapFromRow` 按 `@typeInfo(f.type)` comptime 分派到 `getInt/getFloat`。**先把 P0-14 基准修正再量。**
- **P0-2 每请求全量 dup 头 + `head.target` 生命周期**（✅）：[server.zig:385](src/core/server.zig#L385) 必调 `cacheHeaders`（[:206-222](src/core/context.zig#L206-L222) dup 每个名/值），2N 次分配；`Context.init` 还预分配 cap16/cap8（[:126-135](src/core/context.zig#L126-L135)）。与 P0-10 同源：**一次拷贝 `head_buffer` 到 Context 自有存储**，头/query/path 都从副本解析，一起消灭 UB 与 2N 分配。
- **P0-3 每请求 new 一条 InterceptorChain**（✅）：[router.zig:578-599](src/core/router.zig#L578-L599)（404 分支已经是零分配顺序执行，可直接照抄）。
- **P0-4 param 路由缓存：全局锁 + miss 也缓存（负缓存污染）**（✅）：[router.zig:213-301](src/core/router.zig#L213-L301)、[:498](src/core/router.zig#L498)。随机 404 路径会挤掉热 `:id` 项，退化为 O(routes) 线性扫描。修：不缓存负项/分段/LRU，键改 `(method,path)` 组合哈希免格式化。
- **P0-5 静态路由 key 每次格式化 2–3 遍**（✅）：[router.zig:442-477](src/core/router.zig#L442-L477)；静态 map 把 method 当文本一起哈希。修：只按 path 建 key + `std.EnumArray(HttpMethod, ?usize)` 覆盖 `.ANY`。
- **P1-6 `extractParams` 每请求一个 StringHashMap**（✅）：[router.zig:116-149](src/core/router.zig#L116-L149)。修：定长 `[8]{name,value}` 或按需从 segment 偏移解码。
- **P1-7 gzip：~80KB 栈帧；>16KB 输出静默不压缩；finish 失败仍标 gzip**（✅）：[context.zig:605-635](src/core/context.zig#L605-L635)（`max_window_len=65536`）。修：flush 到 ArrayList、finish 失败视为失败、window 移出栈。
- **P1-8/9 `Context` 预分配 + `getHeader` O(n) 大小写线性扫**（✅）：[context.zig:224-234](src/core/context.zig#L224-L234)，被 auth/CSRF/CORS/XFF/request-id 每请求调 5–10 次。修：小写键存储 + 小写栈 key。
- **P1-10 模板逐字节 append、每表达式 3 次分配、无编译缓存**（✅）：[template.zig:237-252](src/template/template.zig#L237-L252)。修（廉价）：`ensureTotalCapacity`、按 `{{` 整段 append、无 filter 不 dupe。
- **P1-11 池每次 acquire 都 ping（MySQL 往返）**（✅）：[pool.zig:161-179](src/db/pool.zig#L161-L179)、[mysql.zig:135-139](src/db/drivers/mysql.zig#L135-L139)。修：按 idle 时间校验或交给 reaper。
- **P1-13 驱动 ~40 处 `std.debug.print`**（✅）：绕过编译期级别过滤与 Logger，且持有全局 stderr 锁。
- **P1-14 小项**（✅）：`start_ms` 无条件算（[server.zig:360](src/core/server.zig#L360)）→ 每请求最多 3 次 clock；`HttpMethod.fromString(@tagName(...))` 该换 comptime switch；`Route.specificity()` 应在注册时预计算；`urlDecode` 无 `%+` 时仍建 ArrayList；`metrics.routeClass` 每请求算两次；`extension.putOwned` 每 `setExt` 堆分配；`sockread.readVec` 组 8 路 iovec 只用 `dest[0]`。

---

## 5. Zig 0.17 能力采用

### 5.1 `error_tracing`（P0，已验证）
0.17 把错误返回追踪做成 **build 模块选项** `std.Build.Module.CreateOptions.error_tracing`（`std/Build/Module.zig:232`）；`build.zig:133` 未设置，全仓 0 引用。探针（ReleaseSafe）：

| 构建 | 运行 | 体积 |
|------|------|------|
| 默认 | `caught Boom` / **no trace** | 468,824 B |
| `-ferror-tracing` | `caught Boom` / **trace frames=32** | 505,080 B |

两种启用都验证可用（CLI 与 `b.createModule(.{ .error_tracing = true })`）。**建议**：新增 `-Derror-trace`，ReleaseSafe/Fast 默认开；CI ReleaseSafe job 断言 trace 非空。

### 5.2 `@branchHint`（P1，已验证缺失）
全仓 0 处；`@setCold` 在 0.17 **已移除**（本机 lib 命中 0），正确写法是 `@branchHint(.cold/.unlikely)`。候选：路由 cache miss/线性扫描 [router.zig:476-497](src/core/router.zig#L476-L497)、deadline/错误渲染 [server.zig:398](src/core/server.zig#L398)、body 重复读 [context.zig:907-915](src/core/context.zig#L907-L915)、`getInt/getFloat` 的 text/blob 回退 [result.zig:90-105](src/db/result.zig#L90-L105)。

### 5.3 `std.Io.random`（P0，见 §1）
**0.17 移除了 `std.crypto.random`**（`std.crypto` 无 `random` 成员）；CSPRNG 入口是 `std.Io.random(io, buf)`（进程内 CSPRNG，可能持有状态）与 `std.Io.randomSecure(io, buf) !void`（每次系统调用、无回退）。`session.zig:89` / `did.zig:31` 已正确使用；`hash_kit.zig:65` 是未分析的潜在编译错误，`random_kit` 的平台 switch 应统一过去。**（S0 已修）**

### 5.4 `std.StaticStringMap`（修正结论）
已用于 comptime 键（[context.zig:1140-1158](src/core/context.zig#L1140-L1158)）。**路由表是运行期注册的，不适用 StaticStringMap**；正确优化是 §4 P0-5（method EnumArray + path-only key），以及把 `HttpMethod.fromString` 的 if 链换成 comptime 映射。

### 5.5 其它 0.17 选项（P2/P3）
`stack_protector` / `sanitize_c` / `sanitize_thread` / `valgrind` / `unwind_tables` / `strip` 全部未用（`std/Build/Module.zig:214-234`）。建议：prod 明确 `strip` 与 frame pointer 策略；加一个 `sanitize_c`/`sanitize_thread` 的夜间 job（C 互操作 + 池/服务器并发）。
`std.Io.Uring` / `Dispatch`：0 引用，长线（依赖 §3 裸 socket 绕行先退役）。
`anyerror`：151 处，含公开 `Handler` 类型（[interceptor.zig:7](src/interceptor/interceptor.zig#L7)）；插件边界保留，框架内部渐进收敛。

---

## 6. 构建 / CI / 工具链

- **V1（P0）基准测的是 Debug zfinal**：bench 强制 `.optimize=.ReleaseFast`（[build.zig:407/429/451](build.zig#L407)）却导入顶层 Debug 的 `zfinal_mod`（[build.zig:133-137](build.zig#L133-L137)）；子代理探针证明被导入模块的 optimize 独立生效。→ `BASELINE.md` 绝对数字失真，修后才能谈优化。
- **V2（P0）`zf` CLI 的 PG/MySQL introspection 从未进 CI/release/install.sh**：CLI 用独立 `-Denable-pg/-Denable-mysql`（[build.zig:57-58](build.zig#L57-L58)），CI 只传 `-Ddriver_*`（[ci.yml:78-82](.github/workflows/ci.yml#L78-L82)），release/install.sh 也不传 → `zf crud:dsn` 报“未编译支持”。修：CI/release/install.sh 补 `-Denable-*`；两个 `enable` 命名冲突建议改名区分。（审计曾误报 drivers-live 无效，已撤回：框架侧 `driver_*` 会派生 `enable_pg/mysql`，live 覆盖有效。）
- **V4（P0）`addRunFile` 测试绕过已过时**：[build.zig:168/531/540/549/558](build.zig#L168) 用 `addRunFile`，而 [:215/237](build.zig#L215) 用正常 `addRunArtifact`；0.17.0 探针显示 `addRunArtifact` 正常且在 **通过**时多打印一条 `failed command:`（正是 CLAUDE.md 记为“cosmetic”的那行，其实由 workaround 自身产生）。修：换回 `addRunArtifact`，整套测试验证一次。
- **V5（P1）`zf check --deadcode` 未被任何 gate 执行**（我手动跑过：0/5232 dead，全绿）。修：full gate 增加该步。
- **V6（P1）`zf build/serve/test` 是打印后退出 0 的空壳**：AI 会误判成功。修：真执行或非零退出。
- **V7（P1）`examples/{blog,ai-live,smart-routing}` 从未编译**：0.17 API 漂移不可见。修：注册或用例化（smart-routing 目前仅文本扫描）。
- **V8（P2）Docker**：无 `.dockerignore`（`COPY . .` 带上 .zig-cache/.git/zig-pkg）、无最小 install step、`zigup/latest` 未校验、runtime 以 root 运行。
- **V9（P2）CI**：无 `timeout-minutes`、无 Zig 缓存、macOS 未跑 `test-zent-shop`、tag 流程无 ReleaseSafe 测试、`zf doctor` 用 `|| true` 吞错。
- **V10（P2）install.sh**：`ZIG_MIN_VERSION='0.14.0'` 死变量，不读 `.zig-version`，不检查 libsqlite3-dev dev 头。
- **V12（P3）**：`build.zig.zon .paths` 未含 `benchmark/`、`scripts/`、`.zig-version`，打包副本跑不了 bench/gate；backlog F1、C2 已完成。
- **V13（P3）**：zent-shop shell step 不传 target/optimize；NATS “disabled” 注释过时。

---

## 7. 落地顺序（建议）

| 批次 | 内容 | 前置 |
|------|------|------|
| **S0 立即（安全/崩溃，改动小）** ✅ 已完成 2026-10-04（见 §9） | §1 P0-1/2/6/11/12、§2 WS `catch unreachable`、MySQL 截断、SQLite/PG/MySQL/pool 泄漏、`deps.zig`、`Row.intAt` 边界 | 无 |
| **S1 并发正确性** ✅ 已完成 2026-10-04（见 §10） | MQTT-TLS 悬垂、WS Manager UAF+写锁、Redis/Kafka 锁、shutdown 取消点、slowloris deadline | 无 |
| **S2 先修测量再优化** | V1 基准修正 → §4 P0-1 typed 解码、P0-2 head_buffer 一次拷贝（同修 P0-10 UB）、P0-3 拦截器零分配 | V1 |
| **S3 诊断/CI** | error_tracing、Logger 归口、branchHint、deadcode 进 gate、V2/V3/V4/V6/V7、sanitize job | 无 |
| **S4 spike** | sockread 是否退役 → Uring/Event；P0-4 缓存策略；模板编译缓存；anyerror 收敛 | S2 |
| **S5 文档/红线** | 示例安全修复、`.dockerignore`、install.sh、CORS/安全头、会话 TTL | 无 |

## 8. 验证纪律

- 每条落地：`zig build gate-quick` 绿 + 相关回归；性能项必须 `run-bench`/`run-db-bench`/`run-sockread-bench` 前后数据进 `benchmark/BASELINE.md`（**先在 V1 修正后**）。
- **❓假设**在 spike 完成前不得写入 `PRODUCTION_AUDIT.md` 当作既成事实；P0-10、P1-1、P1-4、P1-5、sockread 退役都需要可复现测试或探针证据。
- 安全类 P0/P1 修复应同时补回归测试（尤其示例 SQLi/认证绕过，防止 AI codegen 再抄回）。

## 9. S0 修复记录（2026-10-04）

在 Zig 0.17.0 / v0.28.1 上完成，`zig build` 57/57、`zig build test` **445 passed / 16 skipped / 0 failed**、`gate-quick` PASSED。

**框架（src/）**
- **WS 握手**（[handshake.zig](src/websocket/handshake.zig)）：`acceptKey` 改为增量 SHA1，删除 256 字节栈缓冲与全仓唯一的 `catch unreachable`；新增超长 key 回归测试。
- **随机源**（[random_kit.zig](src/kit/random_kit.zig) / [hash_kit.zig](src/kit/hash_kit.zig)）：`osRandomBytes` 统一到 `std.Io.random`，删除 Windows 时间戳+LCG 弱回退与 `@panic`；`generateRandomString`（CSRF token 来源）改为 `RandomKit.randomBytes` + 拒绝采样，顺带修掉 `std.crypto.random` 这个潜在编译错误。
- **AI 工具**（[business.zig](src/ai/business.zig)）：`readArgs` 对非数组 `args` 返回 `error.InvalidArguments`；新增回归测试。
- **行访问**（[result.zig](src/db/result.zig)）：`intAt/floatAt/boolAt` 增加索引边界 panic。
- **MySQL**（[mysql.zig](src/db/drivers/mysql.zig)）：迭代放行 `MYSQL_DATA_TRUNCATED` → 返回 `error.DataTruncated`（`readMysqlCell` 再加长度防御）；connect 用单一 `errdefer mysql_close`，删除会导致二次释放的显式 close。
- **SQLite**（[sqlite.zig](src/db/drivers/sqlite.zig)）：`queryIter` 在 bind/列分配失败时 finalize 语句并回收已 dupe 的列名。
- **PostgreSQL**（[postgres.zig](src/db/drivers/postgres.zig)）：`PgIter` 读取失败时 `PQclear` 当前结果，`deinit` 兜底。
- **连接池**（[pool.zig](src/db/pool.zig)）：`init` 部分失败时统一回收已建连接与两个列表；[deps.zig](src/deps.zig) 归还预热连接。
- **生产示例**（[examples/production/main.zig](examples/production/main.zig)）：非 Debug 构建缺少/过短 `JWT_SECRET` 时拒绝启动。

**PocketBase 示例**（[examples/pocketbase](examples/pocketbase)）
- 新增 [util.zig](examples/pocketbase/src/util.zig) 标识符白名单 + [auth/admin_session.zig](examples/pocketbase/src/auth/admin_session.zig) 服务端会话（不透明随机 token，24h TTL，`std.Io.Mutex` 保护）。
- 把 `admin_session="true"` 伪造 Cookie 替换为服务端校验；给缺失鉴权的 `record_controller.create/delete` 补上校验。
- 所有用户可控的值参数化（`queryParams/execParams`）：record id、登录 email/password_hash、API token、`_collections` 名称；动态表/列名一律经标识符白名单。
- 顺带修：`record_controller.redirect` 未发送响应、`record_api.sendError` 把错误状态重置成 200。

**端到端验证**（`zig build run-pb` + curl）：
`GET /api/collections/posts/records/x'OR'1'='1` → **404**（合法 id 仍 200）；伪造 `admin_session=true` 访问 dashboard/create → **302 /admin/login**；登录 `email=' OR '1'='1` → **302 /admin/login?error=1**；正确凭据 → 302 dashboard，Cookie 为 64 位十六进制 token，dashboard 200。

## 10. S1 修复记录（2026-10-04）

在 S0 之后完成，`zig build test` **446 passed / 16 skipped / 0 failed**，新增 WebSocket 生命周期回归测试。

- **WebSocket 生命周期**（[websocket.zig](src/websocket/websocket.zig) / [manager.zig](src/websocket/manager.zig)）：连接改为引用计数（创建者 + manager 列表 + 每次快照各持一份），最后一次 `unref` 才关闭并释放；`closed` 改原子量；所有帧写入走 per-connection `write_mutex`（`sendFragmented` 也纳入）。manager 快照用 `snapshotRefs`/`releaseSnapshot`，`removeConnection` 只释放列表引用。`server.zig` 的 handler defer 从「remove+deinit+destroy」改为「removeConnection + unref」。这样 reap/broadcast 快照不会再碰到被 handler 释放的连接。
- **MQTT-over-TLS**（[mqtt.zig](src/plugin/mqtt.zig)）：把 reader/writer 先放进 `self.tls`，再对 `&self.tls.?.stream_reader.interface` 调 `tls.Client.init`，避免把栈局部地址交给会长期保存的 client；顺带移除 TLS 初始化失败时的双重释放。
- **Redis**（[redis.zig](src/plugin/redis.zig)）：`commandWithDeadline` 与 `disconnect` 都用 `std.Io.Mutex`（`lockUncancelable`，避免中途放弃导致 RESP 流错位）串行化整轮 write-then-read。
- **KafkaProducer**（[robustmq.zig](src/plugin/robustmq.zig)）：加入与 consumer 相同的 `state_mutex`/`transport_mutex`，覆盖 socket、correlation id 与 `topic_stats`；锁顺序固定 transport→state，不构成环。
- **停机**（[server.zig](src/core/server.zig)）：keep-alive 每轮循环先查 `shutdown.isShuttingDown()`；drain 超时后 `group.cancel(io)` 唤醒停在取消点的 fiber。
- **slowloris**（[sockread.zig](src/core/sockread.zig) / [websocket.zig](src/websocket/websocket.zig)）：`BufReader` 增加可选读 deadline（`initWithTimeout`），WebSocket 继承 HTTP `read_timeout_ms`，半帧后停住的客户端会让读超时并结束连接。

> 仍存（S2+）：pool connect 在锁内、`checked_out` 数据竞争、p2p 自旋锁、NatsClient/QueueClient 细节、以及 §6 的构建/CI 项。
