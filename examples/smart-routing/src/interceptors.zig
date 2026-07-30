//! Named interceptors for `zf routes` generated `*WithInterceptors` calls.
//! Export one `zfinal.Interceptor` per name listed in `module.interceptors` /
//! `actions[].interceptors`. See doc/smart_routing.md.
const zfinal = @import("zfinal");

// Placeholder — replace with real interceptors in your app:
//   var jwt_cfg: zfinal.JwtAuthConfig = .{ .secret = "…" };
//   pub var auth = zfinal.createJwtAuthInterceptorWithOptions(&jwt_cfg);

pub const auth: zfinal.Interceptor = .{ .name = "auth" };
pub const access_log: zfinal.Interceptor = .{ .name = "access_log" };
pub const rate_limit: zfinal.Interceptor = .{ .name = "rate_limit" };
