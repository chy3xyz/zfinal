# HTMX 模板系统

ZFinal 提供了基于 HTMX 的模板系统，让你可以构建现代化的动态 Web 应用。

## 概述

HTMX 是一个轻量级的 JavaScript 库，允许你直接在 HTML 中使用 AJAX、CSS Transitions、WebSockets 等功能，无需编写 JavaScript 代码。

## 核心特性

1. **简单的模板引擎**: 支持 `{{variable}}` 变量替换
2. **HTMX 集成**: 无缝集成 HTMX 属性
3. **HTML 渲染**: 专门的 `renderHtml()` 方法
4. **零 JavaScript**: 大部分交互无需编写 JS 代码

## 快速开始

### 1. 基础示例

```zig
const std = @import("std");
const zfinal = @import("zfinal");

fn indexHandler(ctx: *zfinal.Context) !void {
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>HTMX Demo</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\</head>
        \\<body>
        \\    <h1>Hello HTMX!</h1>
        \\    <button hx-get="/api/data" hx-target="#result">
        \\        Load Data
        \\    </button>
        \\    <div id="result"></div>
        \\</body>
        \\</html>
    ;
    
    try ctx.renderHtml(html);
}

fn dataHandler(ctx: *zfinal.Context) !void {
    try ctx.renderHtml("<p>Data loaded!</p>");
}

pub fn main() !void {
    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();
    
    try app.get("/", indexHandler);
    try app.get("/api/data", dataHandler);
    
    try app.start();
}
```

### 2. 运行 HTMX Demo

ZFinal 提供了一个完整的 HTMX 待办事项应用示例：

```bash
zig build run-htmx
```

访问 `http://localhost:8080` 查看效果。

## HTMX 常用属性

### hx-get / hx-post / hx-put / hx-delete

发送 HTTP 请求：

```html
<button hx-get="/api/users">Get Users</button>
<button hx-post="/api/users">Create User</button>
<button hx-put="/api/users/1">Update User</button>
<button hx-delete="/api/users/1">Delete User</button>
```

### hx-target

指定响应内容插入的目标元素：

```html
<button hx-get="/api/data" hx-target="#result">
    Load
</button>
<div id="result"></div>
```

### hx-swap

控制内容如何插入：

- `innerHTML`: 替换内部内容（默认）
- `outerHTML`: 替换整个元素
- `beforebegin`: 在元素前插入
- `afterbegin`: 在元素内部开头插入
- `beforeend`: 在元素内部末尾插入
- `afterend`: 在元素后插入

```html
<div id="list">
    <button hx-get="/api/item" hx-target="#list" hx-swap="beforeend">
        Add Item
    </button>
</div>
```

### hx-trigger

自定义触发事件：

```html
<!-- 点击时触发（默认） -->
<button hx-get="/api/data">Click Me</button>

<!-- 输入时触发 -->
<input hx-get="/api/search" hx-trigger="keyup" hx-target="#results">

<!-- 每2秒触发一次 -->
<div hx-get="/api/status" hx-trigger="every 2s"></div>
```

## 完整示例：待办事项应用

### 后端代码

