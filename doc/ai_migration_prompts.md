# AI 迁移提示词手册 — Java → ZFinal

面向 AI 编程助手（Claude Code / Cursor / Copilot / Codex）的 Java 后端迁移提示词集合。可直接复制使用。

## 提示词使用原则

1. **具体 > 抽象**：给 AI 真实的代码片段，而不是描述"有个 Controller"
2. **分步迁移**：一次迁移一个模块（一个 Controller + Service + Model），不要一次全给
3. **先 Schema 后逻辑**：AI 最强的部分是结构翻译（SQL→Model），先给它 Schema 再给业务逻辑
4. **给约束**：告诉 AI "不要改业务行为"、"保持原有 JSON 字段名"
5. **验证闭环**：每步给 AI 测试验证指令，出错可回溯

---

## 一、快速起手式

### 1.0 选型：SQL 还是 zent？

| 领域 | 用 |
|------|-----|
| 平 CRUD / 存量 SQL | `zf crud:sql`（下节 1.1） |
| 电商 / 社交 / 密图 / privacy | **`zf crud:zent`**（下节 1.0b） |

### 1.0b zent 主力（AI 友好）

```
基于以下领域描述，用 ZFinal + zent 生成模块（不要用手写 Schema 样板）：

1. 先写出 schema.zent（module / entity / fields / list_by）
2. 运行：zf crud:zent schema.zent --json
3. 只在 ai-edit-zone 内补校验与鉴权
4. 按命令打印的 bootstrap 接入 main.zig（migrateSchema + Store）
5. 禁止混用 zfinal.DB 与 zent 同一事务
6. 验证：zf check && zig build test

领域：
[粘贴电商/社交需求，或直接给 schema.zent / schema.json]
```

参考：`doc/zent.md`、`examples/zent-shop/`、`.claude/skills/zfinal-zent-ai.md`。

### 1.1 仅凭 SQL Schema 生成全栈 CRUD

```
基于以下 SQL schema，用 ZFinal 框架生成完整 CRUD：

- 生成 Model（继承 zfinal.Model）
- 生成 Controller（list/get/create/update/delete）
- 生成路由注册代码
- 生成集成测试
- 所有 JSON 响应使用 snake_case 字段名
- POST/PUT/DELETE 端点添加 CSRF 保护
- 添加输入校验（必填字段、email 格式、长度限制）

```sql
[粘贴你的 CREATE TABLE 语句]
```
```

### 1.2 从已有 Java 项目提取 Schema

```
读取以下 Java 实体类，提取对应的 SQL CREATE TABLE 语句，
然后基于提取的 schema 生成 ZFinal CRUD 代码：

[Java 代码]
```java
@Entity
@Table(name = "products")
public class Product {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, length = 200)
    private String name;

    @Column(columnDefinition = "TEXT")
    private String description;

    @Column(nullable = false)
    private BigDecimal price;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id")
    private Category category;

    @Column(name = "created_at")
    private LocalDateTime createdAt;
}
```
```

### 1.3 凭 cURL 响应逆向生成

```
以下是旧 Java API 的 JSON 响应格式。生成对应的 ZFinal Model 和 Controller：

GET /api/users/42 返回：
```json
{
  "id": 42,
  "username": "alice",
  "email": "alice@example.com",
  "role": "admin",
  "active": true,
  "created_at": "2025-01-15T08:30:00Z"
}
```

POST /api/users 请求体：
```json
{
  "username": "bob",
  "email": "bob@example.com",
  "password": "secret123",
  "role": "user"
}
```

要求：
- 响应字段名保持 snake_case
- password 字段不在任何 GET 响应中返回
- 不要包含 password_hash 在 JSON 输出中
```

---

## 二、逐层迁移提示词

### 2.1 Controller 层迁移

```
将以下 Spring Boot Controller 迁移为 ZFinal handler 函数：

[Java 代码]
```java
@RestController
@RequestMapping("/api/v1/orders")
public class OrderController {

    @Autowired
    private OrderService orderService;

