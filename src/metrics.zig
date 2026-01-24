//! metrics for observability
//!
//! provides counter, gauge, up-down counter, and histogram instruments
//! matching the OpenTelemetry metrics specification.
//!
//! ## usage
//!
//! ```zig
//! var counter = logfire.u64_counter("requests.total", .{
//!     .description = "total HTTP requests",
//!     .unit = "1",
//! });
//! counter.add(1, &.{.{ .key = "method", .value = .{ .string = "GET" } }});
//! ```

const std = @import("std");
const Attribute = @import("attribute.zig").Attribute;

// ============================================================================
// instrument options
// ============================================================================

pub const InstrumentOptions = struct {
    description: []const u8 = "",
    unit: []const u8 = "",
};

pub const HistogramOptions = struct {
    description: []const u8 = "",
    unit: []const u8 = "",
    /// explicit bucket boundaries (defaults to OpenTelemetry default boundaries)
    boundaries: ?[]const f64 = null,
};

pub const ExponentialHistogramOptions = struct {
    description: []const u8 = "",
    unit: []const u8 = "",
    /// scale factor for exponential buckets (higher = more precision)
    scale: i8 = 20,
};

// ============================================================================
// counter - monotonically increasing value
// ============================================================================

pub fn Counter(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        value: if (T == u64) std.atomic.Value(u64) else if (T == f64) std.atomic.Value(u64) else @compileError("Counter supports u64 and f64"),

        pub fn init(name: []const u8, opts: InstrumentOptions) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .value = @TypeOf(@as(Self, undefined).value).init(0),
            };
        }

        pub fn add(self: *Self, delta: T, attributes: []const Attribute) void {
            _ = attributes; // TODO: attribute aggregation
            if (T == f64) {
                // store f64 as bits
                const bits: u64 = @bitCast(delta);
                const old_bits = self.value.load(.monotonic);
                const old_val: f64 = @bitCast(old_bits);
                const new_bits: u64 = @bitCast(old_val + delta);
                // simple add for now (not atomic for f64, but close enough for metrics)
                self.value.store(new_bits, .monotonic);
                _ = bits;
            } else {
                _ = self.value.fetchAdd(delta, .monotonic);
            }
        }

        pub fn get(self: *const Self) T {
            const raw = self.value.load(.monotonic);
            if (T == f64) {
                return @bitCast(raw);
            }
            return raw;
        }
    };
}

// ============================================================================
// gauge - instantaneous value
// ============================================================================

pub fn Gauge(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        value: if (T == i64) std.atomic.Value(i64) else if (T == u64) std.atomic.Value(u64) else if (T == f64) std.atomic.Value(u64) else @compileError("Gauge supports i64, u64, and f64"),

        pub fn init(name: []const u8, opts: InstrumentOptions) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .value = @TypeOf(@as(Self, undefined).value).init(0),
            };
        }

        pub fn record(self: *Self, value: T, attributes: []const Attribute) void {
            _ = attributes;
            if (T == f64) {
                self.value.store(@bitCast(value), .monotonic);
            } else {
                self.value.store(value, .monotonic);
            }
        }

        pub fn get(self: *const Self) T {
            const raw = self.value.load(.monotonic);
            if (T == f64) {
                return @bitCast(raw);
            }
            return raw;
        }
    };
}

// ============================================================================
// up-down counter - bidirectional counter
// ============================================================================

pub fn UpDownCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        value: if (T == i64) std.atomic.Value(i64) else if (T == f64) std.atomic.Value(u64) else @compileError("UpDownCounter supports i64 and f64"),

        pub fn init(name: []const u8, opts: InstrumentOptions) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .value = @TypeOf(@as(Self, undefined).value).init(0),
            };
        }

        pub fn add(self: *Self, delta: T, attributes: []const Attribute) void {
            _ = attributes;
            if (T == f64) {
                const old_bits = self.value.load(.monotonic);
                const old_val: f64 = @bitCast(old_bits);
                const new_bits: u64 = @bitCast(old_val + delta);
                self.value.store(new_bits, .monotonic);
            } else {
                _ = self.value.fetchAdd(delta, .monotonic);
            }
        }

        pub fn get(self: *const Self) T {
            const raw = self.value.load(.monotonic);
            if (T == f64) {
                return @bitCast(raw);
            }
            return raw;
        }
    };
}

