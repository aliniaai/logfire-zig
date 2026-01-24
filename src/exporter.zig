//! OTLP HTTP/JSON exporter
//!
//! sends spans, logs, and metrics to logfire (or any OTLP-compatible backend)
//! uses HTTP with JSON encoding for simplicity.
//!
//! endpoints:
//! - /v1/traces - span data
//! - /v1/logs - log records
//! - /v1/metrics - metric data
//!
//! see: https://opentelemetry.io/docs/specs/otlp/

const std = @import("std");
const json = std.json;
const Config = @import("config.zig").Config;
const Span = @import("span.zig").Span;
const LogRecord = @import("log.zig").LogRecord;
const Attribute = @import("attribute.zig").Attribute;
const metrics_mod = @import("metrics.zig");
const MetricData = metrics_mod.MetricData;

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
        try self.sendAll(spans, logs, &.{});
    }

    /// send spans, logs, and metrics to OTLP endpoints
    pub fn sendAll(
        self: *Exporter,
        spans: []const Span.Data,
        logs: []const LogRecord,
        metrics: []const MetricData,
    ) !void {
        if (!self.config.shouldSend()) {
            self.printToConsole(spans, logs, metrics);
            return;
        }

        const base_url = self.config.base_url orelse return error.NoBaseUrl;

        if (spans.len > 0) {
            const traces_json = try self.buildTracesJson(spans);
            defer self.allocator.free(traces_json);
            try self.sendToEndpoint(base_url, "/v1/traces", traces_json);
        }

        if (logs.len > 0) {
            const logs_json = try self.buildLogsJson(logs);
            defer self.allocator.free(logs_json);
            try self.sendToEndpoint(base_url, "/v1/logs", logs_json);
        }

        if (metrics.len > 0) {
            const metrics_json = try self.buildMetricsJson(metrics);
            defer self.allocator.free(metrics_json);
            try self.sendToEndpoint(base_url, "/v1/metrics", metrics_json);
        }
    }

    fn sendToEndpoint(self: *Exporter, base_url: []const u8, path: []const u8, body: []const u8) !void {
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ base_url, path }) catch return error.UrlTooLong;

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var auth_buf: [2048]u8 = undefined;
        var auth_header: ?[]const u8 = null;
        if (self.config.token) |token| {
            auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch null;
        }

        var headers: std.http.Client.Request.Headers = .{
            .content_type = .{ .override = "application/json" },
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
            std.log.warn("logfire: export to {s} failed ({s}): {s}", .{ path, @tagName(result.status), aw.toArrayList().items });
            return error.SendFailed;
        }

        // OTLP partial_success response indicates rejected data points
        const response = aw.toArrayList().items;
        if (response.len > 0) {
            std.log.debug("logfire: {s} response: {s}", .{ path, response });
        }
    }

    fn buildTracesJson(self: *Exporter, spans: []const Span.Data) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var jw: json.Stringify = .{ .writer = &output.writer };

        try jw.beginObject();
        try jw.objectField("resourceSpans");
        try jw.beginArray();
        try jw.beginObject();

        // resource
        try jw.objectField("resource");
        try jw.beginObject();
        try jw.objectField("attributes");
        try self.writeResourceAttributesArray(&jw);
        try jw.endObject();

        // scopeSpans
        try jw.objectField("scopeSpans");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("scope");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write("logfire-zig");
        try jw.endObject();

        try jw.objectField("spans");
        try jw.beginArray();
        for (spans) |s| {
            try self.writeSpanObject(&jw, s);
        }
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();
        try jw.endObject();

        return output.toOwnedSlice();
    }

    fn buildLogsJson(self: *Exporter, logs: []const LogRecord) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var jw: json.Stringify = .{ .writer = &output.writer };

        try jw.beginObject();
        try jw.objectField("resourceLogs");
        try jw.beginArray();
        try jw.beginObject();

        // resource
        try jw.objectField("resource");
        try jw.beginObject();
        try jw.objectField("attributes");
        try self.writeResourceAttributesArray(&jw);
        try jw.endObject();

        // scopeLogs
        try jw.objectField("scopeLogs");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("scope");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write("logfire-zig");
        try jw.endObject();

        try jw.objectField("logRecords");
        try jw.beginArray();
        for (logs) |log| {
            try self.writeLogObject(&jw, log);
        }
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();
        try jw.endObject();

        return output.toOwnedSlice();
    }

    pub fn buildMetricsJson(self: *Exporter, metrics: []const MetricData) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer output.deinit();
        var jw: json.Stringify = .{ .writer = &output.writer };

        try jw.beginObject();
        try jw.objectField("resourceMetrics");
        try jw.beginArray();
        try jw.beginObject();

        // resource
        try jw.objectField("resource");
        try jw.beginObject();
        try jw.objectField("attributes");
        try self.writeResourceAttributesArray(&jw);
        try jw.endObject();

        // scopeMetrics
        try jw.objectField("scopeMetrics");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("scope");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write("logfire-zig");
        try jw.endObject();

        try jw.objectField("metrics");
        try jw.beginArray();
        for (metrics) |metric| {
            try writeMetricObject(&jw, metric);
        }
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();

        try jw.endObject();
        try jw.endArray();
        try jw.endObject();

        return output.toOwnedSlice();
    }

    fn writeResourceAttributesArray(self: *Exporter, jw: *json.Stringify) !void {
        try jw.beginArray();
        if (self.config.service_name) |name| {
            try writeAttributeObject(jw, "service.name", .{ .string = name });
        }
        if (self.config.service_version) |version| {
            try writeAttributeObject(jw, "service.version", .{ .string = version });
        }
        if (self.config.environment) |env| {
            try writeAttributeObject(jw, "deployment.environment.name", .{ .string = env });
        }
        try jw.endArray();
    }

    fn writeSpanObject(self: *Exporter, jw: *json.Stringify, s: Span.Data) !void {
        _ = self;
        try jw.beginObject();

        try jw.objectField("traceId");
        try writeHexString(jw, &s.trace_id);

        try jw.objectField("spanId");
        try writeHexString(jw, &s.span_id);

        if (s.parent_span_id) |parent_id| {
            try jw.objectField("parentSpanId");
            try writeHexString(jw, &parent_id);
        }

        try jw.objectField("name");
        try jw.write(s.name);

        try jw.objectField("kind");
        try jw.write(@as(i64, 1));

        try jw.objectField("startTimeUnixNano");
        try writeNsString(jw, s.start_time_ns);

        try jw.objectField("endTimeUnixNano");
        try writeNsString(jw, s.end_time_ns);

        try jw.objectField("attributes");
        try jw.beginArray();
        for (s.attributes[0..s.attribute_count]) |attr| {
            try writeAttributeFromAttr(jw, attr);
        }
        try jw.endArray();

        try jw.objectField("status");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(@as(i64, 0));
        try jw.endObject();

        try jw.endObject();
    }

    fn writeLogObject(self: *Exporter, jw: *json.Stringify, log: LogRecord) !void {
        _ = self;
        try jw.beginObject();

        try jw.objectField("timeUnixNano");
        try writeNsString(jw, log.timestamp_ns);

        try jw.objectField("severityNumber");
        try jw.write(@as(i64, log.level.severity()));

        try jw.objectField("severityText");
        try jw.write(log.level.name());

        try jw.objectField("body");
        try jw.beginObject();
        try jw.objectField("stringValue");
        try jw.write(log.message);
        try jw.endObject();

        if (log.trace_id) |tid| {
            try jw.objectField("traceId");
            try writeHexString(jw, &tid);
        }

        try jw.objectField("attributes");
        try jw.beginArray();
        for (log.attributes[0..log.attribute_count]) |attr| {
            try writeAttributeFromAttr(jw, attr);
        }
        try jw.endArray();

        try jw.endObject();
    }

    fn printToConsole(self: *Exporter, spans: []const Span.Data, logs: []const LogRecord, metrics: []const MetricData) void {
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

        for (metrics) |metric| {
            std.debug.print("[metric] {s}\n", .{metric.name});
        }
    }
};

