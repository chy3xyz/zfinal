//! Preserve `ai-edit-zone` bodies when regenerating files.
//!
//! Recognizes Zig (`// ── ai-edit-zone: name`) and HTML
//! (`<!-- ── ai-edit-zone: name`) markers. Zone *names* must match between
//! the existing file and the newly generated content; bodies from the
//! existing file win. Duplicate zone names (e.g. one `business rules` zone
//! per generated create method) are matched **by order of appearance**, so
//! hand-written bodies stay attached to the same slot after regeneration.
const std = @import("std");

const zone_open = "ai-edit-zone:";
const zone_close = "end ai-edit-zone";

/// One hand-edited zone, in file order.
const ZoneEntry = struct {
    name: []const u8, // owned (caller frees)
    block: []const u8, // borrowed from the source slice
};

/// Merge hand-edited zones from `existing` into `generated`.
/// Returns owned merged text when ≥1 zone was preserved; otherwise `null`
/// (caller should fall back to `.gen.new`).
pub fn mergeAiEditZones(
    allocator: std.mem.Allocator,
    existing: []const u8,
    generated: []const u8,
) !?[]u8 {
    var old_zones: std.ArrayList(ZoneEntry) = .empty;
    defer {
        for (old_zones.items) |e| allocator.free(e.name);
        old_zones.deinit(allocator);
    }
    try collectZones(allocator, existing, &old_zones);
    if (old_zones.items.len == 0) return null;

    // name → how many zones with this name we already consumed in `generated`.
    var name_idx = std.StringHashMap(usize).init(allocator);
    defer name_idx.deinit();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var preserved: u32 = 0;
    var pos: usize = 0;
    while (pos < generated.len) {
        const start = findZoneStart(generated, pos) orelse {
            try out.appendSlice(allocator, generated[pos..]);
            break;
        };
        try out.appendSlice(allocator, generated[pos..start]);
        const open_at = std.mem.indexOf(u8, generated[start..], zone_open) orelse {
            try out.append(allocator, generated[start]);
            pos = start + 1;
            continue;
        };
        const name = parseZoneName(generated[start + open_at ..]) orelse {
            try out.append(allocator, generated[start]);
            pos = start + 1;
            continue;
        };
        const end = findZoneEnd(generated, start) orelse {
            try out.appendSlice(allocator, generated[start..]);
            break;
        };
        const end_line = lineEnd(generated, end);
        if (findZoneMatch(&old_zones, &name_idx, name)) |old_block| {
            try out.appendSlice(allocator, old_block);
            preserved += 1;
        } else {
            try out.appendSlice(allocator, generated[start..end_line]);
        }
        pos = end_line;
    }

    if (preserved == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// Return the next unconsumed `block` for `name` from `old_zones` (order of
/// appearance), or null when no more matches exist.
fn findZoneMatch(
    old_zones: *const std.ArrayList(ZoneEntry),
    name_idx: *std.StringHashMap(usize),
    name: []const u8,
) ?[]const u8 {
    const gop = name_idx.getOrPut(name) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const want = gop.value_ptr.*;
    gop.value_ptr.* += 1;
    var seen: usize = 0;
    for (old_zones.items) |e| {
        if (std.mem.eql(u8, e.name, name)) {
            if (seen == want) return e.block;
            seen += 1;
        }
    }
    return null;
}

fn collectZones(
    allocator: std.mem.Allocator,
    src: []const u8,
    list: *std.ArrayList(ZoneEntry),
) !void {
    var pos: usize = 0;
    while (pos < src.len) {
        const start = findZoneStart(src, pos) orelse break;
        const open_at = std.mem.indexOf(u8, src[start..], zone_open) orelse break;
        const name = parseZoneName(src[start + open_at ..]) orelse {
            pos = start + 1;
            continue;
        };
        const end = findZoneEnd(src, start) orelse break;
        const end_line = lineEnd(src, end);
        const block = src[start..end_line];
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        try list.append(allocator, .{ .name = key, .block = block });
        pos = end_line;
    }
}

fn findZoneStart(src: []const u8, from: usize) ?usize {
    if (std.mem.indexOf(u8, src[from..], zone_open)) |rel| {
        return lineStart(src, from + rel);
    }
    return null;
}

fn findZoneEnd(src: []const u8, from: usize) ?usize {
    if (std.mem.indexOf(u8, src[from..], zone_close)) |rel| return from + rel;
    return null;
}

fn parseZoneName(after_open_keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, after_open_keyword, zone_open)) return null;
    var s = after_open_keyword[zone_open.len..];
    const nl = std.mem.indexOfAny(u8, s, "\r\n") orelse s.len;
    s = std.mem.trim(u8, s[0..nl], " \t");
    // Strip trailing filler: spaces, ASCII '-', UTF-8 box-drawing '─' (U+2500).
    while (s.len > 0) {
        const c = s[s.len - 1];
        if (c == ' ' or c == '\t' or c == '-') {
            s = s[0 .. s.len - 1];
            continue;
        }
        if (s.len >= 3 and s[s.len - 3] == 0xe2 and s[s.len - 2] == 0x94 and s[s.len - 1] == 0x80) {
            s = s[0 .. s.len - 3];
            continue;
        }
        break;
    }
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return null;
    return s;
}

