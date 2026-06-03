const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSmsTemplates", handler.list);
    try app.get("/systemSmsTemplates/{id}", handler.show);
    try app.post("/systemSmsTemplates", handler.create);
    try app.put("/systemSmsTemplates/{id}", handler.update);
    try app.patch("/systemSmsTemplates/{id}", handler.patch);
    try app.delete("/systemSmsTemplates/{id}", handler.delete);
}
