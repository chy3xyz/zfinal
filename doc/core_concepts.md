# 核心概念

## 1. 路由 (Routing)

路由配置在 `src/config/routes.zig` 中进行。ZFinal 支持 RESTful 风格的路由定义。

```zig
pub fn configRoutes(app: *zfinal.ZFinal) !void {
    // 基础路由
    try app.get("/", IndexController.index);
    
    // 路径参数
    try app.get("/users/:id", UserController.show);
    
    // RESTful 方法
    try app.post("/users", UserController.create);
    try app.put("/users/:id", UserController.update);
    try app.delete("/users/:id", UserController.delete);
}
```

## 2. 控制器 (Controller)

控制器是处理 HTTP 请求的核心。每个处理函数接收一个 `*zfinal.Context` 参数。

```zig
pub const UserController = struct {
    pub fn show(ctx: *zfinal.Context) !void {
        // 获取路径参数
        const id = ctx.getPathParam("id") orelse "0";
        
        try ctx.renderJson(.{
            .id = id,
            .name = "User Name"
        });
    }
};
```

## 3. 上下文 (Context)

`Context` 对象封装了 Request 和 Response，提供了丰富的 API。

### 获取参数

```zig
// Query 参数: ?name=Alice&age=18
const name = try ctx.getPara("name"); // ?[]const u8
const age = try ctx.getParaToInt("age"); // ?i32
const age_def = try ctx.getParaToIntDefault("age", 18); // i32

// 路径参数: /users/:id
const id = ctx.getPathParam("id");
```

### 响应渲染

```zig
// 渲染 JSON
try ctx.renderJson(.{ .status = "ok", .data = ... });

// 渲染文本
try ctx.renderText("Hello World");

// 文件下载
try ctx.renderFile("path/to/file.pdf", "download_name.pdf");
```

### Session 与 Cookie

```zig
// Cookie
try ctx.setCookie("key", "value", 3600); // max_age = 3600s
const val = try ctx.getCookie("key");

// Session (需先配置 Session 插件)
try ctx.setSessionAttr("user", user_obj);
const user = ctx.getSessionAttr("user");
```
