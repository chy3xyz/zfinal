# 进阶功能

> **版本**：对齐 v0.20.9+ · 修订 **2026-07-31**  
> 生产装配抄 [`examples/production`](../examples/production/) · 总索 [best_practices.md](best_practices.md)

## 1. 拦截器 (Interceptors)

请求前后横切。优先返回 `HttpError`；仅在已写响应时 `return false`（如 CORS 预检）。

```zig
fn authBefore(ctx: *zfinal.Context, _: ?*anyopaque) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) return error.Unauthorized;
    return true;
}
```

**Caller-owned cfg**（禁止 `createX(&.{…})`）：

```zig
var jwt_cfg: zfinal.JwtAuthConfig = .{ .secret = secret, .opts = .{ .leeway_sec = 30 } };
try app.addGlobalInterceptor(zfinal.createJwtAuthInterceptorWithOptions(&jwt_cfg));
```

Stock：`zfinal.stock.createBodyLimitInterceptor` / `Timeout` / `Compression` / `Trace`。  
详情：[http_ergonomics.md](http_ergonomics.md)。

## 2. 验证器 (Validators)

```zig
var validator = zfinal.Validator.init(ctx.allocator);
defer validator.deinit();
try validator.validateRequired("username", username);
try validator.validateEmail("email", email);
if (validator.hasErrors()) {
    zfinal.http_error.setDetail(ctx, "validation");
    return error.BadRequest;
}
```

## 3. 文件上传

```zig
if (try ctx.getFile("avatar")) |f| {
    defer f.deinit();
    try f.saveToDir("uploads");
    try ctx.renderJson(.{ .msg = "Upload success", .filename = f.filename });
}
```

## 4. 插件系统 (Plugins)

可启停能力进 `plugin/`（Cache / Cron / Redis / MQTT / …）。半成品用 `zfinal.experimental.*` + ADR。  
消息：稳定面 `QueueNatsClient` / `QueueRobustMQClient`（[nats.md](nats.md) · [robustmq.md](robustmq.md)）。

## 5. 规模与端口

L2/L3 抽 `ports` + `adapters`：`zf g port store|cache|bus`；示例 `ports-l2` / `ports-l3`。  
见 [progressive_architecture.md](progressive_architecture.md)。

## 6. OpenAPI

`zf openapi`：bearerAuth、JSON body、实体 `Name`/`NameInput` DTO、HttpError schema。  
与默认信封字段保持一致（[api_envelope.md](api_envelope.md)）。
