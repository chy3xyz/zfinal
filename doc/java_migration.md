# Java → ZFinal Migration Guide

## Step 1: Extract SQL Schema

From Java project root:

```bash
# Spring Boot + JPA/Hibernate
find . -name "*.sql" -not -path "*/target/*" | sort

# MySQL dump (if using MySQL)
mysqldump --no-data -u root -p dbname > schema.sql

# PostgreSQL dump
pg_dump --schema-only dbname > schema.sql

# SQLite
sqlite3 app.db .schema > schema.sql
```

If no SQL files exist, extract from `@Entity` classes:

```bash
# Find all entities
grep -rn "@Entity\|@Table" src/ --include="*.java"

# Example output:
# src/main/java/com/example/model/User.java:@Entity
# src/main/java/com/example/model/Order.java:@Entity
```

From entities, manually write schema.sql:

```sql
CREATE TABLE users (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'USER',
    active BOOLEAN DEFAULT TRUE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE orders (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    total DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'PENDING',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

## Step 2: Generate ZFinal Code

```bash
# Create ZFinal project
zf new myapp
cd myapp

# Generate all CRUD from schema
zf crud:sql /path/to/schema.sql

# Output:
# ✅ Generated model: src/model/users.zig
# ✅ Generated controller: src/controller/users_controller.zig
# ✅ Generated model: src/model/orders.zig
# ✅ Generated controller: src/controller/orders_controller.zig
# ✅ Generated test: test/users_test.zig
# ✅ Generated test: test/orders_test.zig
# ✅ Generated migration package: zfinal_migration.zig
```

## Step 3: Map Java Patterns → ZFinal

### Controller

```java
// Java (Spring Boot)
@RestController
@RequestMapping("/api/users")
public class UserController {

    @Autowired
    private UserService userService;

    @GetMapping
    public ResponseEntity<List<User>> list() {
        return ResponseEntity.ok(userService.findAll());
    }

    @PostMapping
    public ResponseEntity<User> create(@Valid @RequestBody UserDto dto) {
        User user = userService.create(dto);
        return ResponseEntity.status(201).body(user);
    }
}
```

```zig
// ZFinal (generated + AI-enhanced)
// src/controller/users_controller.zig
pub fn list(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};
    const items = try UserModel.findAll(db, ctx.allocator);
    defer ctx.allocator.free(items);
    try ctx.renderJson(.{ .data = items });
}

pub fn create(ctx: *zfinal.Context) !void {
    // AI adds: validation, password hashing, audit log
    const db = try pool.acquire();
    defer pool.release(db) catch {};

    const name = (try ctx.getPara("username")) orelse return error.ValidationError;
    const email = (try ctx.getPara("email")) orelse return error.ValidationError;
    const password = (try ctx.getPara("password")) orelse return error.ValidationError;

    // Hash password (AI adds bcrypt)
    var hash_buf: [64]u8 = undefined;
    const hash = try hashPassword(&hash_buf, password);

    var user = UserModel.Instance{
        .data = .{ .username = name, .email = email, .password_hash = hash },
    };
    try user.save(&db);
    try ctx.renderJson(.{ .ok = true, .data = user.data });
}
```

### Service Layer

```java
// Java (Spring)
@Service
@Transactional
public class OrderService {
    public Order createOrder(Long userId, List<OrderItem> items) {
        User user = userRepo.findById(userId).orElseThrow();
        Order order = new Order(user, items);
        return orderRepo.save(order);
    }
}
```

```zig
// ZFinal — inline in handler or separate file
fn createOrder(db: *zfinal.DB, user_id: i64, items: []OrderItem) !Order {
    // Validate user exists
    const user = try UserModel.findById(db, user_id, allocator) orelse
        return error.UserNotFound;

    // Calculate total
    var total: f64 = 0;
    for (items) |item| total += item.price * @as(f64, @floatFromInt(item.quantity));

    var order = OrderModel.Instance{
        .data = .{ .user_id = user_id, .total = total, .status = "PENDING" },
    };
    try order.save(db);
    return order.data;
}
```

### Auth / Interceptor

```java
// Java (Spring Security)
@Component
public class JwtAuthFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res,
                                     FilterChain chain) {
        String token = req.getHeader("Authorization");
        if (token == null || !jwtProvider.validate(token)) {
            res.sendError(401, "Unauthorized");
            return;
        }
        SecurityContextHolder.setAuthentication(jwtProvider.getAuth(token));
        chain.doFilter(req, res);
    }
}
```

```zig
// ZFinal interceptor — prefer return HttpError (dispatch maps to JSON)
fn jwtBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization");
    if (token == null or !std.mem.startsWith(u8, token.?, "Bearer ")) return error.Unauthorized;
    const jwt = token.?[7..];
    if (!validateJwt(jwt)) return error.Unauthorized;
    try ctx.setAttr("user_id", extractUserId(jwt));
    return true;
}