    @GetMapping
    public ResponseEntity<Page<OrderDto>> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) String status) {

        Page<Order> orders = orderService.findByStatus(status, PageRequest.of(page - 1, size));
        List<OrderDto> dtos = orders.map(OrderDto::from).getContent();
        return ResponseEntity.ok(Map.of(
            "data", dtos,
            "total", orders.getTotalElements(),
            "page", page,
            "size", size
        ));
    }

    @PostMapping
    public ResponseEntity<?> create(@Valid @RequestBody CreateOrderRequest req) {
        Order order = orderService.createOrder(req);
        return ResponseEntity.status(201).body(Map.of("data", OrderDto.from(order)));
    }

    @GetMapping("/{id}")
    public ResponseEntity<?> getById(@PathVariable Long id) {
        return orderService.findById(id)
            .map(o -> ResponseEntity.ok(Map.of("data", OrderDto.from(o))))
            .orElse(ResponseEntity.status(404).body(Map.of("error", "Not found")));
    }
}
```

要求：
- 保持相同的 URL 路径 /api/v1/orders
- 保持相同的请求参数名和 JSON 响应结构
- 分页逻辑使用 zfinal.Model.paginate
- 404 返回 {"error": "Not found"}
- 添加 CSRF token 校验
```

### 2.2 Service 层迁移

```
将以下 Spring Service 迁移为 Zig 函数：

[Java]
```java
@Service
@Transactional
public class OrderService {

    private final OrderRepository orderRepo;
    private final UserRepository userRepo;
    private final InventoryService inventoryService;

    public Order createOrder(CreateOrderRequest req) {
        // 1. 校验用户
        User user = userRepo.findById(req.getUserId())
            .orElseThrow(() -> new NotFoundException("User not found"));

        // 2. 校验库存
        for (OrderItem item : req.getItems()) {
            if (!inventoryService.hasStock(item.getProductId(), item.getQuantity())) {
                throw new BusinessException("Insufficient stock for product " + item.getProductId());
            }
        }

        // 3. 计算总价
        BigDecimal total = req.getItems().stream()
            .map(i -> i.getPrice().multiply(BigDecimal.valueOf(i.getQuantity())))
            .reduce(BigDecimal.ZERO, BigDecimal::add);

        // 4. 创建订单
        Order order = new Order();
        order.setUserId(req.getUserId());
        order.setTotal(total);
        order.setStatus(OrderStatus.PENDING);
        orderRepo.save(order);

        // 5. 扣减库存
        for (OrderItem item : req.getItems()) {
            inventoryService.deduct(item.getProductId(), item.getQuantity());
        }

        return order;
    }
}
```

要求：
- 使用显式事务（db.begin() / db.commit() / db.rollback()）
- 每个校验失败返回明确的错误类型
- 保持相同的业务步骤顺序
- 错误处理使用 Zig 的 error union
```

### 2.3 Auth / 拦截器迁移

```
将以下 Spring Security 过滤器链迁移为 ZFinal Interceptor：

[Java]
```java
// JWT 认证
public class JwtAuthFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res,
                                     FilterChain chain) {
        String header = req.getHeader("Authorization");
        if (header == null || !header.startsWith("Bearer ")) {
            res.sendError(401, "Missing token");
            return;
        }
        String token = header.substring(7);
        try {
            Claims claims = jwtParser.parseClaimsJws(token).getBody();
            req.setAttribute("userId", claims.get("userId", Long.class));
            req.setAttribute("role", claims.get("role", String.class));
            chain.doFilter(req, res);
        } catch (JwtException e) {
            res.sendError(401, "Invalid token");
        }
    }
}

// 角色校验
@PreAuthorize("hasRole('ADMIN')")
@DeleteMapping("/{id}")
public ResponseEntity<?> delete(@PathVariable Long id) { ... }
```

要求：
- JWT 使用 HMAC-SHA256，密钥从环境变量 JWT_SECRET 读取
- 拦截器将 user_id 和 role 存入 ctx.attr
- @PreAuthorize 转为独立的 RoleInterceptor，检查 ctx.attr("role")
- 未认证返回 401，无权限返回 403
```

### 2.4 校验逻辑迁移

```
将以下 Bean Validation 注解转换为 ZFinal Validator 调用：

[Java]
```java
public class CreateUserRequest {
    @NotBlank(message = "用户名不能为空")
    @Size(min = 3, max = 50, message = "用户名长度 3-50")
    private String username;

