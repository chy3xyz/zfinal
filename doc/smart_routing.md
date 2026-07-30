# ZFinal 智能路由最佳实践

> **立场**：绿场、无存量兼容包袱 → **一套真源、一种方言、只读运行时**。  
> **灵感**：JFinal（约定 + ActionKey）· **实现**：`actions.zig` + `zf routes` · **内核**：表驱动匹配。  
> **相关**：[architecture_best_practices.md](architecture_best_practices.md) · [codegen.md](codegen.md) · [reverse_proxy.md](reverse_proxy.md) · [openapi / zf](zf_cli.md)

---

## 0. 总览

```
actions.zig (真源)
      │  zf routes --json
      ▼
routes.zig (@generated)  +  manifest.json
      │  register(&app)
      ▼
Router（启动后只读）
  static HashMap  →  :param 段匹配  →  *wildcard
      │
      ▼
Interceptor（global → module → action）→ Handler
```

| 你要… | 改哪里 |
|-------|--------|
| 标准 CRUD | `actions` 里写 `index/show/create/update/destroy` |
| 自定义动作 | `actions` 加一行 + `method` |
| 换 URL | `action_key` |
| 父子资源 | `module.nested_under` |
| 静态/SPA 兜底 | `path = "/*path"` 或绝对 `action_key` |

---

## 1. 原则（必须遵守）

1. **一条真源**：路由只来自各模块 `actions.zig`，经 `zf routes` 生成；禁止业务里散落 `app.get/post`（框架自测除外）。  
2. **约定默认，显式覆盖**：标准 CRUD 零配置；特例用 `action_key` / `path` / `method`，仍进同一管线。  
3. **运行时零反射、零拼装**：`match` 只查表；URL 在生成期算死。  
4. **一种 URL 方言**：REST + kebab；无 JFinal `/list` 双风格开关。  
5. **启动后只读**：禁止运行时增删路由。  
6. **AI 可审计**：`--json` manifest 必含 path / method / handler / source / params。  
7. **冲突失败**：同 `METHOD + 展开后 path` → 生成失败（非静默覆盖）。  
8. **显式暴露**：未写入 `actions` 的 `pub fn` **永不**自动挂路由。

---

## 2. URL 方言（拍板）

### 2.1 路径风格

- 全小写 **`kebab-case`**
- 模块名 `UserProfile` / `user_profile` → 前缀 `/user-profile`
- 自定义动作 `fooBar` / `foo_bar` → `/foo-bar`
- 前缀一律以 `/` 开头、**无**尾 `/`（根模块除外用 `""` 仅测试）
- Query string **不是**路由的一部分；`?x=` 不参与匹配

### 2.2 标准动作 → HTTP（纯 REST）

| 动作名 | Method | 相对 path | 说明 |
|--------|--------|-----------|------|
| `index` | GET | `` | 集合 |
| `show` | GET | `/:id` | 单条；主键名默认 `id` |
| `create` | POST | `` | 创建 |
| `update` | PUT | `/:id` | 全量更新 |
| `patch` | PATCH | `/:id` | 可选；局部更新 |
| `destroy` | DELETE | `/:id` | 删除 |
| 其它 `name` | 默认 **POST** | `/<kebab(name)>` | 可用字段覆盖 |

模块 `users`（`prefix=/users`）展开：

```
GET    /users
GET    /users/:id
POST   /users
PUT    /users/:id
PATCH  /users/:id          # 若声明了 patch
DELETE /users/:id
POST   /users/reset-password
```

### 2.3 API 版本

- 版本只做 **外层前缀组**，不写进动作名。  
- 应用入口：`try app.mount("/api/v1", &.{ users, orders });` 或生成器为每个 module 加 `module.api_prefix = "/api/v1"`。  
- 同时服务 v1/v2：两套 prefix 或两套 module name（`users_v2`），禁止同一 actions 表魔法分叉。

### 2.4 冲突策略

比较键：`METHOD + '\0' + absolute_pattern`（`:id` 与 `:user_id` 视为不同模式）。

- 生成期发现重复 → **非零退出** + 指出两个 module/action。  
- 注册期（防御）再 assert 一次。  
- **不允许**「先注册优先」。

### 2.5 嵌套资源（`nested_under`）

用于 `/users/:user_id/orders/:id`，禁止手写长串当常规手段。

```zig
pub const module = .{
    .name = "orders",
    .prefix = "/orders",
    .nested_under = .{ .parent = "users", .param = "user_id" },
};
```

**展开（生成期）：**

