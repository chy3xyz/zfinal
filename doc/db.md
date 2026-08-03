# ZFinal DB Layer

## Configuration

```zig
const zfinal = @import("zfinal");

// SQLite (file)
const config = zfinal.DBConfig.sqlite("data.db");

// SQLite (in-memory)
const config = zfinal.DBConfig.sqliteMemory();

// PostgreSQL
const config = zfinal.DBConfig.postgres("mydb", "user", "pass");

// MySQL
const config = zfinal.DBConfig.mysql("mydb", "user", "pass");

// Full config
const config = zfinal.DBConfig{
    .db_type = .postgres,
    .host = "db.example.com",
    .port = 5432,
    .database = "mydb",
    .username = "app",
    .password = "secret",
    .max_connections = 10,
};
```

## Connection

```zig
var db = try zfinal.DB.init(allocator, config);
defer db.deinit();

// Health check
if (!db.ping()) return error.DbDown;

// Raw exec (DDL, simple statements)
try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

// Parameterized exec (safe against SQL injection)
try db.execParams("INSERT INTO users (name, age) VALUES ($1, $2)", &.{
    zfinal.SqlParam{ .text = "Alice" },
    zfinal.SqlParam{ .int = 30 },
});

// Query with results
var result = try db.query("SELECT id, name, age FROM users");
defer result.deinit();
while (result.next()) {
    const row = result.currentRow().?;
    const name = row.getText(1); // column index
    const age = try row.getInt(2);
}

// Query with parameters
var result = try db.queryParams("SELECT * FROM users WHERE age > $1", &.{
    zfinal.SqlParam{ .int = 18 },
});
defer result.deinit();
```

## SqlParam Types

| Type | Constructor | Example |
|------|-----------|---------|
| int | `.{ .int = 42 }` | Integer values |
| real | `.{ .real = 3.14 }` | Floating point |
| text | `.{ .text = "hello" }` | Strings |
| blob | `.{ .blob = &.{0xDE, 0xAD} }` | Binary data |
| null | `.{ .null = {} }` | SQL NULL |

**Placeholder syntax**: PostgreSQL uses `$1, $2, ...`, SQLite and MySQL use `?`.

## Model (ORM)

```zig
const User = struct { id: i64, name: []const u8, age: i64 };
const UserModel = zfinal.Model(User, "users");

// Insert
var user = UserModel.Instance{
    .id = null, // auto-increment
    .data = .{ .id = 0, .name = "Bob", .age = 25 },
};
try user.insert(&db);

// Find by ID
const found = try UserModel.findById(&db, user.id.?, allocator);
defer if (found) |f| f.deinit(allocator);

// Find all
const all = try UserModel.findAll(&db, allocator);
defer { for (all) |*it| it.deinit(allocator); allocator.free(all); }

// Update
user.data.age = 26;
try user.update(&db, user.id.?);

// Delete
try UserModel.deleteById(&db, user.id.?);

// Paginate
const page = try UserModel.paginate(&db, 1, 20, allocator);

// Count
const total = try UserModel.count(&db);
```

### Custom Primary Key

```zig
const Customer = struct { customer_id: i64, company: []const u8 };
const CustomerModel = zfinal.ModelWithPK(Customer, "crm_customers", "customer_id");
```

## Connection Pool

```zig
var pool = zfinal.ConnectionPool.init(allocator, config, 8);
defer pool.deinit();

// Acquire connection
var conn = try pool.acquire();
defer pool.release(conn) catch {};

_ = try conn.exec("SELECT 1");

// Health check idle connections
pool.keepAlive();
```

## ResultSet

```zig
var result = try db.query("SELECT id, name FROM users");
defer result.deinit();

// Column metadata
const n_cols = result.columnCount();
const col_name = result.columnName(0);

// Iterate
while (result.next()) {
    const row = result.currentRow().?;
    const id = try row.getInt(0);
    const name = row.getText(1);
    const is_null = row.getText(2) == null;
}
```

## Transactions

```zig
try db.exec("BEGIN");
errdefer db.exec("ROLLBACK") catch {};
try db.execParams("INSERT INTO users (name) VALUES ($1)", &.{SqlParam{ .text = "Alice" }});
try db.execParams("INSERT INTO orders (user_id) VALUES ($1)", &.{SqlParam{ .int = 1 }});
try db.exec("COMMIT");
```

## Driver-specific Build Flags

```bash
zig build -Ddriver_pg=true           # Enable PostgreSQL (requires libpq)
zig build -Ddriver_mysql=true        # Enable MySQL (requires libmysqlclient)
zig build test -Ddriver_pg=true -Ddriver_mysql=true  # All DB integration tests
```

## Declarative List Query + DTO (ADR-017)

Lists no longer need hand-built WHERE strings and `SqlParam[]` arrays. Use
`Model.Query` (fluent, compile-time column validation), `Context.bindQuery`
(declarative DTO binding), and `Context.renderPage` (unified paged JSON):

```zig
const PostModel = zfinal.Model(Post, "posts");

const Filters = struct {
    status: ?[]const u8 = null,
    views_min: ?i64 = null,
    q: ?[]const u8 = null,
    sort: ?enum { asc, desc } = null,
};

pub fn list(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    var f: Filters = .{};
    try ctx.bindQuery(&f);                       // ← B: params → struct (400 on bad values)
    var q = PostModel.Query.init(db, ctx.allocator);
    defer q.deinit();
    try q.textEq("status", f.status);            // ← A: comptime-validated columns
    try q.gte("views", f.views_min);
    try q.likeAll(&.{ "title", "content" }, f.q);
    try q.orderBy("id", f.sort orelse .desc);
    const page = try ctx.getParaToLongDefault("page", 1);
    try ctx.renderPage(                         // ← C: {data,total,page,size} + frees items
        try q.paginate(@intCast(page), 20, ctx.allocator),
        ctx.allocator,
    );
}
```

- Column names in `eq/gt/.../orderBy` are validated against the model's table
  struct at **compile time** — typos and injection-shaped names fail to build.
- `bindQuery` supported field types: `?i64`, `?i32`, `?f64`, `?bool`,
  `?[]const u8`, optional enums. Missing params keep struct defaults.
- `renderPage` serializes and frees: per-item `deinit(allocator)` (when the item
  type has one) + `Page.deinit()`.

For write endpoints, `Context.bindJson(&dto)` is the JSON-body twin of
`bindQuery`: it parses the request body into a struct (unknown fields ignored),
responds 400 on malformed JSON, and its string fields are owned by a
request-scoped arena freed at `Context.deinit` — so the DTO stays valid for the
whole handler with no manual `deinit`:

```zig
var dto: service.Data = .{};
try ctx.bindJson(&dto);          // parse + 400 + ownership handled
const instance = service.create(db, dto);
```

Response shortcuts and lookups:

- `ctx.ok(data)` → `200 {"data": ...}`
- `ctx.created(id)` → `201 {"ok": true, "id": ...}`
- Generated `service.getOr404(db, id, allocator)` — returns the `Instance` or
  throws `error.NotFound`, which `http_error` maps to a `404` envelope; the
  generated `show`/`delete` handlers use it (and `delete` now `deinit`s the
  fetched instance).
