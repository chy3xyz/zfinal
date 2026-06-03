const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemDictDatas", handler.list);
    try app.get("/systemDictDatas/{id}", handler.show);
    try app.post("/systemDictDatas", handler.create);
    try app.put("/systemDictDatas/{id}", handler.update);
    try app.patch("/systemDictDatas/{id}", handler.patch);
    try app.delete("/systemDictDatas/{id}", handler.delete);
}
