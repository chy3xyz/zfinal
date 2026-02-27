const std = @import("std");
const zfinal = @import("zfinal");
const IndexController = @import("../controller/index_controller.zig").IndexController;
const UserController = @import("../controller/user_controller.zig").UserController;
const PostController = @import("../controller/post_controller.zig").PostController;
const CommentController = @import("../controller/comment_controller.zig").CommentController;

/// 配置所有路由
pub fn configRoutes(app: *zfinal.ZFinal) !void {
    // 首页
    try app.get("/", IndexController.index);

    // 用户路由
    try app.get("/api/users", UserController.index);
    try app.get("/api/users/:id", UserController.show);
    try app.post("/api/users", UserController.create);

    // 文章路由（RESTful）
    try app.get("/api/posts", PostController.index);
    try app.get("/api/posts/:id", PostController.show);
    try app.post("/api/posts", PostController.create);
    try app.put("/api/posts/:id", PostController.update);
    try app.delete("/api/posts/:id", PostController.delete);

    // 评论路由
    try app.get("/api/posts/:post_id/comments", CommentController.index);
    try app.post("/api/posts/:post_id/comments", CommentController.create);
}
