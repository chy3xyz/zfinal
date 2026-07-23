# 反代 + 强制 Connection: close（生产最佳实践）

> **目标**：在 Zig `std.http.Server` keep-alive 默认不安全（[zig#25017](https://github.com/ziglang/zig/issues/25017)，已在 `0.17.0-dev.1422` 核实仍会 assert）的前提下，  
> **用 nginx / Caddy 对客户端做 keep-alive，对 ZFinal 保持短连接**，消掉应用层 keep-alive 风险。  
> **相关**：[scale_to_millions.md](scale_to_millions.md) · [`PRODUCTION_AUDIT.md`](../PRODUCTION_AUDIT.md) · [`examples/production/deploy/`](../examples/production/deploy/)

---

## 1. 原则（必须遵守）

```
浏览器 / 移动端
      │  HTTP/1.1 keep-alive（或 HTTP/2）
      ▼
nginx / Caddy / Envoy   ← TLS、限流、WAF、客户端连接复用
      │  短连接 / 少复用（upstream 不强制 keep-alive）
      ▼
ZFinal（force_connection_close=true，默认）
```

| 层 | Keep-alive | 谁负责 |
|----|------------|--------|
| 客户端 ↔ 反代 | **开** | nginx / Caddy |
| 反代 ↔ ZFinal | **关（或极少）** | ZFinal 默认 `Connection: close` |
| ZFinal 进程内 | 禁止改默认 | 勿设 `force_connection_close=false` |

**不要**为了「单机压测好看」在生产关掉 `force_connection_close`。  
客户端侧的连接复用已由反代吸收；应用侧少一次握手换的是**进程不崩**。

### 实现注意（v0.20.8+）

- `force_connection_close` 必须在 **`respond` 之前** 清掉 `req.head.keep_alive`，否则响应头仍是 keep-alive，`handleConn` 会卡在下一次 `receiveHead`，占住 `async_limit` 槽。
- 每个连接只跑 **一个** Io fiber；不要再为 idle 另 `group.async` 一个 watchdog（会把有效并发减半，顺序压测约 3–4 个请求后全 HTTP 000）。空闲读超时用 `read_timeout_ms`。

---

## 2. ZFinal 侧配置

```zig
app.setConfig(.{
    .port = 8080,
    // 默认即为 true；显式写出便于审计
    .force_connection_close = true,
    .read_timeout_ms = 30_000,
    .write_timeout_ms = 30_000,
    .request_timeout_ms = 30_000,
    .drain_timeout_ms = 15_000,
    .max_body_size = 1 * 1024 * 1024,
});
```

限流 / 访问日志若要用真实客户端 IP（反代在本机或固定网段）：

```zig
rate_limiter.trust_proxy_headers = true;
rate_limiter.trusted_proxies = &.{"127.0.0.1", "::1"};
// 或内网反代：&.{"10.0.0.0/8"} 需自行按实现支持的形式填写
```

未配置 `trusted_proxies` 时**不要**打开 `trust_proxy_headers`（防伪造 `X-Forwarded-For`）。

`zf check --prod`：若检测到 `force_connection_close = false` 会 **WARN**。

---

## 3. 拓扑检查清单

1. **TLS 只在反代终止**（框架当前不对外提供生产 TLS 终止）。
2. 反代只把流量转到 `127.0.0.1:8080`（或内网 VPC），不对公网暴露 ZFinal 端口。
3. 反代 `proxy_*` / `transport` 超时 ≥ 应用 `read/write/request_timeout`（略大一档，如 35–60s）。
4. 健康检查打反代或直连 `/health`（探针可绕过限流）。
5. 多实例：反代上游池 + 无状态会话（Session 进 Redis）。

---

## 4. nginx 示例

完整文件见 [`examples/production/deploy/nginx.conf`](../examples/production/deploy/nginx.conf)。

要点：

- `proxy_http_version 1.1` 可保留（对 upstream 协议版本）。
- **不要**依赖 upstream keep-alive 池来「救」ZFinal；应用仍会回 `Connection: close`。
- 设置 `proxy_set_header Connection ""` 或显式 `close`，避免错误传递客户端的 keep-alive 期望到应用语义层（应用已强制 close）。
- `proxy_set_header X-Forwarded-For` / `X-Forwarded-Proto` / `Host`。
- `client_max_body_size` 与 `max_body_size` 对齐。

---

## 5. Caddy 示例

完整文件见 [`examples/production/deploy/Caddyfile`](../examples/production/deploy/Caddyfile)。

要点：

- `reverse_proxy 127.0.0.1:8080` + 合理 `transport http { response_header_timeout … }`。
- 自动 HTTPS；本地可用 `http://` 块。
- 需要真实 IP 时用 `header_up X-Forwarded-For {http.request.remote.host}`（Caddy 默认也会注入转发头，仍须在 ZFinal 配 `trusted_proxies`）。

---

## 6. 容量含义（心理预期）

强制 close 后，**同样 QPS 需要更多应用实例 / 更多短连接**，这是刻意的安全换性能。

粗算仍见 [scale_to_millions.md](scale_to_millions.md)：峰值 2 万 QPS、单实例稳妥 ~2k → 约 15–20 实例。  
客户端感知延迟主要由**反代 keep-alive + TLS 会话复用**决定，不是 ZFinal↔反代那一跳。

---

## 7. 何时可以考虑应用侧 keep-alive

**同时**满足再议（默认仍建议关）：

1. 上游 Zig 修好 `discardBody` assert（#25017）且钉到该版本。
2. ZFinal 全路径 body drain / 畸形请求强制 close 的 soak + fuzz 通过。
3. `zf check --prod` 策略与文档同步更新。

在此之前：**反代 keep-alive + 应用 force close = 生产默认。**

---

## 9. Flipping `force_connection_close` default

Zig [issue #25017](https://github.com/ziglang/zig/issues/25017) (`discardBody` assert on keep-alive) was **still present** on pinned `0.17.0-dev.1422`. Before changing ZFinal’s default to allow application-side keep-alive:

1. **Pin Zig** to a build where #25017 is verified fixed (re-run the `keepalive_safety` / raw-respond repro); note the version in CHANGELOG.
2. **Soak** — fuzz/malformed POST + keep-alive under load; no process aborts.
3. **Tests green** — `zig build test` including `src/core/keepalive_safety.zig` (must stay green).
4. **CI green** — full Health Stack on the pinned Zig.
5. **Document** — update this file, `PRODUCTION_AUDIT.md`, and CHANGELOG with the flip date and migration note (nginx still recommended for TLS/client KA).
6. **`zf check --prod`** — adjust WARN policy only after steps 1–5.

Until then, leave `force_connection_close = true` as the default.

---

## 10. 验证

```bash
# 应用（强制 close）
curl -v http://127.0.0.1:8080/health
# 响应头应含 connection: close（或等价）

# 经反代（客户端可复用）
curl -v https://api.example.com/health

# 契约
zf check --prod
```

恶意/畸形 POST（无 CL/TE + keep-alive）直连应用：默认 close 路径下不应拖垮进程；  
**切勿**用「关掉 force_connection_close 压测」当作上线依据。