// ============================================================================
// histogram - value distribution with explicit buckets
// ============================================================================

pub fn Histogram(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        boundaries: []const f64,
        counts: []std.atomic.Value(u64),
        sum: std.atomic.Value(i64),
        count: std.atomic.Value(u64),
        min: std.atomic.Value(u64),
        max: std.atomic.Value(u64),
        allocator: std.mem.Allocator,

        /// OpenTelemetry default bucket boundaries
        pub const default_boundaries = [_]f64{ 0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000 };

        pub fn init(allocator: std.mem.Allocator, name: []const u8, opts: HistogramOptions) !Self {
            const boundaries = opts.boundaries orelse &default_boundaries;
            const counts = try allocator.alloc(std.atomic.Value(u64), boundaries.len + 1);
            for (counts) |*c| {
                c.* = std.atomic.Value(u64).init(0);
            }

            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .boundaries = boundaries,
                .counts = counts,
                .sum = std.atomic.Value(i64).init(0),
                .count = std.atomic.Value(u64).init(0),
                .min = std.atomic.Value(u64).init(std.math.maxInt(u64)),
                .max = std.atomic.Value(u64).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counts);
        }

        pub fn record(self: *Self, value: T, attributes: []const Attribute) void {
            _ = attributes;
            const val_f64: f64 = if (T == f64) value else @floatFromInt(value);

            // find bucket
            var bucket: usize = self.boundaries.len;
            for (self.boundaries, 0..) |bound, i| {
                if (val_f64 < bound) {
                    bucket = i;
                    break;
                }
            }

            _ = self.counts[bucket].fetchAdd(1, .monotonic);
            _ = self.sum.fetchAdd(@intFromFloat(val_f64), .monotonic);
            _ = self.count.fetchAdd(1, .monotonic);

            // update min/max
            const val_bits: u64 = @bitCast(val_f64);
            while (true) {
                const old_min = self.min.load(.monotonic);
                const old_min_f64: f64 = @bitCast(old_min);
                if (val_f64 >= old_min_f64) break;
                if (self.min.cmpxchgWeak(old_min, val_bits, .monotonic, .monotonic) == null) break;
            }
            while (true) {
                const old_max = self.max.load(.monotonic);
                const old_max_f64: f64 = @bitCast(old_max);
                if (val_f64 <= old_max_f64) break;
                if (self.max.cmpxchgWeak(old_max, val_bits, .monotonic, .monotonic) == null) break;
            }
        }

        pub fn getCount(self: *const Self) u64 {
            return self.count.load(.monotonic);
        }

        pub fn getSum(self: *const Self) f64 {
            return @floatFromInt(self.sum.load(.monotonic));
        }
    };
}

// ============================================================================
// exponential histogram - Base2 exponential bucket histogram
// ============================================================================