// helper functions

fn writeMetricObject(jw: *json.Stringify, metric: MetricData) !void {
    try jw.beginObject();

    try jw.objectField("name");
    try jw.write(metric.name);

    if (metric.description.len > 0) {
        try jw.objectField("description");
        try jw.write(metric.description);
    }

    if (metric.unit.len > 0) {
        try jw.objectField("unit");
        try jw.write(metric.unit);
    }

    switch (metric.data) {
        .sum => |sum| {
            try jw.objectField("sum");
            try jw.beginObject();
            try jw.objectField("aggregationTemporality");
            try jw.write(@as(i64, @intFromEnum(sum.temporality)));
            try jw.objectField("isMonotonic");
            try jw.write(sum.is_monotonic);
            try jw.objectField("dataPoints");
            try jw.beginArray();
            for (sum.data_points) |dp| {
                try writeNumberDataPointObject(jw, dp);
            }
            try jw.endArray();
            try jw.endObject();
        },
        .gauge => |gauge| {
            try jw.objectField("gauge");
            try jw.beginObject();
            try jw.objectField("dataPoints");
            try jw.beginArray();
            for (gauge.data_points) |dp| {
                try writeNumberDataPointObject(jw, dp);
            }
            try jw.endArray();
            try jw.endObject();
        },
        .histogram => |hist| {
            try jw.objectField("histogram");
            try jw.beginObject();
            try jw.objectField("aggregationTemporality");
            try jw.write(@as(i64, @intFromEnum(hist.temporality)));
            try jw.objectField("dataPoints");
            try jw.beginArray();
            for (hist.data_points) |dp| {
                try writeHistogramDataPointObject(jw, dp);
            }
            try jw.endArray();
            try jw.endObject();
        },
        .exponential_histogram => |exp_hist| {
            try jw.objectField("exponentialHistogram");
            try jw.beginObject();
            try jw.objectField("aggregationTemporality");
            try jw.write(@as(i64, @intFromEnum(exp_hist.temporality)));
            try jw.objectField("dataPoints");
            try jw.beginArray();
            for (exp_hist.data_points) |dp| {
                try writeExponentialHistogramDataPointObject(jw, dp);
            }
            try jw.endArray();
            try jw.endObject();
        },
    }

    try jw.endObject();
}

