//! basic logfire example
//!
//! demonstrates spans, logging, and export to logfire.
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

    // span with timing
    {
        const s = logfire.span("example.work", .{
            .iteration = @as(i64, 1),
        });
        defer s.end();

        // simulate some work
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms);

        logfire.info("work completed", .{});
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

    // flush to ensure all data is sent
    try lf.flush();

    logfire.info("example complete", .{});
}
