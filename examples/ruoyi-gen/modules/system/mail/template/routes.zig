const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemMailTemplates", handler.list);
    try app.get("/systemMailTemplates/{id}", handler.show);
    try app.post("/systemMailTemplates", handler.create);
    try app.put("/systemMailTemplates/{id}", handler.update);
    try app.patch("/systemMailTemplates/{id}", handler.patch);
    try app.delete("/systemMailTemplates/{id}", handler.delete);
}
