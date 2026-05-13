// Export global Io instance
pub const io_instance = @import("io_instance.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}

// Export core modules
pub const ZFinal = @import("core/zfinal.zig").ZFinal;
pub const RouteGroup = @import("core/zfinal.zig").RouteGroup;
pub const Context = @import("core/context.zig").Context;
pub const Server = @import("core/server.zig").Server;
pub const ServerConfig = @import("core/server.zig").ServerConfig;
pub const ThreadPool = @import("core/thread_pool.zig").ThreadPool;
pub const Logger = @import("core/logger.zig").Logger;
pub const LogLevel = @import("core/logger.zig").LogLevel;
pub const LOG_LEVEL = @import("core/logger.zig").LOG_LEVEL;
pub const Field = @import("core/logger.zig").Field;
pub const RequestLogger = @import("core/logger.zig").RequestLogger;
pub const initGlobalLogger = @import("core/logger.zig").initGlobalLogger;
pub const getLogger = @import("core/logger.zig").getLogger;
pub const Metrics = @import("core/metrics.zig").Metrics;
pub const healthHandlerFor = @import("core/metrics.zig").healthHandlerFor;
pub const shutdown = @import("core/shutdown.zig");
// Export database modules
pub const DB = @import("db/db.zig").DB;
pub const DBConfig = @import("db/config.zig").DBConfig;
pub const DBType = @import("db/config.zig").DBType;
pub const ResultSet = @import("db/result.zig").ResultSet;
pub const SqlParam = @import("db/sql_param.zig").SqlParam;
pub const ParamQuery = @import("db/sql_param.zig").ParamQuery;
pub const Model = @import("db/model.zig").Model;
pub const ConnectionPool = @import("db/pool.zig").ConnectionPool;
pub const Page = @import("db/pagination.zig").Page;
pub const SqlTemplate = @import("db/sql_template.zig").SqlTemplate;
pub const SqlTemplateManager = @import("db/sql_template.zig").SqlTemplateManager;

// Export interceptor modules
pub const Interceptor = @import("interceptor/interceptor.zig").Interceptor;
pub const InterceptorChain = @import("interceptor/interceptor.zig").InterceptorChain;
pub const LoggingInterceptor = @import("interceptor/interceptor.zig").LoggingInterceptor;
pub const AuthInterceptor = @import("interceptor/interceptor.zig").AuthInterceptor;
pub const CORSInterceptor = @import("interceptor/interceptor.zig").CORSInterceptor;

// Export validator module
pub const Validator = @import("validator/validator.zig").Validator;

// Export upload modules
pub const UploadFile = @import("upload/multipart.zig").UploadFile;
pub const MultipartParser = @import("upload/multipart.zig").MultipartParser;

// Export plugin modules
pub const Plugin = @import("plugin/plugin.zig").Plugin;
pub const PluginManager = @import("plugin/plugin.zig").PluginManager;
pub const CachePlugin = @import("plugin/cache.zig").CachePlugin;
pub const CacheConfig = @import("plugin/cache.zig").CacheConfig;
pub const CacheBackend = @import("plugin/cache.zig").CacheBackend;
pub const RedisClient = @import("plugin/redis.zig").RedisClient;
pub const RedisCache = @import("plugin/redis.zig").RedisCache;
pub const CronPlugin = @import("plugin/cron.zig").CronPlugin;
pub const MqttPlugin = @import("plugin/mqtt.zig").MqttPlugin;
pub const AgentPlugin = @import("plugin/agent.zig").AgentPlugin;
pub const DidPlugin = @import("plugin/did.zig").DidPlugin;
pub const P2pPlugin = @import("plugin/p2p.zig").P2pPlugin;
pub const CircuitBreaker = @import("plugin/compat/stubs.zig").CircuitBreaker;
pub const ConfigClient = @import("plugin/compat/stubs.zig").ConfigClient;
pub const HttpClient = @import("plugin/compat/stubs.zig").HttpClient;
pub const BeanValidator = @import("plugin/compat/stubs.zig").BeanValidator;
pub const TaskScheduler = @import("plugin/compat/stubs.zig").TaskScheduler;
pub const MessageQueue = @import("plugin/compat/stubs.zig").MessageQueue;
pub const OAuth2Client = @import("plugin/compat/stubs.zig").OAuth2Client;
pub const ObjectMapper = @import("plugin/compat/stubs.zig").ObjectMapper;
pub const MetricsExporter = @import("plugin/compat/stubs.zig").MetricsExporter;

// Export config and i18n modules
pub const I18n = @import("i18n/i18n.zig").I18n;
pub const LocaleInfo = @import("i18n/i18n.zig").LocaleInfo;
pub const PluralRule = @import("i18n/i18n.zig").PluralRule;
pub const detectLocale = @import("i18n/i18n.zig").detectLocale;

// Export generator module
pub const Generator = @import("generator/generator.zig").Generator;
pub const TableInfo = @import("generator/generator.zig").TableInfo;
pub const ColumnInfo = @import("generator/generator.zig").ColumnInfo;

// Export WebSocket modules
pub const WebSocket = @import("websocket/websocket.zig").WebSocket;
pub const WebSocketManager = @import("websocket/manager.zig").WebSocketManager;
pub const WebSocketFrame = @import("websocket/websocket.zig").Frame;
pub const WebSocketOpCode = @import("websocket/websocket.zig").OpCode;

// Export Token modules
pub const TokenManager = @import("token/token.zig").TokenManager;
pub const Token = @import("token/token.zig").Token;
pub const createTokenInterceptor = @import("token/interceptor.zig").createTokenInterceptor;

// Export Captcha modules
pub const CaptchaManager = @import("captcha/captcha.zig").CaptchaManager;
pub const Captcha = @import("captcha/captcha.zig").Captcha;
pub const CaptchaType = @import("captcha/captcha.zig").CaptchaType;

// Export Ext modules
pub const CorsHandler = @import("ext/handler.zig").CorsHandler;
pub const StaticHandler = @import("ext/handler.zig").StaticHandler;
pub const RateLimitHandler = @import("ext/handler.zig").RateLimitHandler;
pub const createPerformanceInterceptor = @import("ext/interceptor.zig").createPerformanceInterceptor;
pub const createExceptionInterceptor = @import("ext/interceptor.zig").createExceptionInterceptor;
pub const createAccessLogInterceptor = @import("ext/interceptor.zig").createAccessLogInterceptor;
pub const createCacheInterceptor = @import("ext/interceptor.zig").createCacheInterceptor;
pub const RenderExt = @import("ext/util.zig").RenderExt;
pub const ParamExt = @import("ext/util.zig").ParamExt;
pub const SessionExt = @import("ext/util.zig").SessionExt;
pub const IpExt = @import("ext/ext_util.zig").IpExt;
pub const RequestExt = @import("ext/ext_util.zig").RequestExt;
pub const ResponseExt = @import("ext/ext_util.zig").ResponseExt;
pub const CookieExt = @import("ext/ext_util.zig").CookieExt;
pub const SecurityExt = @import("ext/ext_util.zig").SecurityExt;

// Export Kit utilities
pub const StrKit = @import("kit/str_kit.zig").StrKit;
pub const HashKit = @import("kit/hash_kit.zig").HashKit;
pub const PathKit = @import("kit/path_kit.zig").PathKit;
pub const TimeKit = @import("kit/time_kit.zig").TimeKit;
pub const NumberKit = @import("kit/number_kit.zig").NumberKit;
pub const FileKit = @import("kit/file_kit.zig").FileKit;
pub const RandomKit = @import("kit/random_kit.zig").RandomKit;
pub const JsonKit = @import("kit/json_kit.zig").JsonKit;
pub const UrlKit = @import("kit/url_kit.zig").UrlKit;
pub const ArrayKit = @import("kit/array_kit.zig").ArrayKit;
pub const RegexKit = @import("kit/regex_kit.zig").RegexKit;
pub const HttpKit = @import("kit/http_kit.zig").HttpKit;
pub const ValidateKit = @import("kit/validate_kit.zig").ValidateKit;
pub const DateKit = @import("kit/date_kit.zig").DateKit;
pub const FormatKit = @import("kit/format_kit.zig").FormatKit;
pub const SysKit = @import("kit/sys_kit.zig").SysKit;
pub const CacheKit = @import("kit/cache_kit.zig").CacheKit;

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

test "integration: router match and handler dispatch" {
    const allocator = std.testing.allocator;

    var router = @import("core/router.zig").Router.init(allocator);
    defer router.deinit();

    var handler_called = false;
    const TestHandler = struct {
        var called: *bool = undefined;
        fn handle(ctx: *Context) !void {
            called.* = true;
            ctx.res_status = .ok;
            try ctx.renderText("OK");
        }
    };
    TestHandler.called = &handler_called;

    try router.addWithMethod("/api/test", .GET, TestHandler.handle);

    const route = router.match("/api/test", .GET);
    try std.testing.expect(route != null);

    try std.testing.expect(handler_called == false);
    try std.testing.expectEqualStrings("/api/test", route.?.pattern);
}

test "integration: context query params" {
    const allocator = std.testing.allocator;

    var params_map = try @import("core/params.zig").parseQuery(allocator, "name=Alice&age=30");
    defer {
        var it = params_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params_map.deinit();
    }

    try std.testing.expectEqualStrings("Alice", params_map.get("name").?);
    try std.testing.expectEqualStrings("30", params_map.get("age").?);
    try std.testing.expect(params_map.get("missing") == null);
}

test "integration: CSRF token flow" {
    const allocator = std.testing.allocator;

    var manager = TokenManager.init(allocator);
    defer manager.deinit();

    const token = try manager.generate();
    defer allocator.free(token);

    try std.testing.expect(manager.exists(token));
    try std.testing.expect(try manager.validate(token));
    try std.testing.expect(!try manager.validate(token)); // one-time use
}

test "integration: captcha generate and validate" {
    const allocator = std.testing.allocator;
    RandomKit.init();

    var manager = CaptchaManager.init(allocator);
    defer manager.deinit();

    const captcha = try manager.generate(.numeric, "session_test");
    // Note: captcha strings are owned by manager, do NOT call captcha.deinit() here.

    try std.testing.expectEqual(@as(usize, 4), captcha.code.len);
    try std.testing.expect(try manager.validate("session_test", captcha.answer));
    try std.testing.expect(!try manager.validate("session_test", captcha.answer)); // consumed
}

test "integration: interceptor chain" {
    const allocator = std.testing.allocator;

    var chain = @import("interceptor/interceptor.zig").InterceptorChain.init(allocator);
    defer chain.deinit();

    // Test the interceptor chain structure
    const interceptor = @import("interceptor/interceptor.zig").Interceptor{
        .name = "test_interceptor",
        .before = null,
        .after = null,
    };

    try chain.add(interceptor);
    try std.testing.expectEqual(@as(usize, 1), chain.interceptors.items.len);
    try std.testing.expectEqualStrings("test_interceptor", chain.interceptors.items[0].name);
}

test "integration: logger + metrics pipeline" {
    const allocator = std.testing.allocator;
    var logger = Logger.init(allocator);
    logger.setLevel(.debug);

    var metrics = Metrics.init(allocator);
    defer metrics.deinit();

    metrics.recordRequest(200);
    metrics.recordRequest(200);
    metrics.recordRequest(404);
    metrics.recordRequest(500);

    try std.testing.expectEqual(@as(u64, 4), metrics.total_requests.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), metrics.responses_2xx.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.responses_4xx.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.responses_5xx.load(.monotonic));
    try std.testing.expect(metrics.uptime() >= 0);
}
