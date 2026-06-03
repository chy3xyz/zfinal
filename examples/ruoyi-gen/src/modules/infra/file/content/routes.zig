const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraFileContents", handler.list);
    try app.get("/infraFileContents/{id}", handler.show);
    try app.post("/infraFileContents", handler.create);
    try app.put("/infraFileContents/{id}", handler.update);
    try app.patch("/infraFileContents/{id}", handler.patch);
    try app.delete("/infraFileContents/{id}", handler.delete);
}
