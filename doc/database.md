# 数据库与 ORM

ZFinal 内置了轻量级的 Active Record 模式 ORM，支持 SQLite, MySQL, PostgreSQL。

## 1. 配置数据库

在 `src/config/config.zig` 中配置：

```zig
pub const DBConfig = struct {
    pub fn get() zfinal.DBConfig {
        // SQLite
        return zfinal.DBConfig.sqlite("app.db");
        
        // MySQL
        // return zfinal.DBConfig.mysql("db_name", "user", "password");
        
        // PostgreSQL
        // return zfinal.DBConfig.postgres("db_name", "user", "password");
    }
};
```

## 2. 定义模型

在 `src/model/` 下定义模型：

```zig
const zfinal = @import("zfinal");

pub const User = struct {
    id: ?i64 = null,
    username: []const u8,
    email: []const u8,
    age: i32,
};

// 定义 UserModel，关联 "users" 表
pub const UserModel = zfinal.Model(User, "users");
```

## 3. CRUD 操作

```zig
// 初始化 DB
var db = try zfinal.DB.init(allocator, config);
defer db.deinit();

// --- 创建 (Create) ---
var user = UserModel.Instance{
    .data = User{
        .username = "Alice",
        .email = "alice@example.com",
        .age = 25
    }
};
try user.save(&db);

// --- 查询 (Read) ---
// 根据 ID 查询
const u = try UserModel.findById(&db, 1, allocator);

// 查询所有
const all = try UserModel.findAll(&db, allocator);

// 条件查询
const adults = try UserModel.findWhere(&db, "age >= 18", allocator);

// 分页查询
const page = try UserModel.paginate(&db, 1, 10, allocator);

// --- 更新 (Update) ---
user.data.age = 26;
try user.save(&db); // 自动识别为更新，因为 id 不为 null

// --- 删除 (Delete) ---
try user.delete(&db);
// 或者
try UserModel.deleteById(&db, 1);
```

## 4. 事务处理

```zig
try db.begin();
{
    errdefer db.rollback();
    
    try user1.save(&db);
    try user2.save(&db);
    
    try db.commit();
}
```

## 5. SQL 模板

SQL 模板允许你将复杂的 SQL 语句提取出来，使用 `{param}` 占位符进行参数化。

### 5.1 基础用法

```zig
const zfinal = @import("zfinal");

var engine = zfinal.SqlTemplate.init(allocator);

// 定义模板，使用 {参数名} 占位符
const template = "SELECT * FROM users WHERE age > {age} AND city = '{city}'";

// 渲染模板
const sql = try engine.render(template, .{
    .age = 18,
    .city = "Beijing"
});
defer allocator.free(sql);

// 生成的 SQL: SELECT * FROM users WHERE age > 18 AND city = 'Beijing'
const result = try db.query(sql);
```

### 5.2 使用 SqlTemplateManager 管理模板

对于大型项目，建议使用 `SqlTemplateManager` 集中管理 SQL 模板。

```zig
// 初始化管理器
var manager = zfinal.SqlTemplateManager.init(allocator);
defer manager.deinit();

// 注册模板
try manager.add("find_user_by_id", 
    "SELECT * FROM users WHERE id = {id}");
try manager.add("find_users_by_age", 
    "SELECT * FROM users WHERE age >= {min_age} AND age <= {max_age}");
try manager.add("update_user_email", 
    "UPDATE users SET email = '{email}' WHERE id = {id}");

// 使用模板
const sql1 = try manager.render("find_user_by_id", .{ .id = 100 });
defer allocator.free(sql1);

const sql2 = try manager.render("find_users_by_age", .{ 
    .min_age = 18, 
    .max_age = 65 
});
defer allocator.free(sql2);
```

### 5.3 支持的类型

SQL 模板支持以下 Zig 类型：

- **整数**: `i32`, `i64`, `u32`, `u64` 等
- **浮点数**: `f32`, `f64`
- **布尔值**: `bool` (渲染为 `true` / `false`)
- **字符串**: `[]const u8`

### 5.4 注意事项

1. **SQL 注入防护**: 模板系统会自动转义基本类型，但对于字符串类型，建议在业务层做好验证。
2. **引号处理**: 字符串需要在模板中手动添加引号，如 `'{city}'`，数字类型则不需要。
3. **性能考虑**: 模板渲染会产生内存分配，建议在性能敏感的场景中缓存渲染结果。