```
abs = parent.abs_prefix + "/:" + param + child.prefix + action.rel

→ GET    /users/:user_id/orders
→ GET    /users/:user_id/orders/:id
→ POST   /users/:user_id/orders
→ PUT    /users/:user_id/orders/:id
→ DELETE /users/:user_id/orders/:id
```

| 项 | 规则 |
|----|------|
| 深度 | **最多 2 层**（父→子）；禁止孙级链式 `nested_under` |
| 更深 | 绝对 `action_key`（可含多段 `:param`） |
| 父模块 | 必须可解析；禁止环；父须先于子被 `zf` 解析 |
| 参数名 | 父键 = `param`（如 `user_id`）；子主键仍 `:id`；**禁止**两段都叫 `:id` |
| Handler | `ctx.param("user_id")`、`ctx.param("id")` |
| 鉴权 | 子模块自列 `interceptors`；需要「属于该 user」在 **service** 校验，不单靠路由 |
| 顶层同资源 | 另开 module name（如 `orders-admin` → `/orders-admin`）；绝对 path 仍不得撞车 |

三层示例（仅 `action_key`）：

```zig
.{ .name = "showItem", .method = .GET, .handler = handler.showItem,
   .action_key = "/users/:user_id/orders/:order_id/items/:id" }
```

### 2.6 尾通配（`*path`）

「前缀固定 + 后缀整段吞掉」——静态站、下载、SPA fallback。**不是**正则引擎。

**语法：**

- 仅允许模式 **最后一段** 为 `*name`（`*path` / `*rest`）
- 整 pattern **至多一个** `*`
- 禁止 `*path` 后再跟静态段；禁止 `/foo/*/bar`

```zig
.{ .name = "get", .method = .GET, .path = "/*path", .handler = handler.get }
// GET /assets/*path  →  /assets/a/b/c.txt  ⇒  path = "a/b/c.txt"
```

| 项 | 规则 |
|----|------|
| 段类型 | `wildcard`（补齐 `static` / `param`） |
| 捕获 | 剩余段用 `/` 拼接；**无**前导 `/` |
| `/assets` vs `/assets/…` | 恰好 `/assets` **不**命中 `/*path`；首页另挂 `index` |
| 优先级 | **静态 > `:param` > `*wildcard`**（注册排序 + 匹配序） |
| 安全 | 必用 `ctx.wildcardPath("path")`（规范化 + 拒绝 `..` + 可选拒绝对盘符） |
| OpenAPI | `string`；description 标明 catch-all |

---

## 3. 动作表字段规范（schema）

### 3.1 `module` 对象

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | string | ✅ | 模块标识；manifest / 日志用 |
| `prefix` | string | 否 | 默认 `/` + kebab(name) |
| `api_prefix` | string | 否 | 如 `/api/v1`，拼在最前 |
| `interceptors` | []string | 否 | 组级拦截器名 |
| `nested_under` | struct | 否 | `{ parent, param }` 见 §2.5 |
| `param_id` | string | 否 | 默认 `"id"`；改主键段名时用 |

### 3.2 `actions[]` 元素

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | string | ✅ | 动作名；标准名走 §2.2 推导 |
| `handler` | fn | ✅ | `*const fn (*Context) anyerror!void` |
| `method` | enum | 否 | 覆盖推导；自定义动作默认 POST |
| `path` | string | 否 | 相对 prefix；如 `/*path`、`/export` |
| `action_key` | string | 否 | 以 `/` 开头的绝对 path；设了则忽略相对推导 |
| `interceptors` | []string | 否 | 动作级，接在 module 之后 |
| `deprecated` | bool | 否 | manifest / OpenAPI deprecated |

互斥：`action_key` 与（相对 `path` + 标准推导）同时出现时，**以 `action_key` 为准**，生成器可 warn。

### 3.3 目录与文件

```
src/modules/<area>/<name>/
├── handler.zig      # ai-edit-zone
├── service.zig
├── model.zig        # 或 zent persistence
├── actions.zig      # ★ 真源
└── routes.zig       # @generated
```

`main` / `app_boot.zig` 只：

```zig
try app.mountApi("/api/v1"); // 可选
try users.routes.register(&app);
try orders.routes.register(&app);
try assets.routes.register(&app);
```

---

## 4. 完整示例

### 4.1 顶层 + ActionKey

