const std = @import("std");
const zfinal = @import("zfinal");
const Template = @import("../../src/template/template.zig").Template;
const TemplateManager = @import("../../src/template/template.zig").TemplateManager;

/// 简单的 Todo 模型
const Todo = struct {
    id: i64,
    title: []const u8,
    completed: bool,
};

var todos = std.ArrayList(Todo).init(std.heap.page_allocator);
var next_id: i64 = 1;

/// 首页
fn indexHandler(ctx: *zfinal.Context) !void {
    const html =
        \\<!DOCTYPE html>
        \\<html lang="zh-CN">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>ZFinal + HTMX Demo</title>
        \\    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
        \\    <style>
        \\        * { margin: 0; padding: 0; box-sizing: border-box; }
        \\        body {
        \\            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        \\            min-height: 100vh;
        \\            padding: 20px;
        \\        }
        \\        .container {
        \\            max-width: 800px;
        \\            margin: 0 auto;
        \\            background: white;
        \\            border-radius: 20px;
        \\            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        \\            padding: 40px;
        \\        }
        \\        h1 {
        \\            color: #667eea;
        \\            margin-bottom: 30px;
        \\            text-align: center;
        \\        }
        \\        .card {
        \\            background: #f8f9fa;
        \\            border-radius: 12px;
        \\            padding: 20px;
        \\            margin-bottom: 15px;
        \\            border: 1px solid #e9ecef;
        \\        }
        \\        input[type="text"] {
        \\            width: 70%;
        \\            padding: 12px;
        \\            border: 2px solid #e9ecef;
        \\            border-radius: 8px;
        \\            font-size: 1rem;
        \\        }
        \\        .btn {
        \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        \\            color: white;
        \\            border: none;
        \\            padding: 12px 24px;
        \\            border-radius: 8px;
        \\            cursor: pointer;
        \\            font-size: 1rem;
        \\            margin-left: 10px;
        \\        }
        \\        .btn:hover { transform: translateY(-2px); }
        \\        .btn-delete {
        \\            background: #dc3545;
        \\            padding: 8px 16px;
        \\            font-size: 0.9rem;
        \\        }
        \\        .todo-item {
        \\            display: flex;
        \\            justify-content: space-between;
        \\            align-items: center;
        \\        }
        \\        .completed { text-decoration: line-through; opacity: 0.6; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>📝 ZFinal + HTMX 待办事项</h1>
        \\        <div class="card">
        \\            <form hx-post="/api/todos" hx-target="#todo-list" hx-swap="beforeend">
        \\                <input type="text" name="title" placeholder="输入待办事项..." required>
        \\                <button type="submit" class="btn">添加</button>
        \\            </form>
        \\        </div>
        \\        <div id="todo-list"></div>
        \\    </div>
        \\    <script>
        \\        htmx.ajax('GET', '/api/todos', {target: '#todo-list', swap: 'innerHTML'});
        \\    </script>
        \\</body>
        \\</html>
    ;

    try ctx.renderHtml(html);
}

/// 获取所有 todos
fn getTodosHandler(ctx: *zfinal.Context) !void {
    var html = std.ArrayList(u8).init(ctx.allocator);
    defer html.deinit();

    for (todos.items) |todo| {
        const completed_class = if (todo.completed) " completed" else "";
        const checked = if (todo.completed) "checked" else "";

        try html.writer().print(
            \\<div class="card todo-item" id="todo-{d}">
            \\    <div>
            \\        <input type="checkbox" {s}
            \\               hx-post="/api/todos/{d}/toggle"
            \\               hx-target="#todo-{d}"
            \\               hx-swap="outerHTML">
            \\        <span class="{s}">{s}</span>
            \\    </div>
            \\    <button class="btn btn-delete"
            \\            hx-delete="/api/todos/{d}"
            \\            hx-target="#todo-{d}"
            \\            hx-swap="outerHTML swap:0.5s">
            \\        删除
            \\    </button>
            \\</div>
            \\
        , .{ todo.id, checked, todo.id, todo.id, completed_class, todo.title, todo.id, todo.id });
    }

    try ctx.renderHtml(html.items);
}

/// 创建 todo
fn createTodoHandler(ctx: *zfinal.Context) !void {
    const title = (try ctx.getPara("title")) orelse {
        ctx.res_status = .bad_request;
        try ctx.renderText("Missing title");
        return;
    };

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
        \\<div class="card todo-item" id="todo-{d}">
        \\    <div>
        \\        <input type="checkbox"
        \\               hx-post="/api/todos/{d}/toggle"
        \\               hx-target="#todo-{d}"
        \\               hx-swap="outerHTML">
        \\        <span>{s}</span>
        \\    </div>
        \\    <button class="btn btn-delete"
        \\            hx-delete="/api/todos/{d}"
        \\            hx-target="#todo-{d}"
        \\            hx-swap="outerHTML swap:0.5s">
        \\        删除
        \\    </button>
        \\</div>
        \\
    , .{ todo.id, todo.id, todo.id, todo.title, todo.id, todo.id });

    try ctx.renderHtml(html.items);
}

/// 切换 todo 状态
fn toggleTodoHandler(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderText("Missing ID");
        return;
    };

    const id = try std.fmt.parseInt(i64, id_str, 10);

    for (todos.items) |*todo| {
        if (todo.id == id) {
            todo.completed = !todo.completed;

            const completed_class = if (todo.completed) " completed" else "";
            const checked = if (todo.completed) "checked" else "";

            var html = std.ArrayList(u8).init(ctx.allocator);
            defer html.deinit();

            try html.writer().print(
                \\<div class="card todo-item" id="todo-{d}">
                \\    <div>
                \\        <input type="checkbox" {s}
                \\               hx-post="/api/todos/{d}/toggle"
                \\               hx-target="#todo-{d}"
                \\               hx-swap="outerHTML">
                \\        <span class="{s}">{s}</span>
                \\    </div>
                \\    <button class="btn btn-delete"
                \\            hx-delete="/api/todos/{d}"
                \\            hx-target="#todo-{d}"
                \\            hx-swap="outerHTML swap:0.5s">
                \\        删除
                \\    </button>
                \\</div>
                \\
            , .{ todo.id, checked, todo.id, todo.id, completed_class, todo.title, todo.id, todo.id });

            try ctx.renderHtml(html.items);
            return;
        }
    }

    ctx.res_status = .not_found;
    try ctx.renderText("Todo not found");
}

/// 删除 todo
fn deleteTodoHandler(ctx: *zfinal.Context) !void {
    const id_str = ctx.getPathParam("id") orelse {
        ctx.res_status = .bad_request;
        try ctx.renderText("Missing ID");
        return;
    };

    const id = try std.fmt.parseInt(i64, id_str, 10);

    var i: usize = 0;
    while (i < todos.items.len) {
        if (todos.items[i].id == id) {
            _ = todos.orderedRemove(i);
            try ctx.renderHtml("");
            return;
        }
        i += 1;
    }

    ctx.res_status = .not_found;
    try ctx.renderText("Todo not found");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = zfinal.ZFinal.init(allocator);
    defer app.deinit();

    app.setPort(8080);

    // 路由
    try app.get("/", indexHandler);
    try app.get("/api/todos", getTodosHandler);
    try app.post("/api/todos", createTodoHandler);
    try app.post("/api/todos/:id/toggle", toggleTodoHandler);
    try app.delete("/api/todos/:id", deleteTodoHandler);

    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  🚀 HTMX Demo Started!\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Server: http://localhost:8080\n", .{});
    std.debug.print("\n", .{});

    try app.start();
}
