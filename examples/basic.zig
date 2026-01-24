//! basic logfire example
//!
//! demonstrates spans, logging, metrics, and export to logfire.
//!
//! run with:
//!   LOGFIRE_TOKEN=your_token zig build example
//!
//! or without token for console-only output:
//!   zig build example

const std = @import("std");
const logfire = @import("logfire");

pub fn main() !void {
    // configure logfire
    // will send to logfire if LOGFIRE_TOKEN is set, otherwise just prints
    const lf = try logfire.configure(.{
        .service_name = "logfire-zig-example",
        .service_version = "0.1.0",
        .environment = "development",
    });
    defer lf.shutdown();

    // simple logging
    logfire.info("application started", .{});
    logfire.debug("debug message with value: {d}", .{42});

    // span with timing and string attributes
    {
        const s = logfire.span("example.work", .{
            .iteration = @as(i64, 1),
            .query = "prefect python",
            .tag = "python",
        });
        defer s.end();

        // simulate some work
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms);

        logfire.info("work completed", .{});
    }

    // span with dynamic string (simulating arena-allocated query)
    {
        var buf: [64]u8 = undefined;
        const query = std.fmt.bufPrint(&buf, "search query {d}", .{42}) catch "fallback";

        const s = logfire.span("example.dynamic_string", .{
            .query = query,
        });
        defer s.end();

        std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
    }

    // span with special characters that might come from URL params
    {
        const s = logfire.span("example.special_chars", .{
            .query = "hello \"world\" & <test>",
            .unicode = "café résumé naïve",
            .control = "tab\there\nnewline",
        });
        defer s.end();
    }

    // nested spans
    {
        const outer = logfire.span("example.outer", .{});
        defer outer.end();

        {
            const inner = logfire.span("example.inner", .{
                .depth = @as(i64, 1),
            });
            defer inner.end();

            std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
        }
    }

    // metrics
    logfire.counter("requests.total", 1);
    logfire.counter("requests.total", 1);
    logfire.gaugeInt("connections.active", 42);
    logfire.gaugeDouble("cpu.usage", 0.75);

    // flush to ensure all data is sent
    try lf.flush();

    logfire.info("example complete", .{});
}
