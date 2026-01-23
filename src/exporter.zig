//! OTLP HTTP/JSON exporter
//!
//! sends spans and logs to logfire (or any OTLP-compatible backend)
//! uses HTTP with JSON encoding for simplicity.
//!
//! endpoints:
//! - /v1/traces - span data
//! - /v1/logs - log records
//!
//! see: https://opentelemetry.io/docs/specs/otlp/

const std = @import("std");
const Config = @import("config.zig").Config;
const Span = @import("span.zig").Span;
const LogRecord = @import("log.zig").LogRecord;

pub const Exporter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, config: Config) Exporter {
        return .{
            .allocator = allocator,
            .config = config,
            .http_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Exporter) void {
        self.http_client.deinit();
    }

    /// send spans and logs to OTLP endpoints
    pub fn send(
        self: *Exporter,
        spans: []const Span.Data,
        logs: []const LogRecord,
    ) !void {
        if (!self.config.shouldSend()) {
            // just log to console if not sending
            self.printToConsole(spans, logs);
            return;
        }

        const base_url = self.config.base_url orelse return error.NoBaseUrl;

        // send spans
        if (spans.len > 0) {
            const traces_json = try self.buildTracesJson(spans);
            defer self.allocator.free(traces_json);

            try self.sendToEndpoint(base_url, "/v1/traces", traces_json);
        }

        // send logs
        if (logs.len > 0) {
            const logs_json = try self.buildLogsJson(logs);
            defer self.allocator.free(logs_json);

            try self.sendToEndpoint(base_url, "/v1/logs", logs_json);
        }
    }

    fn sendToEndpoint(self: *Exporter, base_url: []const u8, path: []const u8, body: []const u8) !void {
        // build full URL
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, path }) catch return error.UrlTooLong;

        // response writer
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        // build auth header on stack
        var auth_buf: [2048]u8 = undefined;
        var auth_header: ?[]const u8 = null;
        if (self.config.token) |token| {
            auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch null;
        }

        // headers
        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
            // disable gzip: zig stdlib flate.Decompress can panic
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "logfire-zig/0.1.0" },
        };
        if (auth_header) |auth| {
            headers.authorization = .{ .override = auth };
        }

        const result = self.http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &aw.writer,
            .method = .POST,
            .payload = body,
            .headers = headers,
        }) catch return error.RequestFailed;

        if (result.status != .ok and result.status != .accepted) {
            std.log.warn("logfire: export failed: {s}", .{aw.toArrayList().items});
            return error.SendFailed;
        }
    }

    /// build OTLP JSON for traces
    /// see: https://opentelemetry.io/docs/specs/otlp/#otlphttp-request
    fn buildTracesJson(self: *Exporter, spans: []const Span.Data) ![]u8 {
        var json: std.ArrayList(u8) = .{};
        errdefer json.deinit(self.allocator);

        var w = json.writer(self.allocator);

        try w.writeAll("{\"resourceSpans\":[{");

        // resource attributes
        try w.writeAll("\"resource\":{\"attributes\":[");
        try self.writeResourceAttributes(&w);
        try w.writeAll("]},");

        // scope spans
        try w.writeAll("\"scopeSpans\":[{");
        try w.writeAll("\"scope\":{\"name\":\"logfire-zig\"},");
        try w.writeAll("\"spans\":[");

        for (spans, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try self.writeSpanJson(&w, s);
        }

        try w.writeAll("]}]}]}");

        return json.toOwnedSlice(self.allocator);
    }

    /// build OTLP JSON for logs
    fn buildLogsJson(self: *Exporter, logs: []const LogRecord) ![]u8 {
        var json: std.ArrayList(u8) = .{};
        errdefer json.deinit(self.allocator);

        var w = json.writer(self.allocator);

        try w.writeAll("{\"resourceLogs\":[{");

        // resource attributes
        try w.writeAll("\"resource\":{\"attributes\":[");
        try self.writeResourceAttributes(&w);
        try w.writeAll("]},");

        // scope logs
        try w.writeAll("\"scopeLogs\":[{");
        try w.writeAll("\"scope\":{\"name\":\"logfire-zig\"},");
        try w.writeAll("\"logRecords\":[");

        for (logs, 0..) |log, i| {
            if (i > 0) try w.writeByte(',');
            try self.writeLogJson(&w, log);
        }

        try w.writeAll("]}]}]}");

        return json.toOwnedSlice(self.allocator);
    }

    fn writeResourceAttributes(self: *Exporter, w: anytype) !void {
        var first = true;

        if (self.config.service_name) |name| {
            try writeAttribute(w, "service.name", .{ .string = name }, &first);
        }
        if (self.config.service_version) |version| {
            try writeAttribute(w, "service.version", .{ .string = version }, &first);
        }
        if (self.config.environment) |env| {
            try writeAttribute(w, "deployment.environment.name", .{ .string = env }, &first);
        }
    }

    fn writeSpanJson(self: *Exporter, w: anytype, s: Span.Data) !void {
        _ = self;
        try w.writeByte('{');

        // trace and span IDs (hex encoded)
        try w.writeAll("\"traceId\":\"");
        try writeHex(w, &s.trace_id);
        try w.writeAll("\",\"spanId\":\"");
        try writeHex(w, &s.span_id);
        try w.writeAll("\",");

        // name
        try w.writeAll("\"name\":");
        try writeJsonString(w, s.name);
        try w.writeByte(',');

        // kind (internal = 1)
        try w.writeAll("\"kind\":1,");

        // timestamps (nanoseconds)
        try w.print("\"startTimeUnixNano\":\"{d}\",", .{s.start_time_ns});
        try w.print("\"endTimeUnixNano\":\"{d}\",", .{s.end_time_ns});

        // attributes (empty for now, will add later)
        try w.writeAll("\"attributes\":[]");

        // status (unset = 0)
        try w.writeAll(",\"status\":{\"code\":0}");

        try w.writeByte('}');
    }

    fn writeLogJson(self: *Exporter, w: anytype, log: LogRecord) !void {
        _ = self;
        try w.writeByte('{');

        // timestamp
        try w.print("\"timeUnixNano\":\"{d}\",", .{log.timestamp_ns});

        // severity
        try w.print("\"severityNumber\":{d},", .{log.level.severity()});
        try w.writeAll("\"severityText\":");
        try writeJsonString(w, log.level.name());
        try w.writeByte(',');

        // body
        try w.writeAll("\"body\":{\"stringValue\":");
        try writeJsonString(w, log.message);
        try w.writeAll("},");

        // trace context
        if (log.trace_id) |tid| {
            try w.writeAll("\"traceId\":\"");
            try writeHex(w, &tid);
            try w.writeAll("\",");
        }

        // attributes (empty for now)
        try w.writeAll("\"attributes\":[]");

        try w.writeByte('}');
    }

    fn printToConsole(self: *Exporter, spans: []const Span.Data, logs: []const LogRecord) void {
        const console = self.config.console orelse return;
        if (!console.enabled) return;

        for (spans) |s| {
            const duration_ms = @as(f64, @floatFromInt(s.end_time_ns - s.start_time_ns)) / 1_000_000.0;
            std.debug.print("[span] {s} ({d:.2}ms)\n", .{ s.name, duration_ms });
        }

        for (logs) |log| {
            if (@intFromEnum(log.level) < @intFromEnum(console.min_level)) continue;
            std.debug.print("[{s}] {s}\n", .{ log.level.name(), log.message });
        }
    }
};

const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool_val: bool,
};

fn writeAttribute(w: anytype, key: []const u8, value: AttributeValue, first: *bool) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try writeAttributeKv(w, key, value);
}

fn writeAttributeKv(w: anytype, key: []const u8, value: AttributeValue) !void {
    try w.writeAll("{\"key\":");
    try writeJsonString(w, key);
    try w.writeAll(",\"value\":{");

    switch (value) {
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

fn writeHex(w: anytype, bytes: []const u8) !void {
    for (bytes) |b| {
        try w.print("{x:0>2}", .{b});
    }
}

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

test "buildTracesJson" {
    const allocator = std.testing.allocator;
    var config = Config{
        .service_name = "test-service",
        .send_to_logfire = .no,
    };
    config = config.resolve();

    var exporter = Exporter.init(allocator, config);
    defer exporter.deinit();

    const spans = [_]Span.Data{
        .{
            .name = "test.span",
            .trace_id = [_]u8{0x01} ** 16,
            .span_id = [_]u8{0x02} ** 8,
            .start_time_ns = 1000,
            .end_time_ns = 2000,
        },
    };

    const json = try exporter.buildTracesJson(&spans);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "test.span") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "test-service") != null);
}
