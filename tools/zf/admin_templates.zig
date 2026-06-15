//! vben-style admin HTML templates. All assets via CDN:
//!   - Tailwind CSS (Play CDN, JIT)
//!   - HTMX 1.9.10
//!   - Alpine.js 3.x
//!
//! Design tokens (vben-inspired):
//!   --primary:        #2b85e4   (vben blue)
//!   --sidebar-bg:     #001529   (vben dark sidebar)
//!   --sidebar-active: #2b85e4
//!   --content-bg:     #f0f2f5
//!   --text-sm:        14px
//!
//! Each template contains `// ── ai-edit-zone: ...` markers so an AI
//! agent can customize behavior without touching generated boilerplate.

const std = @import("std");
const codegen = @import("codegen");

/// Generate the 4 admin HTML files for a single table.
/// Returns owned slices the caller must free. List ends with a
/// null terminator (paired arrays).
pub const AdminFiles = struct {
    layout: []u8,
    list: []u8,
    form: []u8,
    row: []u8,

    pub fn deinit(self: AdminFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.layout);
        allocator.free(self.list);
        allocator.free(self.form);
        allocator.free(self.row);
    }
};

/// Render all admin files for one table. The caller must
/// deinit() the returned AdminFiles.
pub fn renderAll(allocator: std.mem.Allocator, table: *const codegen.Table) !AdminFiles {
    return .{
        .layout = try renderLayout(allocator, table),
        .list = try renderList(allocator, table),
        .form = try renderForm(allocator, table),
        .row = try renderRow(allocator, table),
    };
}

// ============================================================
// Shared CDN + design tokens (single source of truth)
// ============================================================
const SHARED_HEAD =
    \\<!DOCTYPE html>
    \\<html lang="zh-CN">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\<title>{title}</title>
    \\<script src="https://cdn.tailwindcss.com"></script>
    \\<script>
    \\  // vben-style design tokens, exposed to Tailwind via theme.extend
    \\  tailwind.config = {{
    \\    theme: {{
    \\      extend: {{
    \\        colors: {{
    \\          'vben-primary':   '#2b85e4',
    \\          'vben-primary-dk':'#1e6cb8',
    \\          'vben-sidebar':   '#001529',
    \\          'vben-sidebar-h': '#000c17',
    \\          'vben-content':   '#f0f2f5',
    \\        }},
    \\        fontFamily: {{
    \\          sans: ['-apple-system','BlinkMacSystemFont','"Segoe UI"','Roboto','"PingFang SC"','"Hiragino Sans GB"','"Microsoft YaHei"','sans-serif'],
    \\        }},
    \\      }},
    \\    }},
    \\  }};
    \\</script>
    \\<script src="https://unpkg.com/htmx.org@1.9.10"></script>
    \\<script defer src="https://cdn.jsdelivr.net/npm/alpinejs@3.13.3/dist/cdn.min.js"></script>
    \\<style>
    \\  body {{ font-size: 14px; }}
    \\  [x-cloak] {{ display: none !important; }}
    \\</style>
    \\</head>
;

