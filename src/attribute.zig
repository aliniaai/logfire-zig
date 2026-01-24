//! OTLP attribute types
//!
//! converts zig values to OTLP-compatible attribute format.
//! string values are copied into internal storage for memory safety.
//!
//! NOTE: string values are stored in _string_storage, NOT as a slice in Value.
//! this is intentional - zig's struct copy semantics would leave dangling pointers
//! if we stored a slice pointing to _string_storage. instead, we store the length
//! and reconstruct the slice via getString() when needed.

const std = @import("std");

pub const Attribute = struct {
    key: []const u8,
    value: Value,
    /// internal storage for copied strings
    _string_storage: [max_string_len]u8 = undefined,
    _string_len: usize = 0,

    pub const max_string_len = 512;

    /// value types - NOTE: string payload is in _string_storage, not here
    /// this ensures correct behavior when Attribute is copied
    pub const Value = union(enum) {
        string, // string data is in _string_storage[0.._string_len]
        int: i64,
        float: f64,
        bool_val: bool,
    };

    /// get string value - reconstructs slice from internal storage
    /// returns null if value is not a string
    pub fn getString(self: *const Attribute) ?[]const u8 {
        return switch (self.value) {
            .string => self._string_storage[0..self._string_len],
            else => null,
        };
    }

    /// copy a string into internal storage
    fn copyString(self: *Attribute, str: []const u8) void {
        const len = @min(str.len, max_string_len);
        @memcpy(self._string_storage[0..len], str[0..len]);
        self._string_len = len;
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
                    // copy string into internal storage, tag value as string
                    attr.* = .{ .key = key, .value = .string };
                    attr.copyString(value);
                    return true;
                }
                if (ptr.size == .one) {
                    const child_info = @typeInfo(ptr.child);
                    if (child_info == .array and child_info.array.child == u8) {
                        attr.* = .{ .key = key, .value = .string };
                        attr.copyString(value);
                        return true;
                    }
                }
                return false;
            },
            .array => |arr| {
                if (arr.child == u8) {
                    attr.* = .{ .key = key, .value = .string };
                    attr.copyString(&value);
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
    pub fn writeJson(self: *const Attribute, w: anytype) !void {
        try w.writeAll("{\"key\":");
        try writeJsonString(w, self.key);
        try w.writeAll(",\"value\":{");

        switch (self.value) {
            .string => {
                try w.writeAll("\"stringValue\":");
                try writeJsonString(w, self.getString().?);
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
    try std.testing.expectEqualStrings("test", attrs[0].getString().?);
    try std.testing.expectEqual(@as(i64, 42), attrs[1].value.int);
    try std.testing.expectEqual(true, attrs[2].value.bool_val);
}

test "writeJson string" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    // create attr with string value via fromStruct
    var attrs: [1]Attribute = undefined;
    _ = Attribute.fromStruct(.{ .foo = "bar" }, &attrs);
    try attrs[0].writeJson(fbs.writer());
    try std.testing.expectEqualStrings("{\"key\":\"foo\",\"value\":{\"stringValue\":\"bar\"}}", fbs.getWritten());
}

test "copy safety - string survives struct copy" {
    // this test verifies the fix for dangling pointer after struct copy
    var original: [1]Attribute = undefined;
    _ = Attribute.fromStruct(.{ .query = "hello world" }, &original);

    // copy the struct (this is what span.end() does internally)
    const copy = original;

    // the copy should have valid string data
    try std.testing.expectEqualStrings("query", copy[0].key);
    try std.testing.expectEqualStrings("hello world", copy[0].getString().?);

    // verify the copy's getString returns data from the copy's _string_storage
    // not from original (which would be a dangling pointer bug)
    const copy_str_ptr = copy[0].getString().?.ptr;
    const copy_storage_ptr = &copy[0]._string_storage;
    try std.testing.expect(copy_str_ptr == copy_storage_ptr);
}
