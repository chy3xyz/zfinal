# 快速开始

## 1. 环境要求

- **Zig**: 0.14.0 或更高版本
- **OS**: macOS, Linux, Windows (WSL)

## 2. 安装 zfctl 工具

`zfctl` 是 ZFinal 的命令行工具，用于快速创建项目脚手架。

```bash
# 克隆仓库
git clone https://github.com/your-repo/zfinal.git
cd zfinal

# 编译并安装工具
zig build install

# 将工具添加到 PATH (可选，或者直接使用 ./zig-out/bin/zfctl)
export PATH=$PATH:$(pwd)/zig-out/bin
```

## 3. 创建第一个项目

使用 `zfctl` 创建一个名为 `myapp` 的新项目：

```bash
zfctl new myapp
```

这将生成以下目录结构：

```
myapp/
├── build.zig           # 构建脚本
├── build.zig.zon       # 依赖配置
└── src/
    ├── main.zig        # 应用入口
    ├── config/         # 配置层
    │   ├── config.zig
    │   ├── routes.zig
    │   └── db_init.zig
    ├── controller/     # 控制器层
    │   └── index_controller.zig
    ├── model/          # 模型层
    │   └── user.zig
    └── interceptor/    # 拦截器层
        └── interceptors.zig
```

## 4. 运行项目

进入项目目录并运行：

```bash
cd myapp
zig build run
```

访问 `http://localhost:8080`，你应该能看到欢迎信息：

```json
{
  "message": "Welcome to zfinal!",
  "version": "0.1.0"
}
```

## 5. 开发流程

ZFinal 遵循 MVC 模式：

1.  **Model**: 在 `src/model/` 定义数据模型。
2.  **Controller**: 在 `src/controller/` 编写业务逻辑。
3.  **Route**: 在 `src/config/routes.zig` 注册路由。
4.  **View**: 目前主要支持 JSON 和 文本渲染，HTML 模板正在规划中。