pub fn ExponentialHistogram(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        scale: i8,
        sum: std.atomic.Value(i64),
        count: std.atomic.Value(u64),
        zero_count: std.atomic.Value(u64),
        min: std.atomic.Value(u64),
        max: std.atomic.Value(u64),
        // positive bucket counts (simplified - fixed size)
        positive_counts: [256]std.atomic.Value(u64),
        positive_offset: i32,

        pub fn init(name: []const u8, opts: ExponentialHistogramOptions) Self {
            var self = Self{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .scale = opts.scale,
                .sum = std.atomic.Value(i64).init(0),
                .count = std.atomic.Value(u64).init(0),
                .zero_count = std.atomic.Value(u64).init(0),
                .min = std.atomic.Value(u64).init(std.math.maxInt(u64)),
                .max = std.atomic.Value(u64).init(0),
                .positive_counts = undefined,
                .positive_offset = 0,
            };
            for (&self.positive_counts) |*c| {
                c.* = std.atomic.Value(u64).init(0);
            }
            return self;
        }

        pub fn record(self: *Self, value: T, attributes: []const Attribute) void {
            _ = attributes;
            const val_f64: f64 = if (T == f64) value else @floatFromInt(value);

            if (val_f64 == 0) {
                _ = self.zero_count.fetchAdd(1, .monotonic);
            } else if (val_f64 > 0) {
                // compute bucket index using base2 exponential
                const scale_factor = std.math.pow(f64, 2, @as(f64, @floatFromInt(self.scale)));
                const bucket_idx: i32 = @intFromFloat(@ceil(@log2(val_f64) * scale_factor));
                const adjusted_idx: usize = @intCast(@max(0, @min(255, bucket_idx - self.positive_offset)));
                _ = self.positive_counts[adjusted_idx].fetchAdd(1, .monotonic);
            }

            _ = self.sum.fetchAdd(@intFromFloat(val_f64), .monotonic);
            _ = self.count.fetchAdd(1, .monotonic);

            // update min/max
            const val_bits: u64 = @bitCast(val_f64);
            while (true) {
                const old_min = self.min.load(.monotonic);
                const old_min_f64: f64 = @bitCast(old_min);
                if (val_f64 >= old_min_f64) break;
                if (self.min.cmpxchgWeak(old_min, val_bits, .monotonic, .monotonic) == null) break;
            }
            while (true) {
                const old_max = self.max.load(.monotonic);
                const old_max_f64: f64 = @bitCast(old_max);
                if (val_f64 <= old_max_f64) break;
                if (self.max.cmpxchgWeak(old_max, val_bits, .monotonic, .monotonic) == null) break;
            }
        }

        pub fn getCount(self: *const Self) u64 {
            return self.count.load(.monotonic);
        }

        pub fn getSum(self: *const Self) f64 {
            return @floatFromInt(self.sum.load(.monotonic));
        }
    };
}

// ============================================================================
// observable instruments (callback-based)
// ============================================================================

pub fn ObservableCallback(comptime T: type) type {
    return *const fn (observer: *Observer(T)) void;
}

pub fn Observer(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T = 0,
        attributes: [32]Attribute = undefined,
        attribute_count: usize = 0,

        pub fn observe(self: *Self, value: T, attributes: []const Attribute) void {
            self.value = value;
            self.attribute_count = @min(attributes.len, 32);
            @memcpy(self.attributes[0..self.attribute_count], attributes[0..self.attribute_count]);
        }
    };
}

pub fn ObservableCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        callback: ObservableCallback(T),

        pub fn init(name: []const u8, opts: InstrumentOptions, callback: ObservableCallback(T)) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .callback = callback,
            };
        }

        pub fn observe(self: *const Self) Observer(T) {
            var observer = Observer(T){};
            self.callback(&observer);
            return observer;
        }
    };
}

pub fn ObservableGauge(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        callback: ObservableCallback(T),

        pub fn init(name: []const u8, opts: InstrumentOptions, callback: ObservableCallback(T)) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .callback = callback,
            };
        }

        pub fn observe(self: *const Self) Observer(T) {
            var observer = Observer(T){};
            self.callback(&observer);
            return observer;
        }
    };
}

pub fn ObservableUpDownCounter(comptime T: type) type {
    return struct {
        const Self = @This();

        name: []const u8,
        description: []const u8,
        unit: []const u8,
        callback: ObservableCallback(T),

        pub fn init(name: []const u8, opts: InstrumentOptions, callback: ObservableCallback(T)) Self {
            return .{
                .name = name,
                .description = opts.description,
                .unit = opts.unit,
                .callback = callback,
            };
        }

        pub fn observe(self: *const Self) Observer(T) {
            var observer = Observer(T){};
            self.callback(&observer);
            return observer;
        }
    };
}

// ============================================================================
// convenience type aliases matching Rust API
// ============================================================================

pub const U64Counter = Counter(u64);
pub const F64Counter = Counter(f64);

pub const I64Gauge = Gauge(i64);
pub const U64Gauge = Gauge(u64);
pub const F64Gauge = Gauge(f64);

pub const I64UpDownCounter = UpDownCounter(i64);
pub const F64UpDownCounter = UpDownCounter(f64);

pub const U64Histogram = Histogram(u64);
pub const F64Histogram = Histogram(f64);

pub const U64ExponentialHistogram = ExponentialHistogram(u64);
pub const F64ExponentialHistogram = ExponentialHistogram(f64);

pub const U64ObservableCounter = ObservableCounter(u64);
pub const F64ObservableCounter = ObservableCounter(f64);

