# zfinal Blog 演示程序

一个完整的博客应用，展示 zfinal 框架的所有核心功能。

## 功能特性

### 已实现
- ✅ **RESTful API** - 完整的 CRUD 操作
- ✅ **路径参数** - `/api/posts/:id`
- ✅ **查询参数** - 分页支持
- ✅ **数据验证** - 用户输入验证
- ✅ **拦截器** - 日志记录、认证
- ✅ **数据库** - SQLite + ORM
- ✅ **错误处理** - 统一错误响应

### 数据模型
- **User** - 用户（username, email, password）
- **Post** - 文章（title, content, author_id, published）
- **Comment** - 评论（post_id, author_id, content）

## 运行方式

```bash
# 编译
zig build-exe demo/blog_app.zig --dep zfinal -Mzfinal=src/main.zig -lsqlite3 -lc

# 运行
./blog_app
```

## API 端点

### 用户 API
```bash
# 获取用户列表
GET /api/users

# 获取用户详情
GET /api/users/:id

# 创建用户
POST /api/users
  username=alice&email=alice@example.com&password=secret123
```

### 文章 API
```bash
# 获取文章列表（支持分页）
GET /api/posts?page=1&page_size=10

# 获取文章详情
GET /api/posts/:id

# 创建文章
POST /api/posts
  title=My Post&content=Post content

# 更新文章
PUT /api/posts/:id
  title=Updated Title&content=Updated content

# 删除文章
DELETE /api/posts/:id
```

### 评论 API
```bash
# 获取文章评论
GET /api/posts/:post_id/comments

# 创建评论
POST /api/posts/:post_id/comments
  content=Great post!
```

## 测试命令

```bash
# 首页
curl http://localhost:8080/

# 创建用户
curl -X POST http://localhost:8080/api/users \
  -d 'username=alice&email=alice@example.com&password=secret123'

# 获取文章列表
curl http://localhost:8080/api/posts

# 获取文章详情
curl http://localhost:8080/api/posts/1

# 创建文章
curl -X POST http://localhost:8080/api/posts \
  -d 'title=Hello World&content=This is my first post'

# 更新文章
curl -X PUT http://localhost:8080/api/posts/1 \
  -d 'title=Updated Title&content=Updated content'

# 删除文章
curl -X DELETE http://localhost:8080/api/posts/1

# 创建评论
curl -X POST http://localhost:8080/api/posts/1/comments \
  -d 'content=Great post!'
```

## 架构说明

### MVC 结构
- **Models** - User, Post, Comment（使用 zfinal.Model）
- **Controllers** - UserController, PostController, CommentController
- **Routes** - RESTful 路由配置

### 拦截器
- **LoggingInterceptor** - 记录所有请求
- **AuthInterceptor** - 认证检查（示例）

### 数据验证
使用 `zfinal.Validator` 验证：
- 必填字段
- 邮箱格式
- 长度限制

## 扩展建议

1. **完整的数据库操作** - 实际的 CRUD
2. **用户认证** - JWT Token
3. **文件上传** - 文章图片
4. **分页实现** - 使用 `zfinal.Page`
5. **缓存** - 使用 `zfinal.CachePlugin`
6. **国际化** - 使用 `zfinal.I18n`

## 技术栈

- **框架**: zfinal
- **数据库**: SQLite
- **ORM**: Active Record
- **验证**: Validator
- **路由**: RESTful
