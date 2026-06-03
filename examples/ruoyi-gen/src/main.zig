const std = @import("std");
const zfinal = @import("zfinal");
const App = @import("App.zig").App;
const config = @import("config.zig");
const routes = @import("routes.zig");

pub fn main(init: std.process.Init) !void {
    zfinal.io_instance.init(init);
    const allocator = init.gpa;

    var logger = zfinal.Logger.init(allocator);
    logger.setLevel(switch (zfinal.LOG_LEVEL) {
        .debug => .debug,
        .info  => .info,
        .warn  => .warn,
        .err   => .err,
    });
    logger.prefix = "app";
    zfinal.initGlobalLogger(logger);

    // Assemble app
    var app = try App.init(allocator, config.database, config.server);
    defer app.deinit();

    // Register routes
    try routes.register(&app);

    // Start
    zfinal.getLogger().infoFmt("starting on :{d}", .{config.server.port});
    try app.start();
}