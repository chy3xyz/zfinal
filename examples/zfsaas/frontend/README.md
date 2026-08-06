# zfsaas frontend (SolidStart)

Vendored from [saas-solidjs](https://github.com/chy3xyz/saas-solidjs) / zsaas-start into the ZFinal monorepo.

**Parent README:** [../README.md](../README.md)

## Modes

| Mode | How |
|------|-----|
| **Standalone** (Drizzle + PGLite) | Unset `ZFINAL_API_URL`; `npm run db-server` + `npm run dev` |
| **ZFinal API** | Set `ZFINAL_API_URL=http://127.0.0.1:8080`; use `src/libs/zfinalClient.ts` |

```bash
cp .env.example .env
npm install
# optional legacy DB:
# npm run db-server && npm run db:migrate
npm run dev   # http://localhost:3000
```

Backend: from repo root `zig build run-zfsaas`.