```zig
const std = @import("std");
const zfinal = @import("zfinal");

const Todo = struct {
    id: i64,
    title: []const u8,
    completed: bool,
};

var todos = std.ArrayList(Todo).init(std.heap.page_allocator);
var next_id: i64 = 1;

// 首页
fn indexHandler(ctx: *zfinal.Context) !void {
    const html =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        body { font-family: sans-serif; max-width: 600px; margin: 50px auto; }
        \\        .todo { padding: 10px; margin: 5px 0; background: #f0f0f0; }
        \\        .completed { text-decoration: line-through; opacity: 0.6; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>📝 待办事项</h1>
        \\    <form hx-post="/api/todos" hx-target="#todo-list" hx-swap="beforeend">
        \\        <input type="text" name="title" placeholder="新待办..." required>
        \\        <button type="submit">添加</button>
        \\    </form>
        \\    <div id="todo-list"></div>
        \\    <script>
        \\        htmx.ajax('GET', '/api/todos', {target: '#todo-list'});
        \\    </script>
        \\</body>
        \\</html>
    ;
    try ctx.renderHtml(html);
}

// 获取所有待办
fn getTodosHandler(ctx: *zfinal.Context) !void {
    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();
    
    for (todos.items) |todo| {
        const class = if (todo.completed) " completed" else "";
        const checked = if (todo.completed) "checked" else "";
        
        try html.writer().print(
            \\<div class="todo{s}" id="todo-{d}">
            \\    <input type="checkbox" {s}
            \\           hx-post="/api/todos/{d}/toggle"
            \\           hx-target="#todo-{d}"
            \\           hx-swap="outerHTML">
            \\    {s}
            \\    <button hx-delete="/api/todos/{d}"
            \\            hx-target="#todo-{d}"
            \\            hx-swap="outerHTML">删除</button>
            \\</div>
        , .{ class, todo.id, checked, todo.id, todo.id, todo.title, todo.id, todo.id });
    }
    
    try ctx.renderHtml(html.items);
}

// 创建待办
fn createTodoHandler(ctx: *zfinal.Context) !void {
    const title = (try ctx.getPara("title")) orelse return;
    
    const todo = Todo{
        .id = next_id,
        .title = try ctx.allocator.dupe(u8, title),
        .completed = false,
    };
    next_id += 1;
    try todos.append(todo);
    
    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();
    
    try html.writer().print(
        \\<div class="todo" id="todo-{d}">
        \\    <input type="checkbox"
        \\           hx-post="/api/todos/{d}/toggle"
        \\           hx-target="#todo-{d}"
        \\           hx-swap="outerHTML">
        \\    {s}
        \\    <button hx-delete="/api/todos/{d}"
        \\            hx-target="#todo-{d}"
        \\            hx-swap="outerHTML">删除</button>
        \\</div>
    , .{ todo.id, todo.id, todo.id, todo.title, todo.id, todo.id });
    
    try ctx.renderHtml(html.items);
}

// 切换完成状态
fn toggleTodoHandler(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse return;
    const id = try std.fmt.parseInt(i64, id_str, 10);
    
    for (todos.items) |*todo| {
        if (todo.id == id) {
            todo.completed = !todo.completed;
            // 返回更新后的 HTML
            // ... (类似 createTodoHandler)
            return;
        }
    }
}

// 删除待办
fn deleteTodoHandler(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse return;
    const id = try std.fmt.parseInt(i64, id_str, 10);
    
    var i: usize = 0;
    while (i < todos.items.len) {
        if (todos.items[i].id == id) {
            _ = todos.orderedRemove(i);
            try ctx.renderHtml(""); // 返回空，HTMX 会移除元素
            return;
        }
        i += 1;
    }
}
```

## 模板引擎

ZFinal 提供了简单的模板引擎，支持变量替换：

```zig
const Template = @import("zfinal").Template;

var template = Template.init(allocator, "Hello, {{name}}! You are {{age}} years old.");

const data = .{
    .name = "Alice",
    .age = 25,
};

const result = try template.render(data);
defer allocator.free(result);
// 结果: "Hello, Alice! You are 25 years old."
```

### 模板管理器

对于大型项目，使用 `TemplateManager` 管理模板文件：

```zig
const TemplateManager = @import("zfinal").TemplateManager;

var manager = try TemplateManager.init(allocator, "templates");
defer manager.deinit();

// 加载模板
try manager.load("user.html");

// 渲染模板
const html = try manager.render("user.html", .{
    .username = "Alice",
    .email = "alice@example.com",
});
defer allocator.free(html);
```

## 最佳实践

1. **保持 HTML 片段小而专注**: 每个端点返回特定的 HTML 片段
2. **使用语义化的 ID**: 便于 HTMX 定位目标元素
3. **利用 hx-swap**: 选择合适的插入方式
4. **添加过渡效果**: 使用 CSS transitions 提升用户体验
5. **错误处理**: 返回适当的 HTTP 状态码和错误消息

## 与传统 SPA 对比

| 特性 | HTMX | React/Vue |
|------|------|-----------|
| JavaScript 代码量 | 极少 | 大量 |
| 学习曲线 | 平缓 | 陡峭 |
| 服务器负载 | 低 | 低 |
| SEO 友好 | 是 | 需要 SSR |
| 构建工具 | 不需要 | 需要 |
| 适用场景 | 中小型应用 | 大型复杂应用 |

## 参考资源

- [HTMX 官方文档](https://htmx.org/)
- [HTMX 示例](https://htmx.org/examples/)
- ZFinal HTMX Demo: `zig build run-htmx`
