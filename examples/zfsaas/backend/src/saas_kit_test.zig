//! SaaS Kit domain tests (SQLite in-memory): auth, invite, cross-org, webhook idempotency.
const std = @import("std");
const zfinal = @import("zfinal");
const migrate = @import("migrate.zig");
const auth = @import("modules/auth/service.zig");
const org = @import("modules/org/service.zig");
const billing = @import("modules/billing/service.zig");
const todo = @import("modules/todo/service.zig");
const state = @import("state.zig");

const secret = "test-secret-at-least-32-bytes-long!!";

fn openDb() !*zfinal.DB {
    const db = try zfinal.DB.init(std.testing.allocator, zfinal.DBConfig.sqliteMemory());
    try migrate.migrate(db);
    return db;
}

test "saas-kit: sign-up and sign-in" {
    const a = std.testing.allocator;
    var db = try openDb();
    defer db.destroy();

    const up = try auth.signUp(db, a, "a@example.com", "Alice", "password1", secret, 3600);
    defer auth.freeAuthResult(a, up);
    try std.testing.expect(up.user_id > 0);
    try std.testing.expect(up.org_id != null);
    try std.testing.expect(up.token.len > 10);

    const inn = try auth.signIn(db, a, "a@example.com", "password1", secret, 3600);
    defer auth.freeAuthResult(a, inn);
    try std.testing.expectEqual(up.user_id, inn.user_id);
}

test "saas-kit: invite accept + todo cross-org reject" {
    const a = std.testing.allocator;
    var db = try openDb();
    defer db.destroy();

    const alice = try auth.signUp(db, a, "alice@ex.com", "Alice", "password1", secret, 3600);
    defer auth.freeAuthResult(a, alice);
    const bob = try auth.signUp(db, a, "bob@ex.com", "Bob", "password1", secret, 3600);
    defer auth.freeAuthResult(a, bob);

    const org_a = alice.org_id.?;
    var email = state.EmailSender{};
    const inv = try org.createInvite(db, a, org_a, "bob@ex.com", "member", alice.user_id, &email);
    defer a.free(inv.raw_token);

    const joined = try org.acceptInvite(db, a, bob.user_id, "bob@ex.com", inv.raw_token);
    defer a.free(joined);
    try std.testing.expectEqualStrings(org_a, joined);

    // Activate subscription for writes
    try db.execParams("UPDATE subscriptions SET status = 'active' WHERE org_id = ?", &.{.{ .text = org_a }});

    const t1 = try todo.createInOrg(db, "t1", "m", org_a, "1");
    try std.testing.expect(t1.id != null);

    // Bob's personal org must not see Alice's todo id
    const bob_org = bob.org_id.?;
    const miss = try todo.findByIdInOrg(db, a, t1.id.?, bob_org);
    try std.testing.expect(miss == null);
}

test "saas-kit: webhook idempotent" {
    const a = std.testing.allocator;
    var db = try openDb();
    defer db.destroy();

    const alice = try auth.signUp(db, a, "w@ex.com", "W", "password1", secret, 3600);
    defer auth.freeAuthResult(a, alice);
    const oid = alice.org_id.?;

    const o1 = try billing.handleWebhook(db, "evt_1", "customer.subscription.updated", oid, "active");
    try std.testing.expect(o1 == .processed);
    const o2 = try billing.handleWebhook(db, "evt_1", "customer.subscription.updated", oid, "active");
    try std.testing.expect(o2 == .duplicate);

    try billing.requireActiveSubscription(db, oid);
}

test "saas-kit: email verify + refresh rotation + revoke" {
    const a = std.testing.allocator;
    var db = try openDb();
    defer db.destroy();

    const up = try auth.signUp(db, a, "b@example.com", "Bob", "password1", secret, 3600);
    defer auth.freeAuthResult(a, up);
    try std.testing.expect(!up.email_verified);
    try std.testing.expect(up.verify_token != null);
    try std.testing.expect(up.refresh_token != null);

    // verify email
    try auth.verifyEmail(db, a, up.verify_token.?);
    const inn = try auth.signIn(db, a, "b@example.com", "password1", secret, 3600);
    defer auth.freeAuthResult(a, inn);
    try std.testing.expect(inn.email_verified);
    // verify token is single-use
    try std.testing.expectError(error.Gone, auth.verifyEmail(db, a, up.verify_token.?));

    // refresh rotation: old token becomes invalid, new one works
    const rf = try auth.refreshSession(db, a, up.refresh_token.?, secret, 3600);
    defer auth.freeAuthResult(a, rf);
    try std.testing.expect(rf.refresh_token != null);
    try std.testing.expectError(error.Unauthorized, auth.refreshSession(db, a, up.refresh_token.?, secret, 3600));

    // revoke new refresh
    try auth.revokeRefresh(db, a, rf.refresh_token.?);
    try std.testing.expectError(error.Unauthorized, auth.refreshSession(db, a, rf.refresh_token.?, secret, 3600));
}

test "saas-kit: cross-org access control (update/delete/list)" {
    const a = std.testing.allocator;
    var db = try openDb();
    defer db.destroy();

    const alice = try auth.signUp(db, a, "alice2@ex.com", "Alice", "password1", secret, 3600);
    defer auth.freeAuthResult(a, alice);
    const bob = try auth.signUp(db, a, "bob2@ex.com", "Bob", "password1", secret, 3600);
    defer auth.freeAuthResult(a, bob);

    try db.execParams("UPDATE subscriptions SET status = 'active' WHERE org_id = ?", &.{.{ .text = alice.org_id.? }});
    const t1 = try todo.createInOrg(db, "t1", "m", alice.org_id.?, "1");
    try std.testing.expect(t1.id != null);

    // Bob (different org) cannot update, delete, or list Alice's todo.
    try std.testing.expectError(error.NotFound, todo.updateInOrg(db, a, t1.id.?, bob.org_id.?, "x", null));
    try std.testing.expectError(error.NotFound, todo.deleteInOrg(db, a, t1.id.?, bob.org_id.?));

    const bob_list = try todo.listByOrg(db, a, bob.org_id.?, null);
    defer {
        for (bob_list) |*it| it.deinit(a);
        a.free(bob_list);
    }
    try std.testing.expectEqual(@as(usize, 0), bob_list.len);

    // Alice can still update her own.
    const upd = try todo.updateInOrg(db, a, t1.id.?, alice.org_id.?, "t1-updated", null);
    defer upd.deinit(a);
    try std.testing.expectEqualStrings("t1-updated", upd.data.title);
}
