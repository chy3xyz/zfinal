# WebSocket

RFC 6455 frame codec + connection helpers + `WebSocketManager`.

| Piece | API |
|-------|-----|
| App registration | `app.addWebSocket("/ws", handler)` — Upgrade inside `Server` after `receiveHead` |
| Handshake | `zfinal.websocket_handshake` (`acceptKey`, `upgradeResponse`, `extractClientKey`) |
| Frames | `WebSocket` — server requires **client MASK**, rejects RSV, max 1 MiB |
| Manager | owned by `ZFinal` when `addWebSocket` is used |

## Production notes

1. Prefer **`ZFinal.addWebSocket`** (integrated Upgrade). Dedicated accept loops are only for exotic topologies.
2. Keep `force_connection_close=true` on HTTP; WS connections are one-shot takeovers (no HTTP keep-alive reuse after 101).
3. Put JWT/cookie checks in the handler (or reverse-proxy auth) before business logic.
4. Server skips double-close after Upgrade; `WebSocket.deinit` owns the TCP socket.
5. **Idle / ping**：设 `ws.idle_timeout_ms`；读写会刷新 `last_activity_ms`。`WebSocketManager.pingAll` / `reapIdle` 用于探活与回收空闲连接。

## Minimal app

```zig
try app.addWebSocket("/ws", echoHandler);
try app.start();
```

Demo: `zig build run-ws`. See also: [reverse_proxy.md](reverse_proxy.md).
