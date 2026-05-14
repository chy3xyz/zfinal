# AI Prompt: Migrate Java Backend → ZFinal (Zig)

Copy-paste this entire block to your AI. Attach your Java source files after the prompt.

---

```
## Task: Migrate the attached Java backend to ZFinal (Zig web framework).

You are migrating REAL Java code to Zig. Do NOT invent features. Preserve exact behavior.
Follow the ZFinal workflow strictly — use `zf` CLI tools, never hand-code from scratch.

## ⚠️ CRITICAL RULES (read first)

1. **Use zf tools ONLY.** Never write model/handler/service by hand.
   - `zf new <name>` → scaffolds project
   - `zf crud:sql <file>` → generates .gen.zig from SQL schema
   - `zf g handler|model|middleware|service|task <Name>` → extension stubs

2. **gen+ext two-file pattern.** Generated code lives in `.gen.zig`, your code in `ext/`:
   - `model.gen.zig` — struct + Model (overwritten on regeneration, NEVER edit)
   - `service.gen.zig` — CRUD delegation (overwritten)
   - `handler.gen.zig` — list/show/create/update/delete (overwritten)
   - `ext/model.zig` — `import "../model.gen.zig"` + custom queries ← EDIT HERE
   - `ext/service.zig` — business logic, transactions, cross-model ops ← EDIT HERE
   - `ext/handler.zig` — custom endpoints, complex param parsing ← EDIT HERE

3. **Three-layer call chain:** handler → service → model. Handler never touches model directly.

4. **Run `zf check` after every change** to verify AI compliance.

## Migration Steps (execute in order)

### Step 1: Extract SQL Schema

From the attached Java code:
- Find `@Entity`, `@Table`, `CREATE TABLE` statements, or schema files
- Write a single `schema.sql` with all CREATE TABLE statements
- Preserve exact table names, column names, types, defaults, constraints
- Map Java types: `Long`→BIGINT, `String`→VARCHAR/TEXT, `BigDecimal`→DECIMAL,
  `Boolean`→BOOLEAN, `LocalDateTime`→DATETIME, `Integer`→INTEGER

### Step 2: Generate Framework Code

```bash
zf new <project-name>
zf crud:sql schema.sql
```

This creates:
```
src/modules/<sub>/<name>/
├── model.gen.zig       # DO NOT EDIT
├── service.gen.zig     # DO NOT EDIT
├── handler.gen.zig     # DO NOT EDIT
├── routes.zig
└── ext/                # ← you write here
```

### Step 3: Map Java Patterns → ZFinal

For EACH Java class attached, apply the mapping below. Write the business logic
into the corresponding `ext/*.zig` file.

#### Controller → ext/handler.zig

Java:
```java
@RestController
@RequestMapping("/api/v1/users")
public class UserController {
    @GetMapping
    public ResponseEntity<List<UserDto>> list(@RequestParam int page, @RequestParam int size) {
        var users = userService.findAll(page, size);
        return ResponseEntity.ok(Map.of("data", users, "total", users.size()));
    }
}
```

→ ext/handler.zig:
```zig
pub fn customList(ctx: *zfinal.Context) !void {
    // handler.gen.zig already has list(). Override or add custom endpoints here.
}
```

Register in routes.zig:
```zig
try app.get("/api/v1/users", handler.user.customList);
```

#### Service → ext/service.zig

Java:
```java
@Service @Transactional
public class OrderService {
    public Order createOrder(CreateOrderRequest req) {
        // validation + business logic + save
    }
}
```

→ ext/service.zig:
```zig
pub fn createOrder(db: *zfinal.DB, req: CreateOrderData) !Order {
    // service.gen.zig already has create(). Add custom logic here.
    // Use db.begin() / db.commit() / db.rollback() for transactions
}
```

#### Entity/Model → ext/model.zig

Java:
```java
@Entity @Table(name = "users")
public class User {
    @Id @GeneratedValue private Long id;
    @Column private String email;
}
```

→ ext/model.zig (model.gen.zig already has struct + Model):
```zig
// Add custom queries
pub fn findByEmail(db: *zfinal.DB, email: []const u8, a: std.mem.Allocator) !?User {
    return UserModel.findFirst(db, "email = ?", .{email}, a);
}
```

#### Repository → Model methods (already in model.gen.zig)

Java: `userRepository.findById(id)` → ZFinal: `UserModel.findById(db, id, allocator)`
Java: `userRepository.findAll()` → ZFinal: `UserModel.findAll(db, allocator)`
Java: `userRepository.save(user)` → ZFinal: `instance.save(&db)`
Java: `userRepository.delete(user)` → ZFinal: `instance.delete(&db)`

#### Auth/Interceptor → middleware/

Java:
```java
@Component
public class JwtAuthFilter extends OncePerRequestFilter {
    protected void doFilterInternal(req, res, chain) {
        String token = req.getHeader("Authorization");
        if (token == null) { res.sendError(401); return; }
        // validate + set context
        chain.doFilter(req, res);
    }
}
```

→ middleware/auth.zig:
```zig
fn jwtBefore(ctx: *zfinal.Context) !bool {
    const token = ctx.getHeader("Authorization") orelse {
        ctx.res_status = .unauthorized;
        try ctx.renderJson(.{ .err = "Missing token" });
        return false; // stops the chain
    };
    // validate token, set ctx.attr("userId", ...)
    return true; // continue to handler
}

pub const jwt = zfinal.Interceptor{ .name = "jwt", .before = jwtBefore };
```

#### Validation

Java: `@NotBlank @Size(min=3) @Email` → `zfinal.Validator.validateRequired/validateEmail/validateRange`

#### Exception Handler

Java: `@ExceptionHandler` → `Interceptor.after` or handler catch with `ctx.res_status`

### Step 4: Verify

```bash
zf check                           # AI compliance audit
zig build                          # must compile
zig build test                     # unit + integration tests pass
```

## Pattern Translation Table (quick reference)

| Java/Spring | ZFinal |
|-------------|--------|
| `@RestController` + `@GetMapping` | `app.get("/path", handler.list)` in routes.zig |
| `@PostMapping` + `@RequestBody` | `app.post("/path", handler.create)` + `ctx.getPara("field")` |
| `@PathVariable Long id` | `ctx.getPathParam("id")` |
| `@RequestParam String name` | `ctx.getPara("name")` |
| `@Service` + `@Transactional` | `fn doWork(db: *DB) !void` + `db.begin()/commit()` |
| `@Entity` + `@Table` | `pub const X = struct{...}; pub const XModel = zfinal.Model(X, "table")` |
| `JpaRepository.findById()` | `Model.findById(db, id, allocator)` |
| `JpaRepository.findAll()` | `Model.findAll(db, allocator)` |
| `JpaRepository.save()` | `instance.save(&db)` |
| `repository.delete()` | `instance.delete(&db)` |
| `Page<T>` + `Pageable` | `Model.paginate(db, page, size, allocator)` |
| `@Autowired` / `@Inject` | Config struct / module-level init |
| `application.properties` | `config.zig` with `ServerConfig` / `DBConfig` |
| `@Valid` + Bean Validation | `Validator.validateRequired/Email/Range` |
| `ResponseEntity<T>` | `ctx.renderJson(.{...})` + `ctx.res_status` |
| `OncePerRequestFilter` | `Interceptor { .before = fn }` in middleware/ |
| `@Scheduled` | `CronPlugin` or task/ |
| `@ExceptionHandler` | `Interceptor.after` or catch in handler |

## Common Pitfalls (avoid these)

1. ❌ Writing `pub const User = struct {...}` by hand — MODEL.GEN.ZIG ALREADY HAS IT
2. ❌ Calling `UserModel.findById` from handler — go through service layer
3. ❌ Editing `.gen.zig` files — they WILL be overwritten
4. ❌ Creating files outside ext/ — put custom code in ext/
5. ❌ Skip `zf check` — run it every time before committing
6. ❌ Forgetting `defer instance.deinit(allocator)` — memory leak
7. ❌ Using `std.heap.page_allocator` for request-scoped data — use ctx.allocator

## What to Output

For EACH Java file attached, show:
1. The schema.sql fragment (if it's an Entity)
2. The ext/*.zig file with business logic
3. The routes.zig registration line
4. Any middleware needed

Start with Step 1: extract SQL schema from the attached Java code.
```
