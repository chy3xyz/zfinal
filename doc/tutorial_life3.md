# 高阶教程：开发 Life3 应用

Life3 是一个完整的生活管理应用，包含旅程（Journey）、计划（Plan）、记录（Record）和统计分析功能。

## 目录

1. [项目概述](#项目概述)
2. [数据模型设计](#数据模型设计)
3. [项目初始化](#项目初始化)
4. [数据库设计](#数据库设计)
5. [模型层实现](#模型层实现)
6. [控制器层实现](#控制器层实现)
7. [统计分析功能](#统计分析功能)
8. [拦截器与验证](#拦截器与验证)
9. [API 测试](#api-测试)
10. [总结](#总结)

## 项目概述

Life3 应用的核心功能：

- **旅程 (Journey)**: 长期目标，如"学习 Zig 编程"、"健康生活"
- **计划 (Plan)**: 具体计划，关联到某个旅程，如"每天学习 1 小时"
- **记录 (Record)**: 每日执行记录，关联到计划
- **统计分析**: 基于记录数据的完成率、趋势分析

## 数据模型设计

### ER 图

```
Journey (旅程)
  ├─ id: i64
  ├─ title: string
  ├─ description: string
  ├─ created_at: timestamp
  └─ Plans (1:N)

Plan (计划)
  ├─ id: i64
  ├─ journey_id: i64 (FK)
  ├─ title: string
  ├─ target_days: i32 (目标天数)
  ├─ created_at: timestamp
  └─ Records (1:N)

Record (记录)
  ├─ id: i64
  ├─ plan_id: i64 (FK)
  ├─ completed: bool
  ├─ notes: string
  ├─ record_date: date
  └─ created_at: timestamp
```

## 项目初始化

使用 `zfctl` 创建项目：

```bash
cd /path/to/projects
zfctl new life3
cd life3
```

## 数据库设计

编辑 `src/config/db_init.zig`：

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub fn initDatabase(db: *zfinal.DB) !void {
    // 创建 journeys 表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS journeys (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    title TEXT NOT NULL,
        \\    description TEXT,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP
        \\)
    );

    // 创建 plans 表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS plans (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    journey_id INTEGER NOT NULL,
        \\    title TEXT NOT NULL,
        \\    target_days INTEGER DEFAULT 30,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (journey_id) REFERENCES journeys(id) ON DELETE CASCADE
        \\)
    );

    // 创建 records 表
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS records (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    plan_id INTEGER NOT NULL,
        \\    completed BOOLEAN DEFAULT 0,
        \\    notes TEXT,
        \\    record_date TEXT NOT NULL,
        \\    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE
        \\)
    );

    // 创建索引
    try db.exec("CREATE INDEX IF NOT EXISTS idx_plans_journey ON plans(journey_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_records_plan ON records(plan_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_records_date ON records(record_date)");

    std.debug.print("✅ Life3 database initialized\n", .{});
}
```

## 模型层实现

### src/model/journey.zig

```zig
const zfinal = @import("zfinal");

pub const Journey = struct {
    id: ?i64 = null,
    title: []const u8,
    description: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
};

pub const JourneyModel = zfinal.Model(Journey, "journeys");
```

### src/model/plan.zig

```zig
const zfinal = @import("zfinal");

pub const Plan = struct {
    id: ?i64 = null,
    journey_id: i64,
    title: []const u8,
    target_days: i32 = 30,
    created_at: ?[]const u8 = null,
};

pub const PlanModel = zfinal.Model(Plan, "plans");
```

### src/model/record.zig

```zig
const zfinal = @import("zfinal");

pub const Record = struct {
    id: ?i64 = null,
    plan_id: i64,
    completed: bool = false,
    notes: ?[]const u8 = null,
    record_date: []const u8, // YYYY-MM-DD
    created_at: ?[]const u8 = null,
};

pub const RecordModel = zfinal.Model(Record, "records");
```

## 控制器层实现

### src/controller/journey_controller.zig

```zig
const std = @import("std");
const zfinal = @import("zfinal");
const JourneyModel = @import("../model/journey.zig").JourneyModel;

pub const JourneyController = struct {
    /// 获取所有旅程
    pub fn index(ctx: *zfinal.Context) !void {
        // TODO: 从 app context 获取 db
        try ctx.renderJson(.{
            .message = "Journey list",
            .journeys = .{},
        });
    }

    /// 创建旅程
    pub fn create(ctx: *zfinal.Context) !void {
        const title = (try ctx.getPara("title")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing title" });
            return;
        };

        const description = try ctx.getPara("description");

        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("title", title);
        try validator.validateMinLength("title", title, 1);
        try validator.validateMaxLength("title", title, 200);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "Journey created",
            .title = title,
            .description = description,
        });
    }

    /// 获取旅程详情（包含关联的计划）
    pub fn show(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing journey ID" });
            return;
        };

        const id = std.fmt.parseInt(i64, id_str, 10) catch {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Invalid journey ID" });
            return;
        };

        try ctx.renderJson(.{
            .id = id,
            .title = "Sample Journey",
            .plans = .{},
        });
    }

    /// 删除旅程
    pub fn delete(ctx: *zfinal.Context) !void {
        const id_str = ctx.getPathParam("id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing journey ID" });
            return;
        };

        try ctx.renderJson(.{
            .message = "Journey deleted",
            .id = id_str,
        });
    }
};
```

### src/controller/plan_controller.zig

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub const PlanController = struct {
    /// 获取旅程的所有计划
    pub fn index(ctx: *zfinal.Context) !void {
        const journey_id = ctx.getPathParam("journey_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing journey ID" });
            return;
        };

        try ctx.renderJson(.{
            .journey_id = journey_id,
            .plans = .{},
        });
    }

    /// 创建计划
    pub fn create(ctx: *zfinal.Context) !void {
        const journey_id_str = ctx.getPathParam("journey_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing journey ID" });
            return;
        };

        const title = (try ctx.getPara("title")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing title" });
            return;
        };

        const target_days = try ctx.getParaToIntDefault("target_days", 30);

        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("title", title);
        try validator.validateRange("target_days", target_days, 1, 365);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "Plan created",
            .journey_id = journey_id_str,
            .title = title,
            .target_days = target_days,
        });
    }
};
```

