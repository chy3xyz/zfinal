# Admin Template — vben-style B 端后台生成器

ZFinal 自带的 vben 风格管理后台生成器。一个命令同时生成 Zig
业务代码（model/service/handler/routes）和 vben 风格 HTML
界面（admin/admin_form/admin_row/admin_layout），全套资源走
CDN（Tailwind + HTMX + Alpine.js），零本地构建。

## 5 秒上手

```bash
# 1. 写 schema
cat > schema.sql << 'EOF'
CREATE TABLE products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sku TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    price REAL NOT NULL,
    active BOOLEAN DEFAULT 1,
    description TEXT
);
EOF

# 2. 一条命令生成一切
zf crud:sql schema.sql --admin

# 3. 跑
zig build run

# 4. 打开
# http://localhost:8080/products
```

## 单独生成 admin HTML

```bash
# 只想要后台，不想要 Zig 后端？
zf admin schema.sql --out public/
```

这会在 `public/` 下输出：

```
public/
├── admin_layout.html        顶栏 + 侧栏 + 内容区骨架
├── products/
│   ├── admin.html           列表页：搜索 + 表格 + 分页 + Modal
│   ├── admin_form.html      新增 / 编辑表单片段（HTMX 加载到 Modal）
│   └── admin_row.html       单行片段（HTMX 用于原地更新/删除）
```

## 设计语言：vben 风格

```
┌────────────────────────────────────────────────────────┐
│ Topbar: 折叠按钮 + 标题 + 设置 + 用户头像 (Alpine)    │
├──────────┬─────────────────────────────────────────────┤
│ Sidebar  │ Content area                                 │
│  🏠 仪表盘│  ┌─────────────────────────────────────┐   │
│  📋 Products│  │ [搜索] [搜索] [+ 新增]              │  │
│  📊 报表   │  ├─────────────────────────────────────┤   │
│          │  │ ID | SKU | 名称 | 价格 | ...  | 操作  │  │
│          │  │  1 | ... | ...  | ...  | ...  | 编辑删除│  │
│          │  ├─────────────────────────────────────┤   │
│          │  │ 共 N 条  ‹ 1 2 3 ›                     │  │
│          │  └─────────────────────────────────────┘   │
│          │                                              │
│          │  + Modal 表单（HTMX 加载 / Alpine 切换）    │
└──────────┴─────────────────────────────────────────────┘
```

设计 token：

```js
// tailwind.config
colors: {
  'vben-primary':    '#2b85e4',  // vben 标志蓝
  'vben-primary-dk': '#1e6cb8',
  'vben-sidebar':    '#001529',  // 深侧栏
  'vben-sidebar-h':  '#000c17',
  'vben-content':    '#f0f2f5',
}
```

## 字段类型 → HTML input 映射

| SQL 类型 | HTML input | manifest `ui.input` |
|----------|-----------|---------------------|
| INTEGER / INT | `<input type="number">` | `"number"` |
| REAL / FLOAT / DOUBLE | `<input type="number">` | `"number"` |
| BOOLEAN / BOOL | `<input type="checkbox">` | `"checkbox"` |
| DATE | `<input type="date">` | `"date"` |
| DATETIME / TIMESTAMP | `<input type="datetime-local">` | `"datetime-local"` |
| TEXT | `<input type="text">` | `"text"` |

AI 可以在 manifest 的 `ui` 块里改 label / 验证 / 必填等。

## AI edit zones

每个生成的 HTML 都带 `// ── ai-edit-zone: ...` 标记，AI 在
标记内自由改：

| 标记 | AI 改什么 |
|------|---------|
| `ai-edit-zone: topbar` | logo、面包屑、用户菜单、主题切换 |
| `ai-edit-zone: sidebar` | 路由组、权限校验 |
| `ai-edit-zone: list filters` | 搜索栏 debounce、autocomplete、日期范围、状态过滤 |
| `ai-edit-zone: row actions` | 内联编辑、批量删除、导出按钮 |
| `ai-edit-zone: form fields` | 表单布局、验证提示、字段联动 |

## Manifest 形态

```json
{
  "tables": [
    {
      "name": "products",
      "pascal_name": "Products",
      "files": {
        "model": "products/model.zig",
        "service": "products/service.zig",
        "handler": "products/handler.zig",
        "routes": "products/routes.zig"
      },
      "fields": [
        {
          "name": "id",
          "sql_type": "INTEGER",
          "nullable": true,
          "primary_key": true,
          "ui": { "input": "number", "label_zh": "id", "required": false }
        },
        {
          "name": "name",
          "sql_type": "TEXT",
          "nullable": false,
          "primary_key": false,
          "ui": { "input": "text", "label_zh": "name", "required": true }
        },
        {
          "name": "active",
          "sql_type": "BOOLEAN",
          "nullable": true,
          "primary_key": false,
          "ui": { "input": "checkbox", "label_zh": "active", "required": false }
        }
      ]
    }
  ]
}
```

## 完整命令参考

```bash
# 单独生成 admin HTML（不生成 Zig）
zf admin schema.sql --out public/

# 完整：Zig + admin + manifest
zf crud:sql schema.sql --admin --json

# 显式跳过 admin
zf crud:sql schema.sql --no-admin  # not implemented yet; default is on
```

## 跑示例

```bash
# 跑已经生成的 demo
zig build run-htmx-admin

# 访问
# http://localhost:8080/admin
```

## 自定义样式

模板用 Tailwind Play CDN + JIT 编译，运行时生成 CSS。
要在生产环境本地化：

1. 把 `https://cdn.tailwindcss.com` 换成自己的 Tailwind 编译产物
2. 调整 `tailwind.config` 里的 design tokens
3. 把 HTMX / Alpine.js 也下载到本地

AI 改：admin.html 顶部的 `<script src="...">` 标签，指定本地路径。

## 已知限制

- Tailwind Play CDN 体积大、首次加载慢。生产建议本地化。
- vben 默认深色侧栏 + 浅色内容区。改用浅色侧栏在 tailwind.config 里把 `vben-sidebar` 改成浅色色值。
- 表单提交走 HTMX POST，handler 需返回 `HX-Redirect` 头或 inline 替换 `#rows`。看 `src/modules/products/handler.zig` 的 `create` 方法。

## 与 v0.9.0 之后的关系

v0.9.5 之前只能 `zf admin` 单独跑；v0.9.6 起 `zf crud:sql` 集成 `--admin` flag，
AI 一次命令拿到 Zig + HTML + manifest 完整三件套。
