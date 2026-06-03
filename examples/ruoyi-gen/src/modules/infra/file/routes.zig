const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraFiles", handler.list);
    try app.get("/infraFiles/{id}", handler.show);
    try app.post("/infraFiles", handler.create);
    try app.put("/infraFiles/{id}", handler.update);
    try app.patch("/infraFiles/{id}", handler.patch);
    try app.delete("/infraFiles/{id}", handler.delete);
}