fn lineStart(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0 and src[i - 1] != '\n') : (i -= 1) {}
    return i;
}

fn lineEnd(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    if (i < src.len and src[i] == '\n') i += 1;
    return i;
}

test "mergeAiEditZones preserves named body" {
    const allocator = std.testing.allocator;
    const existing =
        \\// header
        \\// ── ai-edit-zone: business rules ──
        \\    try validate(x);
        \\// ── end ai-edit-zone ──
        \\// footer
        \\
    ;
    const generated =
        \\// header v2
        \\// ── ai-edit-zone: business rules ──
        \\    // TODO
        \\// ── end ai-edit-zone ──
        \\// footer v2
        \\
    ;
    const merged = try mergeAiEditZones(allocator, existing, generated);
    defer if (merged) |m| allocator.free(m);
    try std.testing.expect(merged != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "try validate(x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "header v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "footer v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "// TODO") == null);
}

test "mergeAiEditZones returns null without matching zones" {
    const allocator = std.testing.allocator;
    const existing = "// no zones\n";
    const generated =
        \\// ── ai-edit-zone: hooks ──
        \\// ── end ai-edit-zone ──
        \\
    ;
    const merged = try mergeAiEditZones(allocator, existing, generated);
    try std.testing.expect(merged == null);
}

test "mergeAiEditZones keeps new zones from generated" {
    const allocator = std.testing.allocator;
    const existing =
        \\// ── ai-edit-zone: old ──
        \\HAND
        \\// ── end ai-edit-zone ──
        \\
    ;
    const generated =
        \\// ── ai-edit-zone: old ──
        \\TODO
        \\// ── end ai-edit-zone ──
        \\// ── ai-edit-zone: new ──
        \\FRESH
        \\// ── end ai-edit-zone ──
        \\
    ;
    const merged = try mergeAiEditZones(allocator, existing, generated);
    defer if (merged) |m| allocator.free(m);
    try std.testing.expect(merged != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "HAND") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "FRESH") != null);
}

test "mergeAiEditZones pairs duplicate zone names by order" {
    const allocator = std.testing.allocator;
    const existing =
        \\// ── ai-edit-zone: business rules ──
        \\    check(follower_id);
        \\// ── end ai-edit-zone ──
        \\// ── ai-edit-zone: business rules ──
        \\    check(user_id);
        \\// ── end ai-edit-zone ──
        \\
    ;
    const generated =
        \\// ── ai-edit-zone: business rules ──
        \\    // TODO A
        \\// ── end ai-edit-zone ──
        \\// ── ai-edit-zone: business rules ──
        \\    // TODO B
        \\// ── end ai-edit-zone ──
        \\
    ;
    const merged = try mergeAiEditZones(allocator, existing, generated);
    defer if (merged) |m| allocator.free(m);
    try std.testing.expect(merged != null);
    // first slot gets the first old body, second slot the second old body
    const first_pos = std.mem.indexOf(u8, merged.?, "check(follower_id);").?;
    const second_pos = std.mem.indexOf(u8, merged.?, "check(user_id);").?;
    try std.testing.expect(first_pos < second_pos);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "// TODO A") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged.?, "// TODO B") == null);
}