// ============================================================
// Layout: topbar + sidebar shell
// ============================================================
fn renderLayout(allocator: std.mem.Allocator, table: *const codegen.Table) ![]u8 {
    const title = try std.fmt.allocPrint(allocator, "{s} 管理 - ZFinal Admin", .{table.pascal_name});
    defer allocator.free(title);

    return std.fmt.allocPrint(allocator,
        \\{s}
        \\<body class="bg-vben-content min-h-screen" x-data="{{ sidebarCollapsed: false, theme: 'light' }}">
        \\
        \\<!-- ── ai-edit-zone: topbar ──────────────────────────────────────── -->
        \\<!-- AI: customize topbar (logo, breadcrumbs, user menu, theme switch) -->
        \\<header class="h-14 bg-white shadow-sm flex items-center px-4 border-b border-gray-200 fixed top-0 left-0 right-0 z-30">
        \\  <button @click="sidebarCollapsed = !sidebarCollapsed" class="text-gray-600 hover:text-vben-primary mr-4">
        \\    <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        \\      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/>
        \\    </svg>
        \\  </button>
        \\  <h1 class="text-lg font-semibold text-gray-800">{s}</h1>
        \\  <div class="ml-auto flex items-center space-x-3">
        \\    <button class="text-gray-500 hover:text-vben-primary text-sm">⚙ 设置</button>
        \\    <div class="w-8 h-8 rounded-full bg-vben-primary text-white flex items-center justify-center text-sm">U</div>
        \\  </div>
        \\</header>
        \\<!-- ──────────────────────────────────────────────────────────────── -->
        \\
        \\<!-- ── ai-edit-zone: sidebar ──────────────────────────────────────── -->
        \\<!-- AI: replace static menu with route group / permission check -->
        \\<aside :class="sidebarCollapsed ? 'w-16' : 'w-56'" class="fixed left-0 top-14 bottom-0 bg-vben-sidebar text-gray-300 transition-all duration-200 z-20 overflow-y-auto">
        \\  <nav class="py-2">
        \\    <a href="/" class="flex items-center px-4 py-3 hover:bg-vben-sidebar-h transition-colors" :class="!sidebarCollapsed && 'border-l-2 border-vben-primary bg-vben-sidebar-h'">
        \\      <span class="text-base">🏠</span>
        \\      <span x-show="!sidebarCollapsed" x-cloak class="ml-3 text-sm">仪表盘</span>
        \\    </a>
        \\    <a href="/{s}" class="flex items-center px-4 py-3 hover:bg-vben-sidebar-h transition-colors">
        \\      <span class="text-base">📋</span>
        \\      <span x-show="!sidebarCollapsed" x-cloak class="ml-3 text-sm">{s}</span>
        \\    </a>
        \\    <a href="#" class="flex items-center px-4 py-3 hover:bg-vben-sidebar-h transition-colors">
        \\      <span class="text-base">📊</span>
        \\      <span x-show="!sidebarCollapsed" x-cloak class="ml-3 text-sm">报表</span>
        \\    </a>
        \\  </nav>
        \\</aside>
        \\<!-- ──────────────────────────────────────────────────────────────── -->
        \\
        \\<main :class="sidebarCollapsed ? 'ml-16' : 'ml-56'" class="pt-14 transition-all duration-200">
        \\  <div class="p-4">
        \\    {s}
        \\  </div>
        \\</main>
        \\</body>
        \\</html>
    , .{
        SHARED_HEAD, // 1: head
        title, // 2: page title
        table.name, // 3: href in sidebar
        table.pascal_name, // 4: sidebar label
        table.name, // 5: content slot
    });
}

