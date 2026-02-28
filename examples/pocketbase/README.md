# PocketBase Lite

A lightweight, PocketBase-inspired backend with admin UI and REST API, built with [ZFinal](https://github.com/zigcc/zfinal) framework in Zig.

## Features

### 🎨 Admin Dashboard (HTMX)
- Modern web-based admin interface
- Collection (table) management
- Record browser with dynamic columns
- Session-based authentication

### 🚀 REST API
- RESTful JSON API for all collections
- Dynamic schema support
- CRUD operations on any table
- Zero-config data access

### 💾 Database
- SQLite backend (single file)
- Auto-generated timestamps
- Schema introspection

## Quick Start

```bash
# Build and run
cd demo/pocketbase_lite
zig build run-pb

# Server starts on http://localhost:8090
```

## API Reference

### Collections

#### List Collections
```bash
GET /api/collections

# Response
{
  "collections": ["posts", "users"],
  "total": 2
}
```

### Records

#### List Records
```bash
GET /api/collections/:name/records

# Example
curl http://localhost:8090/api/collections/posts/records

# Response
{
  "items": [
    {"id": "1", "title": "Hello", "created_at": "..."},
    {"id": "2", "title": "World", "created_at": "..."}
  ],
  "totalItems": 2,
  "page": 1,
  "perPage": 100
}
```

#### Get Single Record
```bash
GET /api/collections/:name/records/:id

# Example
curl http://localhost:8090/api/collections/posts/records/1

# Response
{
  "id": "1",
  "title": "Hello",
  "content": "World",
  "created_at": "..."
}
```

#### Create Record
```bash
POST /api/collections/:name/records
Content-Type: application/json
Authorization: Bearer <your_api_token>

# Example
curl -X POST http://localhost:8090/api/collections/posts/records \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your_api_token>" \
  -d '{"title":"New Post","content":"Content here"}'

# Response
{
  "id": "e98e4r9d...",
  "message": "Record created successfully"
}
```

#### Update Record
```bash
PATCH /api/collections/:name/records/:id
Content-Type: application/json
Authorization: Bearer <your_api_token>

# Example
curl -X PATCH http://localhost:8090/api/collections/posts/records/1 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your_api_token>" \
  -d '{"title":"Updated Title"}'
```

#### Delete Record
```bash
DELETE /api/collections/:name/records/:id
Authorization: Bearer <your_api_token>

# Example
curl -X DELETE http://localhost:8090/api/collections/posts/records/1 \
  -H "Authorization: Bearer <your_api_token>"

# Response: 204 No Content
```

## Admin Dashboard

### Access
Navigate to `http://localhost:8090/admin`

### Default Credentials
- **Email**: `admin@example.com`
- **Password**: `password`

### Features
- **Dashboard**: System overview
- **Collections**: View and create tables
- **Records**: Browse, create, and manage data

## Architecture

```
├── main.zig                    # Entry point
├── src/
│   ├── controller/
│   │   ├── admin/              # Admin UI (HTMX)
│   │   │   ├── auth_controller.zig
│   │   │   ├── collection_controller.zig
│   │   │   └── record_controller.zig
│   │   └── api/                # Public API (JSON)
│   │       ├── collection_api.zig
│   │       └── record_api.zig
│   └── templates/admin/        # HTMX views
└── pocketbase_lite.db          # SQLite database
```

## Comparison with PocketBase

| Feature | PocketBase | PocketBase Lite |
|---------|-----------|-----------------|
| Language | Go | Zig |
| Database | SQLite | SQLite |
| Admin UI | ✅ SvelteKit | ✅ HTMX |
| REST API | ✅ Full | ✅ Basic |
| Realtime | ✅ SSE | ❌ |
| Authentication | ✅ Advanced | 🟡 Basic |
| File Storage | ✅ | ❌ |
| Rules Engine | ✅ | ❌ |
| Migrations | ✅ | ❌ |

## Limitations

⚠️ **This is a demo/learning project**:
- No authentication on API routes
- No input validation/sanitization  
- No pagination limits
- Simplified security model
- SQL injection vulnerable (demo only)

## Development

### Creating a Collection

Via Admin UI:
1. Login to admin
2. Click "New Collection"
3. Enter name and schema (e.g., `title TEXT, content TEXT`)

Via API:
```bash
# Not implemented - use Admin UI
```

### Example: Blog Schema

```sql
-- Created via Admin UI with schema:
title TEXT, content TEXT, author TEXT, published BOOLEAN
```

Resulting table:
```sql
CREATE TABLE posts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT,
  content TEXT,
  author TEXT,
  published BOOLEAN,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
)
```

## Tech Stack

- **Framework**: [ZFinal](https://github.com/zigcc/zfinal) - High-performance Zig web framework
- **Database**: SQLite3
- **Admin UI**: HTMX + Tailwind CSS
- **Language**: Zig 0.14

## License

MIT

## Credits

Inspired by [PocketBase](https://pocketbase.io/) by Gani Georgiev.