```zig
// modules/users/actions.zig
pub const module = .{
    .name = "users",
    .prefix = "/users",
    .interceptors = .{ "auth", "access_log" },
};
pub const actions = .{
    .{ .name = "index", .handler = handler.index },
    .{ .name = "show", .handler = handler.show },
    .{ .name = "create", .handler = handler.create },
    .{ .name = "update", .handler = handler.update },
    .{ .name = "destroy", .handler = handler.destroy },
    .{ .name = "login", .method = .POST, .action_key = "/auth/login", .handler = handler.login },
    .{ .name = "resetPassword", .method = .POST, .handler = handler.resetPassword },
};
```

### 4.2 嵌套

```zig
// modules/shop/orders/actions.zig
pub const module = .{
    .name = "orders",
    .prefix = "/orders",
    .nested_under = .{ .parent = "users", .param = "user_id" },
    .interceptors = .{"auth"},
};
pub const actions = .{
    .{ .name = "index", .handler = handler.index },
    .{ .name = "show", .handler = handler.show },
    .{ .name = "create", .handler = handler.create },
    .{ .name = "update", .handler = handler.update },
    .{ .name = "destroy", .handler = handler.destroy },
};
```

生成片段：

```zig
// @generated
pub fn register(app: anytype) !void {
    var g = app.group("/users/:user_id/orders", &.{auth});
    try g.get("", handler.index);
    try g.get("/:id", handler.show);
    try g.post("", handler.create);
    try g.put("/:id", handler.update);
    try g.delete("/:id", handler.destroy);
}
```

### 4.3 尾通配

```zig
pub const module = .{ .name = "assets", .prefix = "/assets" };
pub const actions = .{
    .{ .name = "index", .method = .GET, .path = "", .handler = handler.index },
    .{ .name = "get", .method = .GET, .path = "/*path", .handler = handler.get },
};
```

---

## 5. Router 内核（实现契约）

### 5.1 段类型

```
static     "users"
param      ":id" | ":user_id"     → 单段，非空
wildcard   "*path"               → 仅末段，吞剩余
```

### 5.2 匹配算法（概念）

1. 构造 key `METHOD + ":" + raw_path`（无 query）。  
2. **静态表** O(1)；命中则返回。  
3. 按注册序（已按优先级排序）走段匹配：  
   - 静态段：相等  
   - param：非空一段  
   - wildcard：其余拼串  
4. 方法不匹配但 path 匹配 → **405**（Allow 头列出允许方法）；完全无 path → **404**。

### 5.3 注册排序

同一应用内：先挂 **无通配** 路由，再挂通配；同前缀下静态/参数已由生成器按「更具体在前」排出。防御性：Router 也可在 `seal()` 时稳定排序。

### 5.4 Context API

| API | 行为 |
|-----|------|
| `ctx.param(name)` | `:param` 或通配名；缺失返回 null / error（二选一，框架内统一） |
| `ctx.wildcardPath(name)` | 取通配值 + `rejectDotDot` + 拒绝对路径；失败 → 400 |
| `ctx.pathParams` | 只读迭代（调试） |

### 5.5 HEAD / OPTIONS

- **HEAD**：若存在同 path 的 GET，则复用 GET handler，丢弃 body（或框架薄包装）。  
- **OPTIONS**：可由全局 CORS 拦截器处理；不必为每个资源生成 OPTIONS 行（除非显式声明）。

---

## 6. 拦截器

顺序（固定）：

```
global before[]  →  module before[]  →  action before[]
→ handler
→ action after[]  →  module after[]  →  global after[]   # after 逆序
```

- Global：`app.use(...)`  
- Module：`module.interceptors`  
- Action：`actions[i].interceptors`  
- before 返回 `false`：跳过 handler 与后续 before；**已跑过的 after 是否执行** → 定为 **不执行**（与当前链行为对齐，文档写死）。

---

## 7. 框架 API 面（绿场最小集）

| API | 谁调用 |
|-----|--------|
| `app.use(interceptor)` | 应用 boot |
| `app.mountApi(prefix)` / `RouteGroup` | 版本前缀组；`mountApi` = `RouteGroup.init` |
| `group.get/post/put/patch/delete` | **仅** `@generated` routes.zig |
| `routes.register(&app)` | boot 按模块调用 |
| `Router.seal()` | **必选**：`ZFinal.start` 内调用；特异度排序、重建静态索引、禁止再 add |

业务代码 **禁止** 直接 `app.get`；`zf check` 扫描违规。

---

## 8. 工具链与检查

```bash
zf routes --json              # 扫 modules/**/actions.zig → routes.zig + manifest
zf crud:sql|zent …            # 产出/更新 actions（标准五动作），再 routes
zf check                      # 见下表
zf openapi                    # 与 manifest 一致
```