// ============================================================
// List page: search bar + table + pagination + add button
// ============================================================
fn renderList(allocator: std.mem.Allocator, table: *const codegen.Table) ![]u8 {
    var headers: std.ArrayList(u8) = .empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, "      <th class=\"px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider\">ID</th>\n");
    for (table.columns.items) |col| {
        if (col.is_primary_key) continue;
        const h = try std.fmt.allocPrint(allocator, "      <th class=\"px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider\">{s}</th>\n", .{col.name});
        try headers.appendSlice(allocator, h);
        allocator.free(h);
    }
    try headers.appendSlice(allocator, "      <th class=\"px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider\">操作</th>\n");

    return std.fmt.allocPrint(allocator,
        \\<!-- {s} 列表页 -->
        \\<div class="bg-white rounded shadow-sm p-4">
        \\
        \\<!-- ── ai-edit-zone: list filters ──────────────────────────────────── -->
        \\<!-- AI: customize search bar (debounce, autocomplete, date range, status filter) -->
        \\<div class="flex flex-wrap items-center gap-2 mb-4" x-data="{{ q: '' }}">
        \\  <input type="text" x-model="q" placeholder="搜索 {s}…"
        \\         @input.debounce.300ms="$el.dispatchEvent(new CustomEvent('search'))"
        \\         class="flex-1 min-w-[200px] px-3 py-2 border border-gray-300 rounded text-sm focus:outline-none focus:border-vben-primary">
        \\  <button hx-get="/{s}/list?q=''" hx-target="#rows" hx-swap="innerHTML"
        \\          @search="$el.setAttribute('hx-get', `/{s}/list?q=${{encodeURIComponent(q)}}`); htmx.process($el); $el.click()"
        \\          class="px-4 py-2 bg-vben-primary text-white rounded text-sm hover:bg-vben-primary-dk">
        \\    🔍 搜索
        \\  </button>
        \\  <button hx-get="/{s}/form/new" hx-target="#modal-content" hx-swap="innerHTML"
        \\          @click="window.dispatchEvent(new CustomEvent('open-modal'))"
        \\          class="ml-auto px-4 py-2 bg-vben-primary text-white rounded text-sm hover:bg-vben-primary-dk">
        \\    + 新增 {s}
        \\  </button>
        \\</div>
        \\<!-- ────────────────────────────────────────────────────────────────── -->
        \\
        \\<div class="overflow-x-auto border border-gray-200 rounded">
        \\  <table class="min-w-full divide-y divide-gray-200">
        \\    <thead class="bg-gray-50">
        \\<tr>
        \\{s}
        \\</tr>
        \\    </thead>
        \\    <tbody id="rows" class="bg-white divide-y divide-gray-200"
        \\           hx-get="/{s}/list" hx-trigger="load delay:100ms" hx-swap="innerHTML">
        \\      <tr><td colspan="100" class="text-center text-gray-400 py-8">加载中…</td></tr>
        \\    </tbody>
        \\  </table>
        \\</div>
        \\
        \\<!-- Pagination (server-side rendered by handler) -->
        \\<div id="pagination" class="mt-4 flex items-center justify-between text-sm text-gray-600"
        \\     hx-get="/{s}/pagination" hx-trigger="refresh from:body" hx-swap="innerHTML">
        \\  <span>共 0 条</span>
        \\  <div class="flex space-x-1">
        \\    <button class="px-3 py-1 border border-gray-300 rounded hover:bg-gray-50">‹</button>
        \\    <button class="px-3 py-1 border border-vben-primary bg-vben-primary text-white rounded">1</button>
        \\    <button class="px-3 py-1 border border-gray-300 rounded hover:bg-gray-50">›</button>
        \\  </div>
        \\</div>
        \\</div>
        \\
        \\<!-- Modal container (filled by HTMX when /form/new is requested) -->
        \\<div x-data="{{ open: false }}" @open-modal.window="open = true" x-show="open" x-cloak
        \\     class="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
        \\     @keydown.escape.window="open = false">
        \\  <div @click.outside="open = false" class="bg-white rounded shadow-lg w-full max-w-2xl max-h-[90vh] overflow-y-auto">
        \\    <div id="modal-content">
        \\      <div class="p-8 text-center text-gray-400">加载表单…</div>
        \\    </div>
        \\  </div>
        \\</div>
    , .{
        table.pascal_name, // 1: title
        table.pascal_name, // 2: search placeholder
        table.name, // 3: hx-get list
        table.name, // 4: hx-get list (in @search handler)
        table.pascal_name, // 5: add button
        headers.items, // 6: <th> cells
        table.name, // 7: tbody hx-get
        table.name, // 8: pagination hx-get
        table.name, // 9: pagination hx-get
    });
}

// ============================================================
// Form fragment (loaded into modal)
// ============================================================
fn renderForm(allocator: std.mem.Allocator, table: *const codegen.Table) ![]u8 {
    var form_fields: std.ArrayList(u8) = .empty;
    defer form_fields.deinit(allocator);

    for (table.columns.items) |col| {
        if (col.is_primary_key and col.is_auto_increment) continue; // skip autoinc PK
        const input_html = try inputHtmlForColumn(allocator, col);
        defer allocator.free(input_html);
        try form_fields.appendSlice(allocator, input_html);
    }

    return std.fmt.allocPrint(allocator,
        \\<form hx-post="/{s}" hx-target="#rows" hx-swap="innerHTML"
        \\      hx-on::after-request="if(event.detail.successful) window.dispatchEvent(new CustomEvent('open-modal'))"
        \\      class="p-6">
        \\  <div class="flex items-center justify-between mb-4 pb-2 border-b border-gray-200">
        \\    <h2 class="text-lg font-semibold text-gray-800">新增 {s}</h2>
        \\    <button type="button" @click="open = false" class="text-gray-400 hover:text-gray-600">✕</button>
        \\  </div>
        \\
        \\  <!-- ── ai-edit-zone: form fields ──────────────────────────────── -->
        \\  <!-- AI: customize the form layout (sections, validation hints, dependencies) -->
        \\<div class="space-y-4">
        \\{s}
        \\</div>
        \\  <!-- ──────────────────────────────────────────────────────────────── -->
        \\
        \\  <div class="mt-6 flex justify-end space-x-2 pt-4 border-t border-gray-200">
        \\    <button type="button" @click="open = false"
        \\            class="px-4 py-2 border border-gray-300 text-gray-700 rounded text-sm hover:bg-gray-50">
        \\      取消
        \\    </button>
        \\    <button type="submit"
        \\            class="px-4 py-2 bg-vben-primary text-white rounded text-sm hover:bg-vben-primary-dk">
        \\      保存
        \\    </button>
        \\  </div>
        \\</form>
    , .{ table.name, table.pascal_name, form_fields.items });
}

