const std = @import("std");
const Validator = @import("../validator/validator.zig").Validator;

/// Fluent bean-style validator wrapping `zfinal.Validator`.
pub const BeanValidator = struct {
    inner: Validator,
    allocator: std.mem.Allocator,

    pub const FieldError = struct { field: []const u8, message: []const u8 };

    pub fn init(allocator: std.mem.Allocator) BeanValidator {
        return .{ .inner = Validator.init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *BeanValidator) void {
        self.inner.deinit();
    }

    pub fn require(self: *BeanValidator, field: []const u8, value: ?[]const u8) !void {
        try self.inner.validateRequired(field, value);
    }

    pub fn email(self: *BeanValidator, field: []const u8, value: ?[]const u8) !void {
        try self.inner.validateEmail(field, value);
    }

    pub fn length(self: *BeanValidator, field: []const u8, value: ?[]const u8, min: usize, max: usize) !void {
        try self.inner.validateMinLength(field, value, min);
        try self.inner.validateMaxLength(field, value, max);
    }

    pub fn range(self: *BeanValidator, field: []const u8, value: ?i32, min: i32, max: i32) !void {
        try self.inner.validateRange(field, value, min, max);
    }

    /// Returns true when all accumulated checks passed.
    pub fn validate(self: *BeanValidator) bool {
        return !self.inner.hasErrors();
    }

    pub fn hasErrors(self: *const BeanValidator) bool {
        return self.inner.hasErrors();
    }

    /// Snapshot errors into an owned slice (caller frees fields via `freeErrors`).
    pub fn getErrors(self: *BeanValidator) ![]FieldError {
        var list: std.ArrayList(FieldError) = .empty;
        errdefer list.deinit(self.allocator);
        var it = self.inner.errors.iterator();
        while (it.next()) |e| {
            try list.append(self.allocator, .{
                .field = try self.allocator.dupe(u8, e.key_ptr.*),
                .message = try self.allocator.dupe(u8, e.value_ptr.*),
            });
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn freeErrors(self: *BeanValidator, errors: []FieldError) void {
        for (errors) |e| {
            self.allocator.free(e.field);
            self.allocator.free(e.message);
        }
        self.allocator.free(errors);
    }
};

test "bean validator: require and email" {
    const a = std.testing.allocator;
    var v = BeanValidator.init(a);
    defer v.deinit();
    try v.require("name", null);
    try v.email("email", "not-an-email");
    try std.testing.expect(!v.validate());
    const errs = try v.getErrors();
    defer v.freeErrors(errs);
    try std.testing.expect(errs.len >= 2);
}