### src/controller/record_controller.zig

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub const RecordController = struct {
    /// 获取计划的所有记录
    pub fn index(ctx: *zfinal.Context) !void {
        const plan_id = ctx.getPathParam("plan_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing plan ID" });
            return;
        };

        try ctx.renderJson(.{
            .plan_id = plan_id,
            .records = .{},
        });
    }

    /// 创建记录
    pub fn create(ctx: *zfinal.Context) !void {
        const plan_id_str = ctx.getPathParam("plan_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing plan ID" });
            return;
        };

        const completed = try ctx.getParaToBooleanDefault("completed", false);
        const notes = try ctx.getPara("notes");
        const record_date = (try ctx.getPara("record_date")) orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing record_date" });
            return;
        };

        var validator = zfinal.Validator.init(ctx.allocator);
        defer validator.deinit();

        try validator.validateRequired("record_date", record_date);

        if (validator.hasErrors()) {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .errors = validator });
            return;
        }

        try ctx.renderJson(.{
            .message = "Record created",
            .plan_id = plan_id_str,
            .completed = completed,
            .record_date = record_date,
            .notes = notes,
        });
    }
};
```

### src/controller/stats_controller.zig

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub const StatsController = struct {
    /// 获取旅程统计
    pub fn journeyStats(ctx: *zfinal.Context) !void {
        const journey_id = ctx.getPathParam("journey_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing journey ID" });
            return;
        };

        // TODO: 实现真实的统计逻辑
        try ctx.renderJson(.{
            .journey_id = journey_id,
            .total_plans = 5,
            .total_records = 120,
            .completion_rate = 0.85,
            .streak_days = 7,
        });
    }

    /// 获取计划统计
    pub fn planStats(ctx: *zfinal.Context) !void {
        const plan_id = ctx.getPathParam("plan_id") orelse {
            ctx.res_status = .bad_request;
            try ctx.renderJson(.{ .@"error" = "Missing plan ID" });
            return;
        };

        try ctx.renderJson(.{
            .plan_id = plan_id,
            .total_records = 30,
            .completed_records = 25,
            .completion_rate = 0.833,
            .current_streak = 5,
            .longest_streak = 12,
        });
    }

    /// 获取整体统计
    pub fn overview(ctx: *zfinal.Context) !void {
        try ctx.renderJson(.{
            .total_journeys = 3,
            .total_plans = 8,
            .total_records = 240,
            .overall_completion_rate = 0.78,
            .active_plans = 5,
        });
    }
};
```

## 统计分析功能

创建 `src/service/stats_service.zig` 用于复杂的统计逻辑：

