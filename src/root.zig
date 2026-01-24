//! logfire-zig: zig SDK for pydantic logfire
//!
//! a lightweight observability client that sends traces, logs, and metrics
//! to logfire (or any OTLP-compatible backend) via HTTP/JSON.
//!
//! ## quick start
//!
//! ```zig
//! const logfire = @import("logfire");
//!
//! pub fn main() !void {
//!     var lf = try logfire.configure(.{
//!         .service_name = "my-service",
//!     });
//!     defer lf.shutdown();
//!
//!     logfire.info("hello from zig", .{});
//!
//!     const s = logfire.span("do_work", .{ .item_count = 42 });
//!     defer s.end();
//!     // ... do work
//! }
//! ```

const std = @import("std");

pub const Config = @import("config.zig").Config;
pub const Span = @import("span.zig").Span;
pub const Exporter = @import("exporter.zig").Exporter;
pub const Attribute = @import("attribute.zig").Attribute;

const metrics_mod = @import("metrics.zig");
pub const Counter = metrics_mod.Counter;
pub const Gauge = metrics_mod.Gauge;
pub const UpDownCounter = metrics_mod.UpDownCounter;
pub const Histogram = metrics_mod.Histogram;
pub const ExponentialHistogram = metrics_mod.ExponentialHistogram;
pub const MetricData = metrics_mod.MetricData;
pub const NumberDataPoint = metrics_mod.NumberDataPoint;
pub const HistogramDataPoint = metrics_mod.HistogramDataPoint;
pub const ExponentialHistogramDataPoint = metrics_mod.ExponentialHistogramDataPoint;
pub const InstrumentOptions = metrics_mod.InstrumentOptions;
pub const HistogramOptions = metrics_mod.HistogramOptions;
pub const AggregationTemporality = metrics_mod.AggregationTemporality;

const log_mod = @import("log.zig");
pub const Level = log_mod.Level;
pub const LogRecord = log_mod.LogRecord;

/// global logfire instance (set after configure())
var global_instance: ?*Logfire = null;
var global_mutex: std.Thread.Mutex = .{};

/// thread-local trace context - each thread gets its own trace
threadlocal var tl_trace_id: ?[16]u8 = null;
threadlocal var tl_current_span_id: ?[8]u8 = null;
threadlocal var tl_active_span_count: u32 = 0;

