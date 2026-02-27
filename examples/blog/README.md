# Blog 应用 - 模块化结构

参考 JFinal 的组织方式，将应用拆分为清晰的模块结构。

## 目录结构

```
blog/
├── main.zig                    # 应用入口
├── model/                      # 数据模型层
│   ├── user.zig               # User Model
│   ├── post.zig               # Post Model
│   └── comment.zig            # Comment Model
├── controller/                 # 控制器层
│   ├── index_controller.zig   # 首页控制器
│   ├── user_controller.zig    # 用户控制器
│   ├── post_controller.zig    # 文章控制器
│   └── comment_controller.zig # 评论控制器
├── interceptor/                # 拦截器
│   └── interceptors.zig       # 日志、认证拦截器
└── config/                     # 配置
    ├── config.zig             # 应用配置
    ├── routes.zig             # 路由配置
    └── db_init.zig            # 数据库初始化
```

## 模块说明

### Model 层 (`model/`)
- **user.zig** - 用户模型和 UserModel
- **post.zig** - 文章模型和 PostModel
- **comment.zig** - 评论模型和 CommentModel

每个 Model 文件包含：
- 数据结构定义
- Model 类型定义（使用 zfinal.Model）

### Controller 层 (`controller/`)
- **index_controller.zig** - 首页
- **user_controller.zig** - 用户 CRUD
- **post_controller.zig** - 文章 CRUD
- **comment_controller.zig** - 评论管理

每个 Controller 包含：
- index() - 列表
- show() - 详情
- create() - 创建
- update() - 更新
- delete() - 删除

### Interceptor 层 (`interceptor/`)
- **interceptors.zig** - 所有拦截器
  - LoggingInterceptor - 请求日志
  - AuthInterceptor - 认证检查

### Config 层 (`config/`)
- **config.zig** - 数据库和服务器配置
- **routes.zig** - 集中式路由配置
- **db_init.zig** - 数据库表初始化

## 编译运行

```bash
# 编译
zig build-exe demo/blog/main.zig --dep zfinal -Mzfinal=src/main.zig -lsqlite3 -lc

# 运行
./main
```

## 优势

### 1. 清晰的分层
- Model - 数据层
- Controller - 业务逻辑层
- Config - 配置层
- Interceptor - AOP 层

### 2. 易于扩展
- 添加新 Model：在 `model/` 创建新文件
- 添加新 Controller：在 `controller/` 创建新文件
- 添加新路由：在 `routes.zig` 添加

### 3. 易于维护
- 每个文件职责单一
- 模块间低耦合
- 符合 MVC 模式

### 4. 团队协作友好
- 不同开发者可以并行开发不同模块
- 代码冲突少
- 易于代码审查

## 与 JFinal 对比

| JFinal | zfinal Blog |
|--------|-------------|
| `com.demo.model.User` | `model/user.zig` |
| `com.demo.controller.UserController` | `controller/user_controller.zig` |
| `com.demo.config.Routes` | `config/routes.zig` |
| `com.demo.interceptor.LoginInterceptor` | `interceptor/interceptors.zig` |

## 扩展示例

### 添加新功能（如标签）

1. 创建 Model: `model/tag.zig`
2. 创建 Controller: `controller/tag_controller.zig`
3. 在 `routes.zig` 添加路由
4. 在 `db_init.zig` 添加表创建

### 添加服务层

可以创建 `service/` 目录：
```
service/
├── user_service.zig
├── post_service.zig
└── comment_service.zig
```

### 添加工具类

可以创建 `util/` 目录：
```
util/
├── hash.zig      # 密码哈希
├── token.zig     # JWT Token
└── validator.zig # 自定义验证器
```

这种结构完全符合企业级应用开发的最佳实践！
