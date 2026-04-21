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
pub const AsyncServer = @import("core/async_server.zig").AsyncServer;
pub const AsyncServerConfig = @import("core/async_server.zig").AsyncServerConfig;
// Export database modules
pub const DB = @import("db/db.zig").DB;
pub const DBConfig = @import("db/config.zig").DBConfig;
pub const DBType = @import("db/config.zig").DBType;
pub const ResultSet = @import("db/result.zig").ResultSet;
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