fn writeNumberDataPointObject(jw: *json.Stringify, dp: metrics_mod.NumberDataPoint) !void {
    try jw.beginObject();

    // attributes - always include even if empty
    try jw.objectField("attributes");
    try jw.beginArray();
    for (dp.attributes) |attr| {
        try writeAttributeFromAttr(jw, attr);
    }
    try jw.endArray();

    try jw.objectField("startTimeUnixNano");
    try writeNsString(jw, dp.start_time_ns);

    try jw.objectField("timeUnixNano");
    try writeNsString(jw, dp.time_ns);

    switch (dp.value) {
        .int => |v| {
            try jw.objectField("asInt");
            try jw.write(v); // asInt is a number, not a string
        },
        .double => |v| {
            try jw.objectField("asDouble");
            try jw.write(v);
        },
    }

    try jw.endObject();
}

fn writeHistogramDataPointObject(jw: *json.Stringify, dp: metrics_mod.HistogramDataPoint) !void {
    try jw.beginObject();

    try jw.objectField("startTimeUnixNano");
    try writeNsString(jw, dp.start_time_ns);

    try jw.objectField("timeUnixNano");
    try writeNsString(jw, dp.time_ns);

    try jw.objectField("count");
    try jw.write(dp.count); // number, not string

    try jw.objectField("sum");
    try jw.write(dp.sum);

    try jw.objectField("bucketCounts");
    try jw.beginArray();
    for (dp.bucket_counts) |c| {
        try jw.write(c); // numbers, not strings
    }
    try jw.endArray();

    try jw.objectField("explicitBounds");
    try jw.beginArray();
    for (dp.explicit_bounds) |b| {
        try jw.write(b);
    }
    try jw.endArray();

    try jw.objectField("min");
    try jw.write(dp.min);

    try jw.objectField("max");
    try jw.write(dp.max);

    if (dp.attributes.len > 0) {
        try jw.objectField("attributes");
        try jw.beginArray();
        for (dp.attributes) |attr| {
            try writeAttributeFromAttr(jw, attr);
        }
        try jw.endArray();
    }

    try jw.endObject();
}

fn writeExponentialHistogramDataPointObject(jw: *json.Stringify, dp: metrics_mod.ExponentialHistogramDataPoint) !void {
    try jw.beginObject();

    try jw.objectField("startTimeUnixNano");
    try writeNsString(jw, dp.start_time_ns);

    try jw.objectField("timeUnixNano");
    try writeNsString(jw, dp.time_ns);

    try jw.objectField("count");
    try jw.write(dp.count); // number, not string

    try jw.objectField("sum");
    try jw.write(dp.sum);

    try jw.objectField("scale");
    try jw.write(@as(i64, dp.scale));

    try jw.objectField("zeroCount");
    try jw.write(dp.zero_count); // number, not string

    try jw.objectField("positive");
    try jw.beginObject();
    try jw.objectField("offset");
    try jw.write(@as(i64, dp.positive_offset));
    try jw.objectField("bucketCounts");
    try jw.beginArray();
    for (dp.positive_bucket_counts) |c| {
        try jw.write(c); // numbers, not strings
    }
    try jw.endArray();
    try jw.endObject();

    try jw.objectField("min");
    try jw.write(dp.min);

    try jw.objectField("max");
    try jw.write(dp.max);

    if (dp.attributes.len > 0) {
        try jw.objectField("attributes");
        try jw.beginArray();
        for (dp.attributes) |attr| {
            try writeAttributeFromAttr(jw, attr);
        }
        try jw.endArray();
    }

    try jw.endObject();
}