    @NotBlank
    @Email(message = "邮箱格式不正确")
    private String email;

    @NotBlank
    @Size(min = 8, message = "密码至少 8 位")
    @Pattern(regexp = "^(?=.*[A-Z])(?=.*[0-9]).+$",
             message = "密码需包含大写字母和数字")
    private String password;

    @Min(value = 18, message = "年龄至少 18 岁")
    @Max(value = 120)
    private int age;
}
```

要求：
- 校验失败返回 400 + JSON {"errors": {"字段名": "错误信息"}}
- 使用 zfinal.Validator 的 validateRequired / validateEmail / validateRange / validateRegex
- 收集所有校验错误，一次性返回
```

---

## 三、全栈迁移主提示词

### 完整项目迁移（分 3 轮对话）

**第 1 轮：Schema + Model**

```
我要把一个 Java Spring Boot 项目迁移到 Zig + ZFinal 框架。

## 项目信息
- 数据库：PostgreSQL 14
- ORM：Hibernate / JPA
- 认证：JWT (HMAC-SHA256)
- 缓存：Redis（可先跳过）

## 第一步任务
1. 从以下实体类列表中提取完整 SQL Schema
2. 为每个表生成 ZFinal Model
3. 生成对应的集成测试（SQLite 内存库）

实体类列表：
[粘贴所有 @Entity 类的路径和代码]

要求：
- 保持原表名和字段名
- TIMESTAMP → i64 (unix 毫秒)
- DECIMAL → f64
- TINYINT(1) → bool
- JSON 序列化使用 snake_case
```

**第 2 轮：Controller + Route**

```
## 第二步任务（接上一轮）

基于上一轮生成的 Model，为以下 Controller 生成 ZFinal handler：

[粘贴 Controller 代码]

要求：
- URL 路径保持与 Java @RequestMapping 一致
- 响应 JSON 结构与旧 API 完全一致
- 添加 CSRF 保护（TokenManager）
- 添加输入校验（Validator）
- 添加请求日志（Logger）
- 分页参数使用 page/size（1-based）
```

**第 3 轮：Interceptor + Security**

```
## 第三步任务（接上一轮）

迁移安全层和横切关注点：

1. JWT 认证拦截器（从 Authorization: Bearer xxx 提取并验证）
2. 角色权限拦截器（admin/user 角色检查）
3. CORS 配置（允许 origin: *）
4. 限流（每 IP 60 次/分钟）
5. 全局异常处理（统一 JSON 错误格式）

## 已有的 Java 代码
[粘贴 SecurityConfig / Filter / ExceptionHandler 代码]

要求：
- 未认证返回 {"error": "Unauthorized", "code": 401}
- 无权限返回 {"error": "Forbidden", "code": 403}
- 限流超限返回 {"error": "Too Many Requests", "code": 429}
- 服务端异常返回 {"error": "Internal Server Error", "code": 500}
```

---

## 四、特定场景提示词

### 文件上传

```
将以下 Spring 文件上传 Controller 迁移到 ZFinal：

[Java]
```java
@PostMapping("/upload")
public ResponseEntity<?> upload(@RequestParam("file") MultipartFile file) {
    if (file.isEmpty()) return ResponseEntity.badRequest().body("File is empty");
    if (file.getSize() > 10 * 1024 * 1024) return ResponseEntity.badRequest().body("File too large");

    String originalName = file.getOriginalFilename();
    String ext = originalName.substring(originalName.lastIndexOf("."));
    String newName = UUID.randomUUID() + ext;

    Path uploadPath = Path.of("/data/uploads", newName);
    Files.createDirectories(uploadPath.getParent());
    file.transferTo(uploadPath);

    return ResponseEntity.ok(Map.of("url", "/uploads/" + newName));
}
```

要求：
- 使用 zfinal.UploadFile / MultipartParser
- 限制文件大小 10MB
- 只允许 jpg/png/pdf
- 生成随机文件名防止覆盖
- 不保留原始文件名（安全）
```

### WebSocket 迁移

