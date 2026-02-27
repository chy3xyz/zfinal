# ZFinal 开发文档

欢迎使用 ZFinal！这是一个受 JFinal 启发的 Zig Web 框架，旨在提供极简、高性能的 Web 开发体验。

## 目录

1. [ZF CLI 工具](zf_cli.md)
   - 命令行工具使用指南
   - 快速创建项目和生成代码

2. [快速开始 (Getting Started)](getting_started.md)
   - 环境要求
   - 安装 zfctl 工具
   - 创建第一个项目
   - 项目结构说明

2. [核心概念 (Core Concepts)](core_concepts.md)
   - 路由 (Routing)
   - 控制器 (Controller)
   - 上下文 (Context)
   - 参数获取 (Parameter Handling)
   - 响应渲染 (Rendering)

3. [数据库与 ORM (Database & ORM)](database.md)
   - 数据库配置
   - Active Record 模式
   - CRUD 操作
   - 事务处理
   - SQL 模板

4. [进阶功能 (Advanced Features)](advanced.md)
   - 拦截器 (Interceptors / AOP)
   - 验证器 (Validators)
   - 文件上传与下载
   - 插件系统 (Plugins)
   - 国际化 (I18n)

5. [工具包 (Kits)](kits.md)
   - StringKit, HashKit, DateKit 等常用工具

6. [高阶教程：Life3 应用](tutorial_life3.md)
   - 完整开发一个生活管理应用
   - 旅程、计划、记录、统计分析
   - 数据建模、RESTful API、服务层设计

7. [HTMX 模板系统](htmx_template.md)
   - 基于 HTMX 的现代 Web 开发
   - 无需编写 JavaScript
   - 完整的待办事项应用示例

## 为什么选择 ZFinal？

- **高性能**: 基于 Zig 语言，原生编译，无 GC 暂停。
- **极简设计**: 核心库轻量，无繁杂依赖。
- **开发效率**: 类似 JFinal 的极简 API，让 Java 开发者倍感亲切。
- **全栈能力**: 内置 ORM、模板引擎（规划中）、验证器等，开箱即用。