`zf routes` 优先用 `std.zig.Ast` 解析 `actions.zig`；仅当源码无法过 AST（语法破损）时回退启发式扫描。

### 8.1 `zf check` 规则（路由相关）

| 规则 | 级别 |
|------|------|
| 业务 `src/` 出现 `app.get/post/...` 手写注册 | error |
| 手改 `@generated` `routes.zig` | error |
| `actions` 外 `pub fn` 被当成路由（无） | — |
| `nested_under` 环 / 父不存在 / 深度>2 | error |
| 通配不在末段 / 多个 `*` | error |
| METHOD+path 冲突 | error |
| 双主键名 `:id` 嵌套 | error |

### 8.2 Manifest

```json
{
  "method": "GET",
  "path": "/users/:user_id/orders/:id",
  "handler": "modules.shop.orders.handler.show",
  "source": "nested",
  "module": "orders",
  "params": ["user_id", "id"],
  "nested_under": { "parent": "users", "param": "user_id" },
  "interceptors": ["auth"]
}
```

`source`: `convention` | `action_key` | `schema` | `nested` | `wildcard`.

---

## 9. 安全与运维（与路由绑定）

| 主题 | 要求 |
|------|------|
| Keep-alive | `force_connection_close=true`，**respond 前**清 `keep_alive`（见 reverse_proxy.md） |
| Io 槽 | 每连接一 fiber；勿 per-conn 再 async watchdog |
| 通配 | 只通过 `wildcardPath`；根目录/敏感路径黑名单在 handler |
| 嵌套鉴权 | 路由只保证形状；`user_id` 归属在 service 校验 |
| DB 池 | 禁止双归还；`AlreadyReleased` 打日志，勿 `catch {}` |
| 超时 | `read_timeout_ms` 管空闲读；`request_timeout_ms` 管 handler deadline |

---

## 10. 测试矩阵（落地验收）

| 用例 | 期望 |
|------|------|
| `GET /users` | index |
| `GET /users/1` | show，`id=1` |
| `GET /users/1/orders` | nested index，`user_id=1` |
| `GET /users/1/orders/9` | nested show |
| `GET /assets` | assets index（若声明） |
| `GET /assets/x/y` | wildcard，`path=x/y` |
| `GET /assets/../etc/passwd` | 400（wildcardPath） |
| 静态 `/assets/logo.png` 与 `/*path` 并存 | 静态优先 |
| 重复 METHOD+path | `zf routes` 失败 |
| `POST /users` 但只注册 GET 集合 | 405 + Allow |

---

## 11. 与 JFinal（概念对照）

| JFinal | 本实践 |
|--------|--------|
| Controller + 约定 URL | `modules/*` + REST 方言 |
| `@ActionKey` | `action_key` |
| 手写 nested | `nested_under` |
| 静态映射 | `*path` |
| 扫 classpath | `zf routes` 扫 `actions.zig` |
| 运行时 Routes | 禁止 |

---

## 12. 不做的事

- 双风格 URL、存量 `app.get` 兼容层  
- 运行时反射 / 热挂路由  
- 通用正则、中间通配、多 `*`  
- 三层+ `nested_under` 链  
- 「先注册优先」  
- 自动暴露全部 `pub fn`

---

## 13. 落地顺序

1. ~~定方言写入规范；`zf check` 规则表落地。~~ ✅  
2. ~~Router：`wildcard` + 优先级 + `wildcardPath` + 405 + `seal()`。~~ ✅  
3. ~~`zf routes` + `crud:*` 产出 `actions.zig`；nested / `*path` / `action_key`。~~ ✅  
4. ~~示例：`examples/smart-routing`；OpenAPI 扫 `action_key` + merge actions。~~ ✅  
5. ~~Module/Action 拦截器进生成（`src/interceptors.zig` 名字表）；manifest `params`/`interceptors`；check 升 error。~~ ✅  
6. ~~`examples/production` 迁 `actions.zig`；CI `zf routes --check`（smart-routing + production）。~~ ✅  
7. ~~Zig AST 级 `actions.zig` 解析（`std.zig.Ast`）；启发式 parser 仅作兜底。~~ ✅  

---

## 14. 一句话

> **REST + kebab + `actions.zig`；嵌套用 `nested_under`，静态用末段 `*path`；生成只读表、冲突即失败 —— 绿场下表达力与可维护性双满分，不靠运行时魔法。**