pub const JwtInterceptor = zfinal.Interceptor{
    .name = "jwt",
    .before = jwtBefore,
};
```

## Step 4: Pattern Translation Table

| Java/Spring | ZFinal |
|-------------|--------|
| `@RestController` + `@GetMapping` | `try app.get("/path", Controller.list)` |
| `@PostMapping` + `@RequestBody` | `try app.post("/path", Controller.create)` + `ctx.getPara()` |
| `@PathVariable Long id` | `ctx.getPathParam("id")` |
| `@RequestParam String name` | `ctx.getPara("name")` |
| `@Service` + `@Transactional` | `fn doWork(db: *DB) !void` + `db.begin()/commit()` |
| `@Entity` + `JpaRepository` | `zfinal.Model(T, "table_name")` |
| `repository.findById(id)` | `Model.findById(db, id, allocator)` |
| `repository.findAll()` | `Model.findAll(db, allocator)` |
| `repository.save(entity)` | `instance.save(&db)` |
| `repository.delete(entity)` | `instance.delete(&db)` |
| `@Autowired` | Config struct / module-level init |
| `application.properties` | `config.zig` with `DBConfig.postgres(...)` |
| `@Valid` + Bean Validation | `Validator.validateRequired/Email/Range` |
| `@ExceptionHandler` | `Interceptor.after` or handler catch |
| `ResponseEntity<T>` | `ctx.renderJson(.{...})` + `ctx.res_status` |
| `Page<T>` + `Pageable` | `Model.paginate(db, page, size, allocator)` |

## Step 5: AI Enhancement Checklist

After `zf crud:sql`, AI adds to each file:

### Model
- [ ] Business validation rules (email format, min/max length)
- [ ] Custom queries (`findByEmail`, `findByStatus`)
- [ ] Computed fields

### Controller
- [ ] CSRF token on create/update/delete
- [ ] Auth checks (JWT/session/cookie)
- [ ] Rate limiting
- [ ] Input sanitization
- [ ] Audit logging
- [ ] Response filtering (hide password_hash, internal fields)

### Routes
- [ ] Nest under prefix (`/api/v1`)
- [ ] Apply interceptors to protected routes
- [ ] Version API

### Tests
- [ ] Happy path: create → read → update → delete
- [ ] Auth: 401 without token, 403 with wrong role
- [ ] Validation: 400 on invalid input
- [ ] Not found: 404 on missing resource

## Step 6: Verify Migration

```bash
# Run generated tests
zig build test

# Compare API responses
# Old (Java):  curl http://old-server:8080/api/users
# New (ZFinal): curl http://localhost:8080/api/users
# → Both should return same JSON structure

# Performance comparison
# wrk -t4 -c100 -d30s http://old-server:8080/api/users
# wrk -t4 -c100 -d30s http://localhost:8080/api/users
```

## Common Migration Issues

| Issue | Fix |
|-------|-----|
| MySQL `TINYINT(1)` → Zig `bool` | Add to codegen type mapper |
| Composite primary keys | Currently not supported — normalize to single PK |
| `@ManyToMany` join tables | Generate separate model for join table |
| Stored procedures | Rewrite as Zig functions calling `db.execParams` |
| `@Lob` / large text | Use `[]const u8` (SQLite TEXT handles up to 1GB) |
| `@Enumerated` | Use `[]const u8` with Zig enum validation |
| `@Version` optimistic locking | Add `version: i64` field, check in update |