pub const Logfire = struct {
    allocator: std.mem.Allocator,
    config: Config,
    exporter: Exporter,

    /// pending spans/logs/metrics waiting to be exported
    pending_spans: std.ArrayList(Span.Data),
    pending_logs: std.ArrayList(LogRecord),
    pending_metrics: std.ArrayList(MetricData),
    pending_mutex: std.Thread.Mutex,

    /// allocated data points (freed on flush)
    allocated_data_points: std.ArrayList(*NumberDataPoint),

    /// span ID counter (global, just needs to be unique)
    span_id_counter: std.atomic.Value(u64),

    /// background flush thread
    flush_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Logfire {
        const resolved = config.resolve();

        const self = try allocator.create(Logfire);
        self.* = .{
            .allocator = allocator,
            .config = resolved,
            .exporter = Exporter.init(allocator, resolved),
            .pending_spans = .{},
            .pending_logs = .{},
            .pending_metrics = .{},
            .pending_mutex = .{},
            .allocated_data_points = .{},
            .span_id_counter = std.atomic.Value(u64).init(1),
            .flush_thread = null,
            .running = std.atomic.Value(bool).init(true),
        };

        // start background flush thread
        if (resolved.batch_timeout_ms > 0) {
            self.flush_thread = std.Thread.spawn(.{}, flushLoop, .{self}) catch null;
        }

        return self;
    }

    fn flushLoop(self: *Logfire) void {
        const interval_ns = self.config.batch_timeout_ms * std.time.ns_per_ms;
        while (self.running.load(.acquire)) {
            std.Thread.sleep(interval_ns);
            if (!self.running.load(.acquire)) break;
            self.flush() catch |e| {
                std.log.warn("logfire: background flush failed: {}", .{e});
            };
        }
    }

    pub fn deinit(self: *Logfire) void {
        // free any remaining allocated data points
        for (self.allocated_data_points.items) |dp| {
            self.allocator.destroy(dp);
        }
        self.allocated_data_points.deinit(self.allocator);
        self.pending_spans.deinit(self.allocator);
        self.pending_logs.deinit(self.allocator);
        self.pending_metrics.deinit(self.allocator);
        self.exporter.deinit();
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *Logfire) void {
        // stop flush thread
        self.running.store(false, .release);
        if (self.flush_thread) |t| {
            t.join();
        }

        // final flush
        self.flush() catch |e| {
            std.log.warn("logfire: flush failed during shutdown: {}", .{e});
        };

        global_mutex.lock();
        defer global_mutex.unlock();
        if (global_instance == self) {
            global_instance = null;
        }

        self.deinit();
    }

    pub fn flush(self: *Logfire) !void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        if (self.pending_spans.items.len > 0 or self.pending_logs.items.len > 0 or self.pending_metrics.items.len > 0) {
            try self.exporter.sendAll(
                self.pending_spans.items,
                self.pending_logs.items,
                self.pending_metrics.items,
            );
            self.pending_spans.clearRetainingCapacity();
            self.pending_logs.clearRetainingCapacity();
            self.pending_metrics.clearRetainingCapacity();

            // free allocated data points
            for (self.allocated_data_points.items) |dp| {
                self.allocator.destroy(dp);
            }
            self.allocated_data_points.clearRetainingCapacity();
        }
    }

    pub fn createSpan(self: *Logfire, name: []const u8, attributes: anytype) Span {
        // generate new trace ID if no active spans on this thread
        if (tl_active_span_count == 0) {
            tl_trace_id = generateTraceId();
        }
        tl_active_span_count += 1;

        // capture parent span ID before creating new span
        const parent_span_id = tl_current_span_id;
        const span_id = self.span_id_counter.fetchAdd(1, .monotonic);

        // encode span ID
        var span_id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &span_id_bytes, span_id, .big);

        // update current span ID for this thread
        tl_current_span_id = span_id_bytes;

        return Span.init(self, name, span_id_bytes, tl_trace_id, parent_span_id, attributes);
    }

    /// called when a span ends to restore parent context
    pub fn spanEnded(self: *Logfire, parent_span_id: ?[8]u8) void {
        _ = self;
        if (tl_active_span_count > 0) {
            tl_active_span_count -= 1;
        }
        // restore parent as current span
        tl_current_span_id = parent_span_id;
    }

    /// start a new trace (generates new trace ID for this thread)
    pub fn newTrace(self: *Logfire) void {
        _ = self;
        tl_trace_id = generateTraceId();
    }

    /// get the current thread's trace ID
    pub fn currentTraceId() ?[16]u8 {
        return tl_trace_id;
    }

    pub fn recordLog(self: *Logfire, level: Level, message: []const u8, attributes: anytype) void {
        const record = LogRecord.init(
            tl_trace_id,
            level,
            message,
            attributes,
        );

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        self.pending_logs.append(self.allocator, record) catch {
            std.log.warn("logfire: failed to record log", .{});
        };
    }

    pub fn recordSpanEnd(self: *Logfire, data: Span.Data) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        self.pending_spans.append(self.allocator, data) catch {
            std.log.warn("logfire: failed to record span", .{});
        };
    }

    pub fn recordMetric(self: *Logfire, data: MetricData) void {
        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();
        self.pending_metrics.append(self.allocator, data) catch {
            std.log.warn("logfire: failed to record metric", .{});
        };
    }

    /// record a counter value (monotonic sum, delta temporality)
    pub fn recordCounter(self: *Logfire, name: []const u8, value: i64, opts: InstrumentOptions) void {
        const now = std.time.nanoTimestamp();
        const dp = self.allocator.create(NumberDataPoint) catch return;
        dp.* = .{
            .start_time_ns = now,
            .time_ns = now,
            .value = .{ .int = value },
        };

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        // track allocation for cleanup
        self.allocated_data_points.append(self.allocator, dp) catch {
            self.allocator.destroy(dp);
            return;
        };

        self.pending_metrics.append(self.allocator, .{
            .name = name,
            .description = opts.description,
            .unit = opts.unit,
            .data = .{
                .sum = .{
                    .data_points = @as(*const [1]NumberDataPoint, dp),
                    .temporality = .delta, // delta since we send individual increments
                    .is_monotonic = true,
                },
            },
        }) catch {};
    }

    /// record a gauge value (instantaneous)
    pub fn recordGaugeInt(self: *Logfire, name: []const u8, value: i64, opts: InstrumentOptions) void {
        const now = std.time.nanoTimestamp();
        const dp = self.allocator.create(NumberDataPoint) catch return;
        dp.* = .{
            .start_time_ns = now,
            .time_ns = now,
            .value = .{ .int = value },
        };

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        // track allocation for cleanup
        self.allocated_data_points.append(self.allocator, dp) catch {
            self.allocator.destroy(dp);
            return;
        };

        self.pending_metrics.append(self.allocator, .{
            .name = name,
            .description = opts.description,
            .unit = opts.unit,
            .data = .{
                .gauge = .{
                    .data_points = @as(*const [1]NumberDataPoint, dp),
                },
            },
        }) catch {};
    }

    /// record a gauge value (instantaneous, f64)
    pub fn recordGaugeDouble(self: *Logfire, name: []const u8, value: f64, opts: InstrumentOptions) void {
        const now = std.time.nanoTimestamp();
        const dp = self.allocator.create(NumberDataPoint) catch return;
        dp.* = .{
            .start_time_ns = now,
            .time_ns = now,
            .value = .{ .double = value },
        };

        self.pending_mutex.lock();
        defer self.pending_mutex.unlock();

        // track allocation for cleanup
        self.allocated_data_points.append(self.allocator, dp) catch {
            self.allocator.destroy(dp);
            return;
        };

        self.pending_metrics.append(self.allocator, .{
            .name = name,
            .description = opts.description,
            .unit = opts.unit,
            .data = .{
                .gauge = .{
                    .data_points = @as(*const [1]NumberDataPoint, dp),
                },
            },
        }) catch {};
    }

    fn generateTraceId() [16]u8 {
        var id: [16]u8 = undefined;
        std.crypto.random.bytes(&id);
        return id;
    }
};