// ============================================================
// Row fragment (HTMX for inline update / delete)
// ============================================================
fn renderRow(allocator: std.mem.Allocator, table: *const codegen.Table) ![]u8 {
    var cells: std.ArrayList(u8) = .empty;
    defer cells.deinit(allocator);
    for (table.columns.items) |col| {
        if (col.is_primary_key) continue;
        const cell = try std.fmt.allocPrint(allocator, "      <td class=\"px-4 py-2 text-sm text-gray-700\">{{{{item.{s}}}}}</td>\n", .{col.name});
        try cells.appendSlice(allocator, cell);
        allocator.free(cell);
    }

    // Handlebars row template. Zig format only supports `{{` as
    // escape (no `}}` escape), so we emit a placeholder token and
    // replace it with the literal closing braces after formatting.
    const raw = try std.fmt.allocPrint(allocator,
        \\<!-- BEGIN:row -->
        \\<tr id="row-HBOPENitem.idHBCLOSE" class="hover:bg-gray-50">
        \\  <td class="px-4 py-2 text-sm text-gray-900">HBOPENitem.idHBCLOSE</td>
        \\{s}  <td class="px-4 py-2 text-sm space-x-2 whitespace-nowrap">
        \\    <button hx-get="/{s}/form/HBOPENitem.idHBCLOSE" hx-target="#modal-content" hx-swap="innerHTML"
        \\            @click="window.dispatchEvent(new CustomEvent('open-modal'))"
        \\            class="text-vben-primary hover:underline">编辑</button>
        \\    <button hx-delete="/{s}/HBOPENitem.idHBCLOSE" hx-target="#row-HBOPENitem.idHBCLOSE" hx-swap="outerHTML"
        \\            hx-confirm="确认删除?此操作不可撤销。"
        \\            class="text-red-600 hover:underline">删除</button>
        \\  </td>
        \\</tr>
        \\<!-- END:row -->
    , .{ cells.items, table.name, table.name });
    defer allocator.free(raw);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (i + 6 <= raw.len and std.mem.eql(u8, raw[i..][0..6], "HBOPEN")) {
            try out.appendSlice(allocator, "{{");
            i += 6;
        } else if (i + 6 <= raw.len and std.mem.eql(u8, raw[i..][0..6], "HBCLOSE")) {
            try out.appendSlice(allocator, "}}");
            i += 6;
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ============================================================
// Map SQL type → HTML input element
// ============================================================
fn inputHtmlForColumn(allocator: std.mem.Allocator, col: codegen.Column) ![]u8 {
    // Cheap uppercase copy
    var sql_upper_buf: [32]u8 = undefined;
    const sql_upper = blk: {
        const n = @min(col.sql_type.len, sql_upper_buf.len);
        for (0..n) |i| sql_upper_buf[i] = std.ascii.toUpper(col.sql_type[i]);
        break :blk sql_upper_buf[0..n];
    };

    const InputKind = struct { input_type: []const u8, kind: []const u8 };

    const input_kind: InputKind = blk: {
        if (std.mem.eql(u8, sql_upper, "INTEGER") or std.mem.eql(u8, sql_upper, "INT"))
            break :blk InputKind{ .input_type = "number", .kind = "number" };
        if (std.mem.eql(u8, sql_upper, "REAL") or std.mem.eql(u8, sql_upper, "FLOAT") or std.mem.eql(u8, sql_upper, "DOUBLE"))
            break :blk InputKind{ .input_type = "number", .kind = "number-step" };
        if (std.mem.eql(u8, sql_upper, "BOOLEAN") or std.mem.eql(u8, sql_upper, "BOOL"))
            break :blk InputKind{ .input_type = "checkbox", .kind = "checkbox" };
        if (std.mem.eql(u8, sql_upper, "DATE"))
            break :blk InputKind{ .input_type = "date", .kind = "date" };
        if (std.mem.eql(u8, sql_upper, "DATETIME") or std.mem.eql(u8, sql_upper, "TIMESTAMP"))
            break :blk InputKind{ .input_type = "datetime-local", .kind = "datetime" };
        if (col.max_length orelse 0 > 200)
            break :blk InputKind{ .input_type = "textarea", .kind = "textarea" };
        break :blk InputKind{ .input_type = "text", .kind = "text" };
    };
    const required: []const u8 = if (col.is_nullable) "" else " required";
    const required_star: []const u8 = if (col.is_nullable) "" else " <span class=\"text-red-500\">*</span>";

    if (std.mem.eql(u8, input_kind.kind, "checkbox")) {
        return std.fmt.allocPrint(allocator,
            \\    <div>
            \\      <label class="block text-sm font-medium text-gray-700 mb-1">{s}{s}</label>
            \\      <input type="checkbox" name="{s}" value="true"
            \\             class="w-4 h-4 text-vben-primary border-gray-300 rounded focus:ring-vben-primary">
            \\    </div>
        , .{ col.name, required_star, col.name });
    }
    if (std.mem.eql(u8, input_kind.kind, "textarea")) {
        return std.fmt.allocPrint(allocator,
            \\    <div>
            \\      <label class="block text-sm font-medium text-gray-700 mb-1">{s}{s}</label>
            \\      <textarea name="{s}" rows="4"{s}
            \\                class="w-full px-3 py-2 border border-gray-300 rounded text-sm focus:outline-none focus:border-vben-primary"
            \\                placeholder="输入 {s}…"></textarea>
            \\    </div>
        , .{ col.name, required_star, col.name, required, col.name });
    }
    return std.fmt.allocPrint(allocator,
        \\    <div>
        \\      <label class="block text-sm font-medium text-gray-700 mb-1">{s}{s}</label>
        \\      <input type="{s}" name="{s}"{s}
        \\             class="w-full px-3 py-2 border border-gray-300 rounded text-sm focus:outline-none focus:border-vben-primary"
        \\             placeholder="输入 {s}…">
        \\    </div>
    , .{ col.name, required_star, input_kind.input_type, col.name, required, col.name });
}

// ============================================================
// Tests
// ============================================================

test "admin_templates: layout has vben sidebar and ai-edit-zone" {
    const allocator = std.testing.allocator;
    const tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const layout = try renderLayout(allocator, table);
    defer allocator.free(layout);

    try std.testing.expect(std.mem.indexOf(u8, layout, "bg-vben-sidebar") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "#001529") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "ai-edit-zone: topbar") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout, "ai-edit-zone: sidebar") != null);
}