```zig
const std = @import("std");
const zfinal = @import("zfinal");

pub const StatsService = struct {
    allocator: std.mem.Allocator,
    db: *zfinal.DB,

    pub fn init(allocator: std.mem.Allocator, db: *zfinal.DB) StatsService {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    /// 计算计划的完成率
    pub fn calculateCompletionRate(self: *StatsService, plan_id: i64) !f64 {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            \\SELECT 
            \\  COUNT(*) as total,
            \\  SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END) as completed
            \\FROM records WHERE plan_id = {d}
        ,
            .{plan_id},
        );
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        // TODO: 解析结果并计算
        return 0.85;
    }

    /// 计算连续打卡天数
    pub fn calculateStreak(self: *StatsService, plan_id: i64) !i32 {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            \\SELECT record_date, completed 
            \\FROM records 
            \\WHERE plan_id = {d} 
            \\ORDER BY record_date DESC
        ,
            .{plan_id},
        );
        defer self.allocator.free(sql);

        var result = try self.db.query(sql);
        defer result.deinit();

        // TODO: 实现连续天数计算逻辑
        return 7;
    }

    /// 获取趋势数据（最近 N 天）
    pub fn getTrend(self: *StatsService, plan_id: i64, days: i32) ![]TrendData {
        _ = self;
        _ = plan_id;
        _ = days;
        // TODO: 实现趋势分析
        return &[_]TrendData{};
    }

    pub const TrendData = struct {
        date: []const u8,
        completed: bool,
    };
};
```

## 路由配置

编辑 `src/config/routes.zig`：

```zig
const zfinal = @import("zfinal");
const IndexController = @import("../controller/index_controller.zig").IndexController;
const JourneyController = @import("../controller/journey_controller.zig").JourneyController;
const PlanController = @import("../controller/plan_controller.zig").PlanController;
const RecordController = @import("../controller/record_controller.zig").RecordController;
const StatsController = @import("../controller/stats_controller.zig").StatsController;

pub fn configRoutes(app: *zfinal.ZFinal) !void {
    // 首页
    try app.get("/", IndexController.index);

    // 旅程路由
    try app.get("/api/journeys", JourneyController.index);
    try app.post("/api/journeys", JourneyController.create);
    try app.get("/api/journeys/:id", JourneyController.show);
    try app.delete("/api/journeys/:id", JourneyController.delete);

    // 计划路由
    try app.get("/api/journeys/:journey_id/plans", PlanController.index);
    try app.post("/api/journeys/:journey_id/plans", PlanController.create);

    // 记录路由
    try app.get("/api/plans/:plan_id/records", RecordController.index);
    try app.post("/api/plans/:plan_id/records", RecordController.create);

    // 统计路由
    try app.get("/api/stats/overview", StatsController.overview);
    try app.get("/api/stats/journeys/:journey_id", StatsController.journeyStats);
    try app.get("/api/stats/plans/:plan_id", StatsController.planStats);
}
```

## API 测试

### 创建旅程

```bash
curl -X POST http://localhost:8080/api/journeys \
  -d 'title=学习 Zig 编程&description=掌握 Zig 语言和 ZFinal 框架'
```

### 创建计划

```bash
curl -X POST http://localhost:8080/api/journeys/1/plans \
  -d 'title=每天学习 1 小时&target_days=90'
```

### 创建记录

```bash
curl -X POST http://localhost:8080/api/plans/1/records \
  -d 'completed=true&record_date=2024-01-15&notes=学习了路由和控制器'
```

### 查看统计

```bash
# 整体统计
curl http://localhost:8080/api/stats/overview

# 旅程统计
curl http://localhost:8080/api/stats/journeys/1

# 计划统计
curl http://localhost:8080/api/stats/plans/1
```

## 总结

本教程展示了如何使用 ZFinal 开发一个完整的 Life3 应用，涵盖：

1. **数据建模**: 三层关联模型（Journey → Plan → Record）
2. **RESTful API**: 标准的 CRUD 操作
3. **数据验证**: 使用 Validator 进行输入验证
4. **统计分析**: 完成率、连续天数、趋势分析
5. **服务层**: 分离业务逻辑到 Service 层

### 后续优化方向

1. **认证授权**: 添加用户系统和 JWT 认证
2. **数据库集成**: 在控制器中真正使用数据库
3. **缓存优化**: 使用 CachePlugin 缓存统计数据
4. **定时任务**: 使用 CronPlugin 定期清理过期数据
5. **WebSocket**: 实时推送完成进度
6. **前端界面**: 使用 HTML + JavaScript 构建 UI
