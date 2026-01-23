//! structured logging
//!
//! logs are exported as OTLP log records with severity levels.

const std = @import("std");
pub const Level = @import("config.zig").Config.Level;

pub const LogRecord = struct {
    timestamp_ns: i128,
    level: Level,
    message: []const u8,
    trace_id: ?[16]u8,

    pub fn init(
        trace_id: ?[16]u8,
        level: Level,
        message: []const u8,
        attrs: anytype,
    ) LogRecord {
        _ = attrs; // TODO: implement attribute storage

        return .{
            .timestamp_ns = std.time.nanoTimestamp(),
            .level = level,
            .message = message,
            .trace_id = trace_id,
        };
    }
};

// tests

test "LogRecord init" {
    const record = LogRecord.init(null, .info, "test message", .{});
    try std.testing.expectEqual(Level.info, record.level);
    try std.testing.expectEqualStrings("test message", record.message);
}