```
将以下 Spring WebSocket handler 迁移到 ZFinal：

[Java]
```java
@Component
public class ChatWebSocketHandler extends TextWebSocketHandler {
    private final Set<WebSocketSession> sessions = ConcurrentHashMap.newKeySet();

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        sessions.add(session);
        broadcast("User joined: " + session.getId());
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) {
        broadcast(message.getPayload());
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        sessions.remove(session);
        broadcast("User left: " + session.getId());
    }

    private void broadcast(String msg) {
        for (WebSocketSession s : sessions) {
            if (s.isOpen()) s.sendMessage(new TextMessage(msg));
        }
    }
}
```

要求：
- 使用 zfinal.WebSocket / WebSocketManager
- 保持广播语义
- 处理断线清理
- 添加心跳 ping/pong
```

### 定时任务迁移

```
将以下 Spring @Scheduled 迁移到 ZFinal CronPlugin：

[Java]
```java
@Component
public class ScheduledTasks {

    @Scheduled(fixedRate = 300000) // 5 minutes
    public void cleanExpiredSessions() {
        sessionRepo.deleteByExpiryBefore(Instant.now());
        log.info("Cleaned expired sessions");
    }

    @Scheduled(cron = "0 0 2 * * ?") // 2 AM daily
    public void generateDailyReport() {
        var orders = orderRepo.findByDate(LocalDate.now().minusDays(1));
        var report = reportGenerator.generate(orders);
        emailService.send("admin@example.com", "Daily Report", report);
    }
}
```

要求：
- 使用 zfinal.CronPlugin
- cleanExpiredSessions 每 5 分钟执行
- generateDailyReport 每天凌晨 2:00 执行
- 添加执行日志
```

---

## 五、提示词调优技巧

### 让 AI 输出更好的代码

```
1. 给样本数据 — AI 需要真实的输入/输出来推断类型
   ❌ "迁移 UserController"
   ✅ "迁移 UserController，这是它的 GET 响应：{...}"

2. 标注陷阱 — 提前告诉 AI 哪些地方容易出错
   ✅ "这个 API 的 page 参数是 0-based，ZFinal 默认 1-based，注意转换"
   ✅ "password 字段存的是 bcrypt hash，不是明文，保持这个行为"

3. 给约束而非建议
   ❌ "可以考虑加限流"
   ✅ "必须添加限流：60 req/min per IP，超限返回 429"

4. 要求解释 — 复杂逻辑让 AI 在代码注释中解释
   ✅ "在复杂业务逻辑处添加注释，解释 WHY 而非 WHAT"

5. 增量验证 — 每步都要可测试
   ✅ "生成代码后，同时生成一个 curl 命令+预期输出来验证"
```

### 常见翻车点及预防

```
| 场景 | 预防提示词 |
|------|-----------|
| AI 改了字段名 | "保持原有 JSON 字段名，不要自作主张改为驼峰/蛇形" |
| AI 漏了参数校验 | "每个端点都必须校验必填参数，参考 Java 代码中的 @Valid 注解" |
| AI 生成的 SQL 不安全 | "所有 SQL 使用参数化查询，禁止拼接用户输入" |
| AI 过度设计 | "保持与 Java 版本相同的抽象层次，不要增加多余的中间层" |
| AI 忘记错误处理 | "每个可能失败的操作都要处理错误，参考 Java 代码中的 try-catch" |
| AI 使用了不存在的 API | "只使用 zfinal 标准库中的 API，不要引入额外依赖" |
```

---

## 六、迁移后验证提示词

```
## 验证迁移结果

对迁移后的 ZFinal 代码执行以下检查：

1. 逐一对比 Java API 和 Zig API 的 cURL 测试：
   ```bash
   # Java 版本
   curl -s http://old:8080/api/users/1 | jq .
   # Zig 版本
   curl -s http://new:8080/api/users/1 | jq .
   # 用 diff 对比两个 JSON 结构（值可以不同，结构必须一致）
   ```

2. 检查以下安全项：
   - [ ] 所有 POST/PUT/DELETE 有 CSRF 保护
   - [ ] 密码哈希不在任何响应中返回
   - [ ] SQL 使用参数化查询（搜索 "fmt" 拼接 SQL 的模式）
   - [ ] 输入校验覆盖所有必填字段
   - [ ] 错误响应不泄漏堆栈信息

3. 性能基准测试：
   ```bash
   wrk -t4 -c100 -d30s http://localhost:8080/api/users
   ```

4. 报告发现的任何差异和问题。
```

