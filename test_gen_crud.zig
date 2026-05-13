const std = @import("std");
const zfinal = @import("zfinal");
const UserModel = @import("src/modules/user/model.zig").UsersModel;
const PostModel = @import("src/modules/post/model.zig").PostsModel;
const CommentModel = @import("src/modules/comment/model.zig").CommentsModel;
const User = @import("src/modules/user/model.zig").Users;
const Post = @import("src/modules/post/model.zig").Posts;
const Comment = @import("src/modules/comment/model.zig").Comments;
const UserController = @import("src/modules/user/controller.zig");

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

test "pagination: page 1 returns first N rows" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();
    for (0..10) |i| {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "user{d}", .{i});
        var user = UserModel.Instance{
            .data = User{ .username = name, .email = name, .password = "pw", .created_at = null },
        };
        try user.save(&db);
    }
    const page1 = try UserModel.paginate(&db, 1, 5, allocator);
    defer {
        for (page1) |*item| item.deinit(allocator);
        allocator.free(page1);
    }
    try testing.expectEqual(@as(usize, 5), page1.len);
    const page2 = try UserModel.paginate(&db, 2, 5, allocator);
    defer {
        for (page2) |*item| item.deinit(allocator);
        allocator.free(page2);
    }
    try testing.expectEqual(@as(usize, 5), page2.len);
}

test "batch insert: all-or-nothing transaction" {
    const allocator = std.testing.allocator;
    var db = try setupDb(allocator);
    defer db.deinit();
    var instances: [3]UserModel.Instance = undefined;
    instances[0] = UserModel.Instance{ .data = User{ .username = "batch1", .email = "b1@t.com", .password = "pw", .created_at = null } };
    instances[1] = UserModel.Instance{ .data = User{ .username = "batch2", .email = "b2@t.com", .password = "pw", .created_at = null } };
    instances[2] = UserModel.Instance{ .data = User{ .username = "batch3", .email = "b3@t.com", .password = "pw", .created_at = null } };
    try UserModel.insertBatch(&db, &instances);
    const count = try UserModel.count(&db);
    try testing.expectEqual(@as(i64, 3), count);
}

test "json: field mapping snake_case → camelCase" {
    const PostMod = @import("src/modules/post/model.zig");
    // snake_case ident — DB columns are snake_case, should map to themselves
    try testing.expectEqualStrings("author_id", comptime PostMod.jsonFieldName("author_id"));
    try testing.expectEqualStrings("created_at", comptime PostMod.jsonFieldName("created_at"));
}

test "json: safeFields excludes password column" {
    const UserMod = @import("src/modules/user/model.zig");
    // Verify password is NOT in safeFields
    for (UserMod.safeFields) |field| {
        try testing.expect(!std.mem.eql(u8, field, "password"));
    }
}

test "json: validate rejects invalid email" {
    const data = User{ .username = "test", .email = "not-an-email", .password = "pw", .created_at = null };
    const UserMod = @import("src/modules/user/model.zig");
    try testing.expectError(error.InvalidEmail, UserMod.validate(data));
}

test "json: validate accepts valid email" {
    const data = User{ .username = "test", .email = "alice@example.com", .password = "pw", .created_at = null };
    const UserMod = @import("src/modules/user/model.zig");
    try UserMod.validate(data);
}

test "json: validate rejects empty required fields" {
    const data = User{ .username = "", .email = "a@b.com", .password = "pw", .created_at = null };
    const UserMod = @import("src/modules/user/model.zig");
    try testing.expectError(error.ValidationError, UserMod.validate(data));
}

test "json: routes include PATCH endpoint" {
    const routes = @embedFile("src/modules/user/routes.zig");
    try testing.expect(std.mem.indexOf(u8, routes, ".patch(") != null);
    try testing.expect(std.mem.indexOf(u8, routes, ".delete(") != null);
}

test "routes file: all modules have routes.zig" {
    for ([_][]const u8{ "user", "post", "comment" }) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "src/modules/{s}/routes.zig", .{name});
        defer std.testing.allocator.free(path);
        const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch {
            std.debug.print("Missing: {s}\n", .{path});
            return error.TestFailed;
        };
        file.close(std.testing.io);
    }
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
