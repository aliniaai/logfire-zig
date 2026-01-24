//! OTLP attribute types
//!
//! converts zig values to OTLP-compatible attribute format.

const std = @import("std");

pub const Attribute = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool_val: bool,
    };

    /// convert a comptime struct to attributes array
    /// returns number of attributes written
    pub fn fromStruct(attrs: anytype, out: []Attribute) usize {
        const T = @TypeOf(attrs);
        const info = @typeInfo(T);

        if (info != .@"struct") return 0;

        const fields = info.@"struct".fields;
        var count: usize = 0;

        inline for (fields) |field| {
            if (count >= out.len) break;

            const field_value = @field(attrs, field.name);
            if (toValue(field_value)) |value| {
                out[count] = .{
                    .key = field.name,
                    .value = value,
                };
                count += 1;
            }
        }

        return count;
    }

    /// convert a zig value to an attribute value
    fn toValue(value: anytype) ?Value {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        return switch (info) {
            .int, .comptime_int => .{ .int = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            .bool => .{ .bool_val = value },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    return .{ .string = value };
                }
                if (ptr.size == .one) {
                    // pointer to array (e.g., *const [N]u8)
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        return .{ .string = value };
                    }
                }
                return null;
            },
            .array => |arr| {
                if (arr.child == u8) {
                    return .{ .string = &value };
                }
                return null;
            },
            .optional => {
                if (value) |v| {
                    return toValue(v);
                }
                return null;
            },
            else => null,
        };
    }

    /// write attribute as OTLP JSON
    pub fn writeJson(self: Attribute, w: anytype) !void {
        try w.writeAll("{\"key\":");
        try writeJsonString(w, self.key);
        try w.writeAll(",\"value\":{");

        switch (self.value) {
            .string => |s| {
                try w.writeAll("\"stringValue\":");
                try writeJsonString(w, s);
            },
            .int => |i| {
                try w.print("\"intValue\":\"{d}\"", .{i});
            },
            .float => |f| {
                try w.print("\"doubleValue\":{d}", .{f});
            },
            .bool_val => |b| {
                try w.print("\"boolValue\":{}", .{b});
            },
        }

        try w.writeAll("}}");
    }
};

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u00{x:0>2}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// tests

test "fromStruct basic" {
    var attrs: [8]Attribute = undefined;
    const count = Attribute.fromStruct(.{
        .name = "test",
        .count = @as(i64, 42),
        .enabled = true,
    }, &attrs);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("name", attrs[0].key);
    try std.testing.expectEqualStrings("test", attrs[0].value.string);
    try std.testing.expectEqual(@as(i64, 42), attrs[1].value.int);
    try std.testing.expectEqual(true, attrs[2].value.bool_val);
}

test "writeJson string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const attr = Attribute{ .key = "foo", .value = .{ .string = "bar" } };
    try attr.writeJson(fbs.writer());
    try std.testing.expectEqualStrings("{\"key\":\"foo\",\"value\":{\"stringValue\":\"bar\"}}", fbs.getWritten());
}