test "admin_templates: list has search, table, pagination, modal" {
    const allocator = std.testing.allocator;
    const tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const list = try renderList(allocator, table);
    defer allocator.free(list);

    try std.testing.expect(std.mem.indexOf(u8, list, "hx-get=\"/posts/list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "ai-edit-zone: list filters") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "+ 新增") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "分页") != null);
}

test "admin_templates: form has all fields, save button, ai-edit-zone" {
    const allocator = std.testing.allocator;
    const tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, sku TEXT, name TEXT NOT NULL, count INT, active BOOLEAN);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const form = try renderForm(allocator, table);
    defer allocator.free(form);

    try std.testing.expect(std.mem.indexOf(u8, form, "ai-edit-zone: form fields") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "name=\"sku\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "type=\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "type=\"checkbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form, "保存") != null);
}

test "admin_templates: row has edit + delete actions" {
    const allocator = std.testing.allocator;
    const tables = try codegen.parseSqlFile(allocator,
        \\CREATE TABLE todos (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);
    );
    defer {
        for (tables.items) |*t| t.deinit();
        tables.deinit(allocator);
    }
    const table = tables.items[0];

    const row = try renderRow(allocator, table);
    defer allocator.free(row);

    try std.testing.expect(std.mem.indexOf(u8, row, "hx-delete") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "hx-get") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "编辑") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "删除") != null);
}

test "admin_templates: inputHtmlForColumn maps SQL types correctly" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { sql: []const u8, expected: []const u8 }{
        .{ .sql = "INTEGER", .expected = "type=\"number\"" },
        .{ .sql = "REAL", .expected = "type=\"number\"" },
        .{ .sql = "BOOLEAN", .expected = "type=\"checkbox\"" },
        .{ .sql = "DATE", .expected = "type=\"date\"" },
        .{ .sql = "DATETIME", .expected = "type=\"datetime-local\"" },
        .{ .sql = "TEXT", .expected = "type=\"text\"" },
    };
    for (cases) |c| {
        const col = codegen.Column{
            .name = "x",
            .sql_type = c.sql,
            .is_nullable = true,
            .is_primary_key = false,
            .is_auto_increment = false,
            .default_value = null,
            .max_length = 10,
        };
        const html = try inputHtmlForColumn(allocator, col);
        defer allocator.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, c.expected) != null);
    }
}
