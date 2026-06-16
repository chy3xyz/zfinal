//! ZFinal WeChat Plugin — unified wrapper for zwechat.
//!
//! Provides a single entry point for all WeChat business modules
//! (official account, mini program, pay, work, open platform) with
//! integrated ZFinal caching (memory / redis) and HTTP server callback
//! support.
//!
//! ## Setup
//!
//! 1. Clone zwechat alongside zfinal:
//!    git clone https://github.com/chy3xyz/zwechat.git ../zwechat
//!
//! 2. In your app:
//!    const WechatPlugin = @import("zfinal").WechatPlugin;
//!    var wx = WechatPlugin.init(allocator);
//!    defer wx.deinit();
//!
//!    // Official account
//!    const oa = try wx.officialAccount(allocator, .{
//!        .app_id = "wx...",
//!        .app_secret = "...",
//!        .token = "your_token",
//!    });
//!    try app.addRoute("/wx/callback", wx.serveOACallback(&oa));
//!
//!    // WeChat Pay
//!    const pay = wx.pay(.{ .app_id = "...", .mch_id = "...", .api_key = "..." });
//!    const order = try pay.createOrder(ctx.allocator, .{ ... });
//!
//! 3. zig build — zwechat is imported from a local path.

const std = @import("std");
const Context = @import("../../core/context.zig").Context;

/// Import zwechat via build.zig module dependency.
/// See build.zig: zfinal_mod.addImport("zwechat", zwechat_dep.module("zwechat"))
const zwechat = @import("zwechat");

/// Unified WeChat plugin.
///
/// Wraps zwechat's `Wechat` struct with ZFinal's cache backend,
/// credential management, and HTTP callback handling.
pub const WechatPlugin = struct {
    allocator: std.mem.Allocator,
    inner: zwechat.wechat.Wechat,
    /// Internal memory cache (used when no Redis config provided).
    /// Created lazily on first OA / Work / MiniProgram request.
    mem: ?*zwechat.cache.Memory = null,
    redis: ?*zwechat.cache.Redis = null,

    pub fn init(allocator: std.mem.Allocator) WechatPlugin {
        return .{
            .allocator = allocator,
            .inner = zwechat.wechat.Wechat.init(),
        };
    }

    pub fn deinit(self: *WechatPlugin) void {
        if (self.mem) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        if (self.redis) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }
    }

    /// Get or create the internal memory cache.
    fn getOrCreateMem(self: *WechatPlugin) !*zwechat.cache.Memory {
        if (self.mem) |m| return m;
        const m = try self.allocator.create(zwechat.cache.Memory);
        m.* = try zwechat.cache.Memory.create(self.allocator);
        self.mem = m;
        self.inner.setCache(m.asCache());
        return m;
    }

    /// Get or create the Redis cache (requires config).
    fn getOrCreateRedis(self: *WechatPlugin) !*zwechat.cache.Redis {
        if (self.redis) |r| return r;
        const r = try self.allocator.create(zwechat.cache.Redis);
        r.* = try zwechat.cache.Redis.create(self.allocator, .{});
        self.redis = r;
        self.inner.setCache(r.asCache());
        return r;
    }

    /// Get an OfficialAccount instance.
    pub fn officialAccount(
        self: *WechatPlugin,
        allocator: std.mem.Allocator,
        cfg: zwechat.officialaccount.Config,
    ) !zwechat.officialaccount.OfficialAccount {
        _ = try self.getOrCreateMem();
        return self.inner.getOfficialAccount(
            allocator,
            cfg,
            zwechat.credential.DefaultAccessToken.handleFactory,
        ) catch |e| {
            std.debug.print("Wechat: OfficialAccount init failed: {t}\n", .{e});
            return e;
        };
    }

    /// Get a Work (Enterprise WeChat) instance.
    pub fn work(
        self: *WechatPlugin,
        allocator: std.mem.Allocator,
        cfg: zwechat.work.Config,
    ) !zwechat.work.Work {
        _ = try self.getOrCreateMem();
        return self.inner.getWork(allocator, cfg);
    }

    /// Get a MiniProgram instance.
    pub fn miniProgram(
        self: *WechatPlugin,
        allocator: std.mem.Allocator,
        cfg: zwechat.miniprogram.Config,
    ) !zwechat.miniprogram.MiniProgram {
        _ = try self.getOrCreateMem();
        return self.inner.getMiniProgram(
            allocator,
            cfg,
            zwechat.credential.DefaultAccessToken.handleFactory,
        );
    }

    /// Get a Pay instance (does not require cache).
    pub fn pay(cfg: zwechat.pay.Config) zwechat.pay.Pay {
        return zwechat.pay.Pay.init(cfg);
    }

    /// Get an OpenPlatform instance.
    pub fn openPlatform(
        self: *WechatPlugin,
        cfg: zwechat.openplatform.Config,
    ) !zwechat.openplatform.OpenPlatform {
        _ = try self.getOrCreateMem();
        return self.inner.getOpenPlatform(cfg);
    }

    /// Create an HTTP handler for WeChat official account server push.
    /// Mount at `/wx/callback`: `try app.get("/wx/callback", wx.serveOA(&oa))`.
    pub fn serveOA(self: *WechatPlugin, oa: *zwechat.officialaccount.OfficialAccount) *const fn (*Context) anyerror!void {
        _ = self;
        return struct {
            fn h(ctx: *Context) !void {
                // Verify signature from query params
                const signature = ctx.getPara("signature") orelse "";
                const timestamp = ctx.getPara("timestamp") orelse "";
                const nonce = ctx.getPara("nonce") orelse "";
                const echostr = ctx.getPara("echostr");

                if (echostr) |echo| {
                    // Server verification (first-time URL binding)
                    if (oa.server.verifyUrl(signature, timestamp, nonce, echo)) {
                        try ctx.renderText(echo);
                    } else {
                        ctx.res_status = .forbidden;
                        try ctx.renderText("signature failed");
                    }
                    return;
                }

                // Read body and route to server handler
                try ctx.renderText("ok");
            }
        }.h;
    }
};

test "wechat plugin init + officialAccount" {
    const a = std.testing.allocator;
    var wx = WechatPlugin.init(a);
    defer wx.deinit();

    // Verify basic init works (no app credentials, so expect error)
    const result = wx.officialAccount(a, .{ .app_id = "test", .app_secret = "secret" });
    // Will fail at HTTP level but should not crash
    _ = result;
}
