const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/systemSocialUsers", handler.list);
    try app.get("/systemSocialUsers/{id}", handler.show);
    try app.post("/systemSocialUsers", handler.create);
    try app.put("/systemSocialUsers/{id}", handler.update);
    try app.patch("/systemSocialUsers/{id}", handler.patch);
    try app.delete("/systemSocialUsers/{id}", handler.delete);
}
