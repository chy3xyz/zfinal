//! Named interceptors for generated routes. Main assigns real instances before register.
const zfinal = @import("zfinal");

pub var csrf: zfinal.Interceptor = .{ .name = "csrf" };
pub var jwt: zfinal.Interceptor = .{ .name = "jwt" };