/// configure logfire with the given options
pub fn configure(options: Config) !*Logfire {
    const allocator = std.heap.page_allocator;
    const instance = try Logfire.init(allocator, options);

    global_mutex.lock();
    defer global_mutex.unlock();
    global_instance = instance;

    return instance;
}

/// get the global logfire instance
pub fn getInstance() ?*Logfire {
    global_mutex.lock();
    defer global_mutex.unlock();
    return global_instance;
}

// convenience functions that use the global instance

pub fn span(name: []const u8, attributes: anytype) Span {
    if (getInstance()) |lf| {
        return lf.createSpan(name, attributes);
    }
    return Span.noop();
}

/// start a new trace (generates new trace ID for subsequent spans)
pub fn newTrace() void {
    if (getInstance()) |lf| {
        lf.newTrace();
    }
}

pub fn trace(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.trace, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    logWithLevel(.err, fmt, args);
}

fn logWithLevel(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (getInstance()) |lf| {
        var buf: [4096]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        // dupe the message since buf is on the stack
        const owned_message = lf.allocator.dupe(u8, message) catch return;
        lf.recordLog(level, owned_message, .{});
    }
}

// metric convenience functions

pub fn counter(name: []const u8, value: i64) void {
    if (getInstance()) |lf| {
        lf.recordCounter(name, value, .{});
    }
}

pub fn counterWithOpts(name: []const u8, value: i64, opts: InstrumentOptions) void {
    if (getInstance()) |lf| {
        lf.recordCounter(name, value, opts);
    }
}

pub fn gaugeInt(name: []const u8, value: i64) void {
    if (getInstance()) |lf| {
        lf.recordGaugeInt(name, value, .{});
    }
}

pub fn gaugeDouble(name: []const u8, value: f64) void {
    if (getInstance()) |lf| {
        lf.recordGaugeDouble(name, value, .{});
    }
}

pub fn metric(data: MetricData) void {
    if (getInstance()) |lf| {
        lf.recordMetric(data);
    }
}

// tests

test "basic configuration" {
    const lf = try configure(.{
        .service_name = "test-service",
        .send_to_logfire = .no,
    });
    defer lf.shutdown();

    try std.testing.expect(getInstance() != null);
}

test "span creation" {
    const lf = try configure(.{
        .service_name = "test-service",
        .send_to_logfire = .no,
    });
    defer lf.shutdown();

    const s = span("test.operation", .{});
    defer s.end();

    try std.testing.expect(s.active);
}

test "logging" {
    const lf = try configure(.{
        .service_name = "test-service",
        .send_to_logfire = .no,
    });
    defer lf.shutdown();

    info("test message with {d}", .{42});

    try std.testing.expectEqual(@as(usize, 1), lf.pending_logs.items.len);
}

test "metrics recording" {
    const lf = try configure(.{
        .service_name = "test-service",
        .send_to_logfire = .no,
    });
    defer lf.shutdown();

    counter("requests.total", 1);
    gaugeInt("connections.active", 42);

    try std.testing.expectEqual(@as(usize, 2), lf.pending_metrics.items.len);
}

test "parent-child span linking" {
    const lf = try configure(.{
        .service_name = "test-service",
        .send_to_logfire = .no,
    });
    defer lf.shutdown();

    // create parent span
    const parent = span("parent.operation", .{});
    const parent_span_id = parent.data.span_id;
    const parent_trace_id = parent.data.trace_id;

    // parent should have no parent
    try std.testing.expect(parent.data.parent_span_id == null);

    // create child span while parent is active
    const child = span("child.operation", .{});

    // child should have parent's span_id as parent_span_id
    try std.testing.expect(child.data.parent_span_id != null);
    try std.testing.expectEqualSlices(u8, &parent_span_id, &child.data.parent_span_id.?);

    // child should share parent's trace_id
    try std.testing.expectEqualSlices(u8, &parent_trace_id, &child.data.trace_id);

    // end spans (child first due to defer order)
    child.end();
    parent.end();

    // should have recorded 2 spans
    try std.testing.expectEqual(@as(usize, 2), lf.pending_spans.items.len);
}

// re-export tests from submodules
test {
    _ = @import("config.zig");
    _ = @import("exporter.zig");
    _ = @import("span.zig");
    _ = @import("log.zig");
    _ = @import("attribute.zig");
    _ = @import("metrics.zig");
}
