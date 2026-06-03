const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemNotifyTemplates", handler.list);
    try app.get("/systemNotifyTemplates/{id}", handler.show);
    try app.post("/systemNotifyTemplates", handler.create);
    try app.put("/systemNotifyTemplates/{id}", handler.update);
    try app.patch("/systemNotifyTemplates/{id}", handler.patch);
    try app.delete("/systemNotifyTemplates/{id}", handler.delete);
}