pub const I64ObservableGauge = ObservableGauge(i64);
pub const U64ObservableGauge = ObservableGauge(u64);
pub const F64ObservableGauge = ObservableGauge(f64);

pub const I64ObservableUpDownCounter = ObservableUpDownCounter(i64);
pub const F64ObservableUpDownCounter = ObservableUpDownCounter(f64);

// ============================================================================
// metric data for export
// ============================================================================

/// aggregation temporality for metric export
pub const AggregationTemporality = enum(u8) {
    unspecified = 0,
    delta = 1,
    cumulative = 2,
};

/// data point for sum/gauge metrics
pub const NumberDataPoint = struct {
    start_time_ns: i128,
    time_ns: i128,
    value: union(enum) {
        int: i64,
        double: f64,
    },
    attributes: []const Attribute = &.{},
};

/// data point for histogram metrics
pub const HistogramDataPoint = struct {
    start_time_ns: i128,
    time_ns: i128,
    count: u64,
    sum: f64,
    bucket_counts: []const u64,
    explicit_bounds: []const f64,
    min: f64,
    max: f64,
    attributes: []const Attribute = &.{},
};

/// data point for exponential histogram metrics
pub const ExponentialHistogramDataPoint = struct {
    start_time_ns: i128,
    time_ns: i128,
    count: u64,
    sum: f64,
    scale: i8,
    zero_count: u64,
    positive_offset: i32,
    positive_bucket_counts: []const u64,
    min: f64,
    max: f64,
    attributes: []const Attribute = &.{},
};

/// metric data for export
pub const MetricData = struct {
    name: []const u8,
    description: []const u8 = "",
    unit: []const u8 = "",
    data: union(enum) {
        sum: struct {
            data_points: []const NumberDataPoint,
            temporality: AggregationTemporality = .cumulative,
            is_monotonic: bool = true,
        },
        gauge: struct {
            data_points: []const NumberDataPoint,
        },
        histogram: struct {
            data_points: []const HistogramDataPoint,
            temporality: AggregationTemporality = .cumulative,
        },
        exponential_histogram: struct {
            data_points: []const ExponentialHistogramDataPoint,
            temporality: AggregationTemporality = .cumulative,
        },
    },
};

// ============================================================================
// tests
// ============================================================================

test "u64 counter" {
    var counter = U64Counter.init("test.counter", .{ .description = "test counter" });
    counter.add(5, &.{});
    counter.add(3, &.{});
    try std.testing.expectEqual(@as(u64, 8), counter.get());
}

test "i64 gauge" {
    var gauge = I64Gauge.init("test.gauge", .{});
    gauge.record(42, &.{});
    try std.testing.expectEqual(@as(i64, 42), gauge.get());
    gauge.record(-10, &.{});
    try std.testing.expectEqual(@as(i64, -10), gauge.get());
}

test "i64 up down counter" {
    var counter = I64UpDownCounter.init("test.updown", .{});
    counter.add(5, &.{});
    counter.add(-3, &.{});
    try std.testing.expectEqual(@as(i64, 2), counter.get());
}

test "f64 histogram" {
    var histogram = try F64Histogram.init(std.testing.allocator, "test.histogram", .{
        .boundaries = &[_]f64{ 10, 50, 100 },
    });
    defer histogram.deinit();

    histogram.record(5.0, &.{}); // bucket 0
    histogram.record(25.0, &.{}); // bucket 1
    histogram.record(75.0, &.{}); // bucket 2
    histogram.record(200.0, &.{}); // bucket 3 (overflow)

    try std.testing.expectEqual(@as(u64, 4), histogram.getCount());
}

test "exponential histogram" {
    var histogram = U64ExponentialHistogram.init("test.exp_histogram", .{ .scale = 10 });
    histogram.record(1, &.{});
    histogram.record(10, &.{});
    histogram.record(100, &.{});

    try std.testing.expectEqual(@as(u64, 3), histogram.getCount());
}

test "observable gauge" {
    const callback = struct {
        fn cb(observer: *Observer(i64)) void {
            observer.observe(42, &.{});
        }
    }.cb;

    const gauge = I64ObservableGauge.init("test.observable", .{}, callback);
    const result = gauge.observe();
    try std.testing.expectEqual(@as(i64, 42), result.value);
}
