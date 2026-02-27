const std = @import("std");

/// Validator for request data validation (JFinal-style)
pub const Validator = struct {
    errors: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Validator {
        return Validator{
            .errors = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Validator) void {
        var iter = self.errors.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.errors.deinit();
    }

    /// Check if there are any validation errors
    pub fn hasErrors(self: *const Validator) bool {
        return self.errors.count() > 0;
    }

    /// Get all errors as a map
    pub fn getErrors(self: *const Validator) std.StringHashMap([]const u8) {
        return self.errors;
    }

    /// Add a validation error
    fn addError(self: *Validator, field: []const u8, message: []const u8) !void {
        const field_copy = try self.allocator.dupe(u8, field);
        const message_copy = try self.allocator.dupe(u8, message);
        try self.errors.put(field_copy, message_copy);
    }

    /// Custom JSON serialization
    pub fn jsonStringify(self: Validator, writer: anytype) !void {
        try writer.beginObject();
        var it = self.errors.iterator();
        while (it.next()) |entry| {
            try writer.objectField(entry.key_ptr.*);
            try writer.write(entry.value_ptr.*);
        }
        try writer.endObject();
    }

    // === Validation Rules ===

    /// Validate required field
    pub fn validateRequired(self: *Validator, field: []const u8, value: ?[]const u8) !void {
        if (value == null or value.?.len == 0) {
            try self.addError(field, "This field is required");
        }
    }

    /// Validate email format
    pub fn validateEmail(self: *Validator, field: []const u8, value: ?[]const u8) !void {
        if (value) |v| {
            if (v.len == 0) return;

            // Simple email validation
            const has_at = std.mem.indexOfScalar(u8, v, '@') != null;
            const has_dot = std.mem.indexOfScalar(u8, v, '.') != null;

            if (!has_at or !has_dot) {
                try self.addError(field, "Invalid email format");
            }
        }
    }

    /// Validate integer range
    pub fn validateRange(self: *Validator, field: []const u8, value: ?i32, min: i32, max: i32) !void {
        if (value) |v| {
            if (v < min or v > max) {
                var buf: [128]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Value must be between {d} and {d}", .{ min, max });
                try self.addError(field, msg);
            }
        }
    }

    /// Validate minimum length
    pub fn validateMinLength(self: *Validator, field: []const u8, value: ?[]const u8, min_len: usize) !void {
        if (value) |v| {
            if (v.len < min_len) {
                var buf: [128]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Minimum length is {d} characters", .{min_len});
                try self.addError(field, msg);
            }
        }
    }

    /// Validate maximum length
    pub fn validateMaxLength(self: *Validator, field: []const u8, value: ?[]const u8, max_len: usize) !void {
        if (value) |v| {
            if (v.len > max_len) {
                var buf: [128]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Maximum length is {d} characters", .{max_len});
                try self.addError(field, msg);
            }
        }
    }

    /// Validate regex pattern (simplified)
    pub fn validatePattern(self: *Validator, field: []const u8, value: ?[]const u8, pattern: []const u8) !void {
        _ = pattern; // TODO: Implement regex matching
        if (value) |_| {
            // Placeholder for regex validation
            // In a real implementation, you'd use a regex library
        } else {
            try self.addError(field, "Value does not match pattern");
        }
    }

    /// Validate that value matches another field (e.g., password confirmation)
    pub fn validateMatch(self: *Validator, field: []const u8, value: ?[]const u8, other_value: ?[]const u8, other_field: []const u8) !void {
        if (value == null or other_value == null) return;

        if (!std.mem.eql(u8, value.?, other_value.?)) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Must match {s}", .{other_field});
            try self.addError(field, msg);
        }
    }

    /// Validate numeric value
    pub fn validateNumeric(self: *Validator, field: []const u8, value: ?[]const u8) !void {
        if (value) |v| {
            if (v.len == 0) return;

            for (v) |c| {
                if (c < '0' or c > '9') {
                    try self.addError(field, "Must be numeric");
                    return;
                }
            }
        }
    }

    /// Validate alpha (letters only)
    pub fn validateAlpha(self: *Validator, field: []const u8, value: ?[]const u8) !void {
        if (value) |v| {
            if (v.len == 0) return;

            for (v) |c| {
                if (!std.ascii.isAlphabetic(c)) {
                    try self.addError(field, "Must contain only letters");
                    return;
                }
            }
        }
    }

    /// Validate alphanumeric
    pub fn validateAlphanumeric(self: *Validator, field: []const u8, value: ?[]const u8) !void {
        if (value) |v| {
            if (v.len == 0) return;

            for (v) |c| {
                if (!std.ascii.isAlphanumeric(c)) {
                    try self.addError(field, "Must contain only letters and numbers");
                    return;
                }
            }
        }
    }

    /// Custom validation with callback
    pub fn validateCustom(self: *Validator, field: []const u8, value: anytype, validator_fn: *const fn (@TypeOf(value)) bool, message: []const u8) !void {
        if (!validator_fn(value)) {
            try self.addError(field, message);
        }
    }
};

test "validator required" {
    const allocator = std.testing.allocator;

    var v = Validator.init(allocator);
    defer v.deinit();

    try v.validateRequired("name", null);
    try std.testing.expect(v.hasErrors());

    const errors = v.getErrors();
    try std.testing.expect(errors.get("name") != null);
}

test "validator email" {
    const allocator = std.testing.allocator;

    var v = Validator.init(allocator);
    defer v.deinit();

    try v.validateEmail("email", "invalid");
    try std.testing.expect(v.hasErrors());
}

test "validator range" {
    const allocator = std.testing.allocator;

    var v = Validator.init(allocator);
    defer v.deinit();

    try v.validateRange("age", 150, 0, 120);
    try std.testing.expect(v.hasErrors());
}

test "validator min length" {
    const allocator = std.testing.allocator;

    var v = Validator.init(allocator);
    defer v.deinit();

    try v.validateMinLength("password", "123", 6);
    try std.testing.expect(v.hasErrors());
}