---

## 附录：完整示例

### 输入：Spring Boot Controller（真实代码量）

```java
@RestController
@RequestMapping("/api/v1/products")
@RequiredArgsConstructor
public class ProductController {
    private final ProductService service;

    @GetMapping
    public ResponseEntity<Map<String, Object>> list(
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size,
            @RequestParam(required = false) Long categoryId) {
        var result = service.list(page, size, categoryId);
        return ResponseEntity.ok(Map.of(
            "data", result.getContent(),
            "total", result.getTotalElements(),
            "page", page,
            "size", size));
    }

    @GetMapping("/{id}")
    public ResponseEntity<?> get(@PathVariable Long id) {
        return service.findById(id)
                .map(p -> ResponseEntity.ok(Map.of("data", p)))
                .orElseGet(() -> ResponseEntity.status(404)
                        .body(Map.of("error", "Product not found")));
    }

    @PostMapping
    @PreAuthorize("hasRole('ADMIN')")
    public ResponseEntity<?> create(@Valid @RequestBody CreateProductRequest body) {
        var product = service.create(body);
        return ResponseEntity.status(201).body(Map.of("data", product));
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN')")
    public ResponseEntity<?> update(@PathVariable Long id,
                                     @Valid @RequestBody UpdateProductRequest body) {
        return service.update(id, body)
                .map(p -> ResponseEntity.ok(Map.of("data", p)))
                .orElseGet(() -> ResponseEntity.status(404)
                        .body(Map.of("error", "Product not found")));
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasRole('ADMIN')")
    public ResponseEntity<?> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.ok(Map.of("ok", true));
    }
}
```

### 对应的迁移提示词

```
将以上 ProductController 迁移为 ZFinal handler 函数。

要求：
1. URL 路径保持 /api/v1/products
2. JSON 响应结构与 Java 版本完全一致（snake_case 字段名）
3. page 参数为 1-based，与 Java 版本相同
4. @PreAuthorize → 检查 ctx.attr("role") == "admin"
5. 使用 zfinal.TokenManager 添加 CSRF 保护
6. 输入校验用 zfinal.Validator
7. 生成对应的集成测试（使用 SQLite 内存库）
8. 数据库操作使用 zfinal.Model + ConnectionPool
```

### AI 期望输出

```zig
const std = @import("std");
const zfinal = @import("zfinal");

const ProductModel = @import("../model/products.zig").ProductModel;
const pool = @import("../deps.zig").pool;

pub fn list(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};

    const page_str = ctx.getPara("page") orelse "1";
    const size_str = ctx.getPara("size") orelse "20";
    const page = std.fmt.parseInt(u32, page_str, 10) catch 1;
    const size = std.fmt.parseInt(u32, size_str, 10) catch 20;

    const page_result = try ProductModel.paginate(db, page, size, ctx.allocator);
    try ctx.renderJson(.{
        .data = page_result.items,
        .total = page_result.total,
        .page = page,
        .size = size,
    });
}

pub fn get(ctx: *zfinal.Context) !void {
    const db = try pool.acquire();
    defer pool.release(db) catch {};

    const id_str = ctx.getPathParam("id") orelse return error.BadRequest;
    const id = std.fmt.parseInt(i64, id_str, 10) catch return error.BadRequest;

    if (try ProductModel.findById(db, id, ctx.allocator)) |product| {
        try ctx.renderJson(.{ .data = product });
    } else {
        return error.NotFound;
    }
}

pub fn create(ctx: *zfinal.Context) !void {
    if (!std.mem.eql(u8, ctx.attr("role") orelse "", "admin")) return error.Forbidden;

    const db = try pool.acquire();
    defer pool.release(db) catch {};

    const name = (try ctx.getPara("name")) orelse return error.ValidationError;
    const price_str = (try ctx.getPara("price")) orelse return error.ValidationError;
    const price = std.fmt.parseFloat(f64, price_str) catch return error.ValidationError;

    var product = ProductModel.Instance{
        .data = .{ .name = name, .price = price },
    };
    try product.save(&db);
    ctx.res_status = .created;
    try ctx.renderJson(.{ .data = product.data });
}
```
