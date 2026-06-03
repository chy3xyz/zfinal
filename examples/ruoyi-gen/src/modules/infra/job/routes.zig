const handler = @import("handler.gen.zig");

pub fn register(app: anytype) !void {
    try app.get("/infraJobs", handler.list);
    try app.get("/infraJobs/{id}", handler.show);
    try app.post("/infraJobs", handler.create);
    try app.put("/infraJobs/{id}", handler.update);
    try app.patch("/infraJobs/{id}", handler.patch);
    try app.delete("/infraJobs/{id}", handler.delete);
}
