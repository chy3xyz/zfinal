# zfsaas — ZFinal SaaS 全栈示例

前后端同仓模板，可直接复制改业务。

| 目录 | 技术 | 端口 |
|------|------|------|
| [`backend/`](backend/) | ZFinal Zig API（auth / org / billing / todo） | `:8080` |
| [`frontend/`](frontend/) | SolidStart（源自 [saas-solidjs / zsaas-start](https://github.com/chy3xyz/saas-solidjs)） | `:3000` |

契约与对接说明：[doc/saas_kit.md](../../doc/saas_kit.md)（路径已迁至本示例）。

## 快速启动

```bash
# 仓库根目录
./examples/zfsaas/scripts/dev.sh
# 或分终端：
zig build run-zfsaas          # API
cd examples/zfsaas/frontend && cp -n .env.example .env && npm i && npm run dev
```

测试后端领域逻辑：

```bash
zig build test-zfsaas
```

## 架构

```
SolidStart (frontend)  --Bearer JWT-->  ZFinal (backend)  --> SQLite/PG
                                         ^
Stripe webhook --------------------------+
```

- **默认**：前端仍可独立用 Drizzle+PGLite（原 zsaas 路径），便于对照。
- **对接 ZFinal**：设 `ZFINAL_API_URL=http://127.0.0.1:8080`，用 `src/libs/zfinalClient.ts` 调 API；逐步把 auth/billing server actions 切到 HTTP（见 doc）。

## 环境变量

**Backend**：`JWT_SECRET` · `SAAS_DB` · `CORS_ORIGIN`（默认 `http://localhost:3000`）· `STRIPE_*` · `PUBLIC_BASE_URL`

**Frontend**：见 `frontend/.env.example`（含 `ZFINAL_API_URL`）
