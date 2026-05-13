---
name: zfinal-app
description: Build full-stack web apps with ZFinal. Three modes: new project (DB modeling + code gen), existing SQL (parse schema + code gen), legacy migration (extract SQL from Java/PHP/Go/Rust + code gen). Maximize code generation, then AI fills business logic.
---

# ZFinal Application Builder — 3-Mode Workflow

ZFinal's primary value: **maximize code generation from database schema, then AI fills what can't be generated.**

## Mode 1: New Project (Greenfield)

User describes domain → you design DB schema → ZF generates CRUD → you fill business logic.

### Workflow

```
1. Model database: CREATE TABLE statements for all entities
2. zf crud:sql schema.sql    ← generates everything
3. AI fills: business rules, auth, validation, inter-service calls
4. zig build test && zig build run
```

### Example

User: "Build a blog with users, posts, comments"

```sql
-- schema.sql
CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL, body TEXT, published BOOLEAN DEFAULT 0, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER NOT NULL REFERENCES posts(id), user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);
```

```bash
zf crud:sql schema.sql  # Generates all models, controllers, routes, tests
```

Then AI adds to each generated controller:
- `posts_controller.zig`: check `user_id == current_user.id` before update/delete
- `comments_controller.zig`: rate limit, spam detection
- Auth interceptor: JWT/session validation
- Password hashing in create/update user

## Mode 2: Existing SQL Schema (Brownfield)

User has SQL dump from existing database → parse schema → generate → AI fills.

### Workflow

```
1. Collect SQL schema (mysqldump --no-data, pg_dump --schema-only, or .sql file)
2. zf crud:sql dump.sql    ← parses all CREATE TABLE, generates full package
3. AI reviews generated code, adds missing business logic
4. Incrementally replace old API endpoints with generated ones
```

### Handling Multiple SQL Dialects

The parser supports SQLite, MySQL, and PostgreSQL CREATE TABLE syntax:
- `INTEGER PRIMARY KEY AUTOINCREMENT` (SQLite)
- `INT AUTO_INCREMENT PRIMARY KEY` (MySQL)
- `SERIAL PRIMARY KEY` (PostgreSQL)
- Backtick, double-quote, and unquoted identifiers
- `IF NOT EXISTS`, `DEFAULT`, `NOT NULL`, `UNIQUE`, `REFERENCES`

## Mode 3: Legacy Migration (Java/PHP/Go/Rust)

User has existing project → you extract SQL schema → generate Zig code → AI maps business logic.

### Workflow

```
1. Extract SQL schema from legacy project:
   - Java: find *.sql files, @Entity classes, application.properties (spring.datasource)
   - PHP:  find *.sql, Schema.php, migration files
   - Go:   find *.sql, migration/*.up.sql, model struct tags
   - Rust: find *.sql, migration dir, diesel schema.rs
2. Consolidate into single schema.sql
3. zf crud:sql schema.sql    ← generates ZFinal package
4. AI maps business logic:
   - Read old controller → understand business rules → port to Zig
   - Read old middleware → port to ZFinal interceptors
   - Read old validation → port to ZFinal validator
   - Read old tests → port to ZFinal test format
5. Verify: compare old API responses with new
```

### Legacy Pattern Mapping

| Legacy Pattern | ZFinal Equivalent |
|---------------|-------------------|
| @RestController (Java) | Controller with `renderJson` |
| @Entity + JpaRepository | Model + ActiveRecord |
| @Transactional | `db.begin()` / `db.commit()` |
| Spring Security Filter | Interceptor `.before` |
| Bean Validation annotations | Validator.validate* |
| Laravel Eloquent Model | Model + ActiveRecord |
| Laravel Middleware | Interceptor |
| Gin Handler (Go) | Handler function |
| GORM Model (Go) | Model + ActiveRecord |
| Actix Web Handler (Rust) | Handler function |
| Diesel Schema (Rust) | Model + raw query |

## ZF CLI Commands

```bash
# Schema-based generation (primary workflow)
zf crud:sql schema.sql        # Parse SQL file → generate everything
zf crud db.sqlite3 users      # Read from live SQLite DB → generate CRUD

# Manual code generation
zf new project_name           # Create project scaffold
zf g controller User          # Generate controller + HTMX template
zf api Product                # Generate JSON API controller
zf g model User               # Generate ActiveRecord model
zf g interceptor Auth         # Generate interceptor
zf g plugin Custom            # Generate plugin skeleton

# Utilities
zf migrate new init           # Create migration file
zf test:gen UserService       # Generate test file
zf docker                     # Generate Dockerfile + compose
```

## Quality Checklist (After Generation)

Before accepting generated code, verify:
- [ ] All `init()` have matching `defer deinit()`
- [ ] SQL uses parameterized queries (generator already does this)
- [ ] POST/PUT/DELETE routes have CSRF protection (add manually)
- [ ] Input validation added for non-trivial fields (email format, length limits)
- [ ] Auth checks on sensitive endpoints
- [ ] Rate limiting on public endpoints
- [ ] Logger calls instead of std.debug.print
- [ ] `zig build test` passes
