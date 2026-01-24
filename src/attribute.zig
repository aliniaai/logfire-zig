//! OTLP attribute types
//!
//! converts zig values to OTLP-compatible attribute format.
//! string values are copied into internal storage for memory safety.

const std = @import("std");

pub const Attribute = struct {
    key: []const u8,
    value: Value,
    /// internal storage for copied strings
    _string_storage: [max_string_len]u8 = undefined,
    _string_len: usize = 0,

    pub const max_string_len = 512;

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool_val: bool,
    };

    /// copy a string into internal storage and return slice pointing to it
    fn copyString(self: *Attribute, str: []const u8) []const u8 {
        const len = @min(str.len, max_string_len);
        @memcpy(self._string_storage[0..len], str[0..len]);
        self._string_len = len;
        return self._string_storage[0..len];
    }

    /// convert a comptime struct to attributes array
    /// returns number of attributes written
    /// string values are copied for memory safety
    pub fn fromStruct(attrs: anytype, out: []Attribute) usize {
        const T = @TypeOf(attrs);
        const info = @typeInfo(T);

        if (info != .@"struct") return 0;

        const fields = info.@"struct".fields;
        var count: usize = 0;

        inline for (fields) |field| {
            if (count >= out.len) break;

            const field_value = @field(attrs, field.name);
            if (toValueWithCopy(&out[count], field.name, field_value)) {
                count += 1;
            }
        }

        return count;
    }

    /// convert value and copy strings into attribute's internal storage
    fn toValueWithCopy(attr: *Attribute, key: []const u8, value: anytype) bool {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        switch (info) {
            .int, .comptime_int => {
                attr.* = .{ .key = key, .value = .{ .int = @intCast(value) } };
                return true;
            },
            .float, .comptime_float => {
                attr.* = .{ .key = key, .value = .{ .float = @floatCast(value) } };
                return true;
            },
            .bool => {
                attr.* = .{ .key = key, .value = .{ .bool_val = value } };
                return true;
            },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    // copy the string into internal storage
                    attr.* = .{ .key = key, .value = undefined };
                    const copied = attr.copyString(value);
                    attr.value = .{ .string = copied };
                    return true;
                }
                if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        attr.* = .{ .key = key, .value = undefined };
                        const copied = attr.copyString(value);
                        attr.value = .{ .string = copied };
                        return true;
                    }
                }
                return false;
            },
            .array => |arr| {
                if (arr.child == u8) {
                    attr.* = .{ .key = key, .value = undefined };
                    const copied = attr.copyString(&value);
                    attr.value = .{ .string = copied };
                    return true;
                }
                return false;
            },
            .optional => {
                if (value) |v| {
                    return toValueWithCopy(attr, key, v);
                }
                return false;
            },
            else => return false,
        }
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
