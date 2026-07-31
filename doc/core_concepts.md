# 核心概念

> **版本**：对齐 v0.20.9+ · 修订 **2026-07-31**  
> 更深实践：[best_practices.md](best_practices.md) · [http_ergonomics.md](http_ergonomics.md) · [smart_routing.md](smart_routing.md)

## 1. 路由 (Routing)

**绿场推荐**：模块内 `actions.zig` 为真源，经 `zf routes` 生成 `routes.zig`（[smart_routing.md](smart_routing.md)）。

手写注册仍可用（示例 / 存量）：

```zig
pub fn configRoutes(app: *zfinal.ZFinal) !void {
    try app.get("/", IndexController.index);
    try app.get("/users/:id", UserController.show);
    try app.post("/users", UserController.create);
}
```

禁止与 `actions.zig` **双真源**并存于同一模块。

## 2. Handler（原「控制器」）

每个处理函数接收 `*zfinal.Context`。失败优先返回 `HttpError`，由 `dispatch` 渲染。

```zig
pub fn show(ctx: *zfinal.Context) !void {
    const id = try zfinal.extract.requireParamInt(ctx, "id");
    // … call service …
    try ctx.renderJson(.{ .id = id, .name = "User Name" });
}
```

生成 CRUD 使用 `failHttp`；勿手搓 `{ .err = … }` 后再 `return error.*`。

## 3. 上下文 (Context)

### 参数

```zig
const name = try ctx.getPara("name");
const id = try zfinal.extract.requireParamInt(ctx, "id");
```

### 响应

```zig
try ctx.renderJson(.{ .ok = true, .data = … });
try ctx.renderText("Hello World");
try ctx.renderFile("path/to/file.pdf", "download_name.pdf");
```

失败信封默认 `{ "err", "msg", "detail"? }` — [api_envelope.md](api_envelope.md)。

### Session / Cookie / State

```zig
try ctx.setCookie("key", "value", 3600);
try ctx.setSessionAttr("user", user_obj);
app.setState(App, &app_state);
const st = try ctx.state(App);
```

## 4. 三层与数据层

```
handler → service → model   （SQL / DB）
handler → service → persistence → zent Schema  （zent）
```

一模块只选一种数据主力。[architecture_best_practices.md](architecture_best_practices.md)。

## 5. 拦截器

横切鉴权 / CORS / 限流。cfg 必须 **caller-owned** `*const Cfg`（禁止临时 `&.{…}`）。
见 [advanced.md](advanced.md) · [http_ergonomics.md](http_ergonomics.md)。
