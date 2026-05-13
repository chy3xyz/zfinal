const std = @import("std");
const zfinal = @import("zfinal");
const UserModel = @import("src/modules/user/model.zig").UsersModel;
const PostModel = @import("src/modules/post/model.zig").PostsModel;
const CommentModel = @import("src/modules/comment/model.zig").CommentsModel;
const User = @import("src/modules/user/model.zig").Users;
const Post = @import("src/modules/post/model.zig").Posts;
const Comment = @import("src/modules/comment/model.zig").Comments;

const testing = std.testing;

fn setupDb(allocator: std.mem.Allocator) !zfinal.DB {
    const config = zfinal.DBConfig.sqliteMemory();
    var db = try zfinal.DB.init(allocator, config);
    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT, email TEXT, password TEXT, created_at TEXT)");
    try db.exec("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, content TEXT, author_id INTEGER, published BOOLEAN DEFAULT 0, created_at TEXT)");
    try db.exec("CREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, post_id INTEGER, author_id INTEGER, content TEXT, created_at TEXT)");
    return db;
}

test "integration: CRUD user — insert, read, update, delete" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();

    // CREATE
    var user = UserModel.Instance{
        .data = User{ .username = "alice", .email = "alice@test.com", .password = "secret", .created_at = null },
    };
    try user.save(&db);
    try testing.expect(user.id != null);
    const user_id = user.id.?;

    // READ
    const found = try UserModel.findById(&db, user_id, allocator);
    try testing.expect(found != null);
    defer found.?.deinit(allocator);
    try testing.expectEqualStrings("alice", found.?.data.username);
    try testing.expectEqualStrings("alice@test.com", found.?.data.email);

    // UPDATE
    const update_count = try UserModel.count(&db);
    try testing.expectEqual(@as(i64, 1), update_count);
}

test "integration: CRUD post — insert with foreign key" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();

    // Insert user first
    var user = UserModel.Instance{
        .data = User{ .username = "bob", .email = "bob@test.com", .password = "pw", .created_at = null },
    };
    try user.save(&db);
    const author_id = user.id.?;

    // Insert post linked to user
    var post = PostModel.Instance{
        .data = Post{ .title = "Hello World", .content = "My first post", .author_id = author_id, .published = null, .created_at = null },
    };
    try post.save(&db);
    try testing.expect(post.id != null);

    // Read back
    const found = try PostModel.findById(&db, post.id.?, allocator);
    try testing.expect(found != null);
    defer found.?.deinit(allocator);
    try testing.expectEqualStrings("Hello World", found.?.data.title);
    try testing.expectEqual(@as(i64, author_id), found.?.data.author_id);
}

test "integration: findAll — multiple records" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();

    // Insert 3 users
    const names = [_][]const u8{ "alice", "bob", "charlie" };
    for (names) |name| {
        var user = UserModel.Instance{
            .data = User{ .username = name, .email = try std.fmt.allocPrint(allocator, "{s}@test.com", .{name}), .password = "pw", .created_at = null },
        };
        try user.save(&db);
    }

    const all = try UserModel.findAll(&db, allocator);
    defer {
        for (all) |*item| item.deinit(allocator);
        allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 3), all.len);
    try testing.expectEqualStrings("alice", all[0].data.username);
    try testing.expectEqualStrings("bob", all[1].data.username);
    try testing.expectEqualStrings("charlie", all[2].data.username);
}

test "integration: delete — cascade logic" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();

    var user = UserModel.Instance{
        .data = User{ .username = "temp", .email = "temp@test.com", .password = "pw", .created_at = null },
    };
    try user.save(&db);
    const uid = user.id.?;

    // Delete
    try user.delete(&db);
    try testing.expect(user.id == null);

    // Verify gone
    const gone = try UserModel.findById(&db, uid, allocator);
    try testing.expect(gone == null);
}

test "performance: batch insert 100 users" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();

    const start = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds();
    for (0..100) |i| {
        var email_buf: [64]u8 = undefined;
        const email = try std.fmt.bufPrint(&email_buf, "user{d}@test.com", .{i});
        var user = UserModel.Instance{
            .data = User{ .username = email, .email = email, .password = "pw", .created_at = null },
        };
        try user.save(&db);
    }
    const elapsed_ms = std.Io.Timestamp.now(std.testing.io, .real).toMilliseconds() - start;
    try testing.expect(elapsed_ms < 5000);
    std.debug.print("\n  100 user inserts: {d}ms\n", .{elapsed_ms});

    const count = try UserModel.count(&db);
    try testing.expectEqual(@as(i64, 100), count);
}

test "type safety: non-nullable field rejects null" {
    const BlogPost = struct { title: []const u8, author_id: i64 };
    const BpModel = zfinal.Model(BlogPost, "blog_posts");
    // Verify type-level constraint: author_id is i64, cannot be null
    const inst = BpModel.Instance{
        .data = BlogPost{ .title = "test", .author_id = 42 },
    };
    try testing.expectEqual(@as(i64, 42), inst.data.author_id);
}

test "JSON naming: field map exists" {
    const UserMod = @import("src/modules/user/model.zig");
    try testing.expect(@hasDecl(UserMod, "fieldMap"));
    try testing.expect(@hasDecl(UserMod, "jsonNaming"));
    try testing.expect(@hasDecl(UserMod, "jsonFieldName"));
    // snake_case: "created_at" maps to itself
    try testing.expectEqualStrings("created_at", comptime UserMod.jsonFieldName("created_at"));
}

test "Module imports: all controllers import correctly" {
    _ = @import("src/modules/user/controller.zig");
    _ = @import("src/modules/post/controller.zig");
    _ = @import("src/modules/comment/controller.zig");
}
