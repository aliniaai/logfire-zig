//! span tracking for distributed tracing
//!
//! spans measure the duration of operations.
//! use defer to ensure spans are ended even on error paths.
//!
//! ## usage
//!
//! ```zig
//! const s = logfire.span("db.query", .{});
//! defer s.end();
//! // ... do work
//! ```

const std = @import("std");
const root = @import("root.zig");
const Attribute = @import("attribute.zig").Attribute;

pub const Span = struct {
    logfire: ?*root.Logfire,
    data: Data,
    active: bool,

    pub const max_attributes = 32;

    pub const Data = struct {
        name: []const u8,
        trace_id: [16]u8,
        span_id: [8]u8,
        start_time_ns: i128,
        end_time_ns: i128,
        attributes: [max_attributes]Attribute = undefined,
        attribute_count: usize = 0,
    };

    /// create a span (called by Logfire.createSpan)
    pub fn init(logfire: *root.Logfire, name: []const u8, span_id_num: u64, attrs: anytype) Span {
        var s = Span{
            .logfire = logfire,
            .data = .{
                .name = name,
                .trace_id = logfire.current_trace_id orelse [_]u8{0} ** 16,
                .span_id = undefined,
                .start_time_ns = std.time.nanoTimestamp(),
                .end_time_ns = 0,
            },
            .active = true,
        };

        // encode span ID from counter
        std.mem.writeInt(u64, &s.data.span_id, span_id_num, .big);

        // store attributes
        s.data.attribute_count = Attribute.fromStruct(attrs, &s.data.attributes);

        return s;
    }

    /// create a no-op span (when logfire not configured)
    pub fn noop() Span {
        return .{
            .logfire = null,
            .data = .{
                .name = "",
                .trace_id = [_]u8{0} ** 16,
                .span_id = [_]u8{0} ** 8,
                .start_time_ns = 0,
                .end_time_ns = 0,
            },
            .active = false,
        };
    }

    /// end the span and record it
    pub fn end(self: *const Span) void {
        if (!self.active) return;
        if (self.logfire) |lf| {
            var data = self.data;
            data.end_time_ns = std.time.nanoTimestamp();
            lf.recordSpanEnd(data);
            lf.spanEnded();
        }
    }
};

// tests

test "span lifecycle" {
    const s = Span.noop();
    defer s.end();

    try std.testing.expect(!s.active);
}