const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool_val: bool,
};

fn writeAttributeObject(jw: *json.Stringify, key: []const u8, value: AttributeValue) !void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(key);
    try jw.objectField("value");
    try jw.beginObject();
    switch (value) {
        .string => |s| {
            try jw.objectField("stringValue");
            try writeStringValue(jw, s);
        },
        .int => |i| {
            try jw.objectField("intValue");
            try writeIntString(jw, i);
        },
        .float => |f| {
            try jw.objectField("doubleValue");
            try jw.write(f);
        },
        .bool_val => |b| {
            try jw.objectField("boolValue");
            try jw.write(b);
        },
    }
    try jw.endObject();
    try jw.endObject();
}

fn writeAttributeFromAttr(jw: *json.Stringify, attr: Attribute) !void {
    try jw.beginObject();
    try jw.objectField("key");
    try jw.write(attr.key);
    try jw.objectField("value");
    try jw.beginObject();
    switch (attr.value) {
        .string => |s| {
            try jw.objectField("stringValue");
            try writeStringValue(jw, s);
        },
        .int => |i| {
            try jw.objectField("intValue");
            try writeIntString(jw, i);
        },
        .float => |f| {
            try jw.objectField("doubleValue");
            try jw.write(f);
        },
        .bool_val => |b| {
            try jw.objectField("boolValue");
            try jw.write(b);
        },
    }
    try jw.endObject();
    try jw.endObject();
}

fn writeHexString(jw: *json.Stringify, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    for (bytes) |b| {
        _ = std.fmt.bufPrint(buf[i .. i + 2], "{x:0>2}", .{b}) catch unreachable;
        i += 2;
    }
    try jw.write(buf[0..i]);
}

fn writeNsString(jw: *json.Stringify, ns: i128) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{ns}) catch unreachable;
    try jw.write(s);
}

fn writeIntString(jw: *json.Stringify, val: i64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{val}) catch unreachable;
    try jw.write(s);
}

/// write a string value with proper JSON escaping
/// uses raw mode to maintain Stringify state while writing manually
fn writeStringValue(jw: *json.Stringify, s: []const u8) !void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try jw.writer.writeAll("\\\""),
            '\\' => try jw.writer.writeAll("\\\\"),
            '\n' => try jw.writer.writeAll("\\n"),
            '\r' => try jw.writer.writeAll("\\r"),
            '\t' => try jw.writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "\\u00{x:0>2}", .{c}) catch unreachable;
                try jw.writer.writeAll(&buf);
            },
            else => try jw.writer.writeByte(c),
        }
    }
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

// tests

test "buildMetricsJson" {
    const allocator = std.testing.allocator;
    var config = Config{
        .service_name = "test-service",
        .send_to_logfire = .no,
    };
    config = config.resolve();

    var exporter = Exporter.init(allocator, config);
    defer exporter.deinit();

    var dp = metrics_mod.NumberDataPoint{
        .start_time_ns = 1000000000000000000,
        .time_ns = 1000000000000000000,
        .value = .{ .int = 42 },
    };

    const metrics = [_]MetricData{
        .{
            .name = "test.counter",
            .description = "A test counter",
            .unit = "1",
            .data = .{
                .sum = .{
                    .data_points = @as(*const [1]metrics_mod.NumberDataPoint, &dp),
                    .temporality = .delta,
                    .is_monotonic = true,
                },
            },
        },
    };

    const json_out = try exporter.buildMetricsJson(&metrics);
    defer allocator.free(json_out);

    // verify structure
    try std.testing.expect(std.mem.indexOf(u8, json_out, "test.counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"aggregationTemporality\":1") != null); // delta=1
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"isMonotonic\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\"asInt\":42") != null);
}

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

    const json_out = try exporter.buildTracesJson(&spans);
    defer allocator.free(json_out);

    try std.testing.expect(std.mem.indexOf(u8, json_out, "test.span") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "test-service") != null);
}
