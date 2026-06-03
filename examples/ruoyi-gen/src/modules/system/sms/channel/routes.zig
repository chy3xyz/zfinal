const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSmsChannels", handler.list);
    try app.get("/systemSmsChannels/{id}", handler.show);
    try app.post("/systemSmsChannels", handler.create);
    try app.put("/systemSmsChannels/{id}", handler.update);
    try app.patch("/systemSmsChannels/{id}", handler.patch);
    try app.delete("/systemSmsChannels/{id}", handler.delete);
}
