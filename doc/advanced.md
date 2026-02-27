# 进阶功能

## 1. 拦截器 (Interceptors / AOP)

拦截器用于在请求处理前后执行逻辑，如日志记录、权限检查等。

### 定义拦截器

```zig
fn authBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null) {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .@"error" = "Unauthorized" });
        return false; // 拦截请求，不再继续
    }
    return true; // 放行
}

pub const AuthInterceptor = zfinal.Interceptor{
    .name = "auth",
    .before = authBefore,
};
```

### 注册拦截器

**全局拦截器**: 对所有请求生效。
```zig
try app.addGlobalInterceptor(AuthInterceptor);
```

**路由级拦截器**: 仅对特定路由生效。
```zig
try app.getWithInterceptors("/admin", AdminController.index, &.{AuthInterceptor});
```

## 2. 验证器 (Validators)

ZFinal 提供了一套流式验证 API。

```zig
pub fn create(ctx: *zfinal.Context) !void {
    var validator = zfinal.Validator.init(ctx.allocator);
    defer validator.deinit();

    const username = try ctx.getPara("username");
    const email = try ctx.getPara("email");

    try validator.validateRequired("username", username);
    try validator.validateEmail("email", email);
    try validator.validateMinLength("username", username, 3);

    if (validator.hasErrors()) {
        ctx.res_status = .bad_request;
        // 直接序列化 validator 输出错误信息
        try ctx.renderJson(.{ .errors = validator });
        return;
    }
    
    // ... 业务逻辑
}
```

## 3. 文件上传

```zig
pub fn upload(ctx: *zfinal.Context) !void {
    // 获取上传的文件
    const file = try ctx.getFile("avatar");
    if (file) |f| {
        defer f.deinit();
        // 保存到指定目录
        try f.saveToDir("uploads");
        try ctx.renderJson(.{ .msg = "Upload success", .filename = f.filename });
    }
}
```

## 4. 插件系统 (Plugins)

插件用于扩展框架功能，如缓存、定时任务等。

### 缓存插件

```zig
var cache = zfinal.CachePlugin.init(allocator);
try app.addPlugin(cache);

// 使用缓存
try cache.set("key", "value", 60); // 60s TTL
const val = cache.get("key");
```

### 定时任务插件

```zig
var cron = zfinal.CronPlugin.init(allocator);
try cron.addTask("* * * * *", myTaskFunction);
try app.addPlugin(cron);
```
