# Smart routing example

Minimal `actions.zig` fixtures for [doc/smart_routing.md](../../doc/smart_routing.md).

```bash
zig build install-zf
./zig-out/bin/zf routes --root examples/smart-routing/src/modules --json
```

Generates `routes.zig` next to each `actions.zig` (nested orders + assets `*path`).

If `module.interceptors` is set, generated routes import `src/interceptors.zig`
(names must match exports such as `auth`, `access_log`).

Runnable counterpart: `examples/production` (CSRF/JWT via named interceptors +
`zf routes --root examples/production/src/modules`).
