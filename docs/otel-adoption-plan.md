# otel-zig adoption plan

## status: in progress (2025-01-25)

this document explores how logfire-zig should adopt [otel-zig](https://github.com/ibd1279/otel-zig) to become a proper OpenTelemetry-based observability library.

## background

### current state of logfire-zig

logfire-zig is currently a standalone OTLP exporter with:
- simple span/log API
- OTLP HTTP/JSON export to Logfire
- token-based configuration (Logfire-specific)
- background flush thread

it does NOT have:
- full OTel API/SDK compliance
- semantic conventions
- context propagation (W3C traceparent)
- metrics support (partial - types exist but incomplete)
- pipeline architecture

### python logfire architecture

python logfire wraps opentelemetry-python:

```
opentelemetry-python (API/SDK)
    +-- opentelemetry-instrumentation-* (ecosystem plugins)
    +-- logfire (wrapper + Logfire-specific config)
```

this means:
- instrumentation plugins work for ALL OTel users
- logfire users get ecosystem plugins for free
- logfire adds value through config, dashboards, hosted backend

### otel-zig

[otel-zig](https://github.com/ibd1279/otel-zig) by ibd1279 is a comprehensive OTel implementation.

**zig version:** 0.15.1 (compatible with logfire-zig's 0.15.0 requirement)

## findings

### logfire-zig implementation analysis

**architecture:** 6 modules (root, config, span, log, attribute, exporter, metrics) with a central `Logfire` singleton.

**core types:**
- `Logfire` - singleton managing all observability, background flush thread
- `Span.Data` - immutable span with trace_id, span_id, parent, timestamps, 32 max attributes
- `LogRecord` - severity, message, trace correlation, attributes
- `Attribute` - tagged union with internal string storage (512 bytes) for copy safety
- `MetricData` - union of sum/gauge/histogram/exponential_histogram

**threading model:**
- thread-local trace context (`threadlocal var tl_trace_id`, `tl_current_span_id`)
- background flush thread (configurable interval)
- mutex-protected pending lists
- atomic span ID counter

**OTLP export:**
- HTTP/JSON only (no protobuf, no gRPC)
- per-endpoint batching (/v1/traces, /v1/logs, /v1/metrics)
- uses `std.json.Stringify` for streaming JSON generation
- special handling for hex trace IDs, nanosecond timestamps

**limitations vs full OTel:**
1. no trace links or span events
2. no span status (always UNSET)
3. no resource detection
4. no W3C traceparent propagation
5. metrics attributes ignored
6. no sampling
7. no pipeline architecture (processor -> exporter)
8. 32 attribute limit, 512 byte string limit
9. no semantic conventions

**strengths:**
- simple, focused API
- memory-safe attribute handling (internal string storage)
- working background export
- Logfire-specific token handling

### otel-zig implementation analysis

**architecture:** proper OTel structure with api/, sdk/, exporters/, semconv/ separation.

**core types:**
- `Span`, `Tracer`, `TracerProvider` - union-tagged for noop/bridge polymorphism
- `LogRecord`, `Logger`, `LoggerProvider` - same pattern
- `Meter`, `MeterProvider`, `Counter`, `Gauge`, `Histogram` - full metrics
- `SpanContext` - trace_id, span_id, trace_flags, trace_state, is_remote

**pipeline architecture:**
```
Provider -> Processor -> Exporter
```
- traces: TracerProvider -> SpanProcessor -> SpanExporter
- logs: LoggerProvider -> LogRecordProcessor -> LogRecordExporter
- metrics: MeterProvider -> Reader -> MetricExporter
- fluent pipeline builder pattern at compile time

**OTLP export:**
- protobuf-based (using zig-protobuf dependency)
- HTTP transport (gRPC/JSON configurable)
- proper conversion from Zig types to OTLP messages

**semantic conventions:**
- comprehensive coverage (v1.24.0)
- http, database, rpc, messaging, exception, network, resource
- standard constant values

**W3C context propagation:**
- traceparent header injection/extraction
- TextMapCarrier abstraction
- marks remote contexts properly

**maturity: ~70-75% production-ready**

known gaps (per TODO.md):
- trace state parsing incomplete (potential leak)
- thread-local context storage not implemented
- histogram configurations incomplete
- parent sampling decorator incomplete

**strengths:**
- proper API/SDK separation
- all three signals (traces, logs, metrics)
- thread-safe implementations
- no-op implementations for safety
- std.log bridge
- comprehensive tests

## comparison

| aspect | logfire-zig | otel-zig |
|--------|-------------|----------|
| zig version | 0.15.0 | 0.15.1 |
| spec compliance | minimal | ~80% |
| API/SDK separation | no | yes |
| semantic conventions | none | comprehensive |
| context propagation | threadlocal only | W3C traceparent |
| OTLP format | HTTP/JSON | HTTP/protobuf |
| pipeline architecture | no | yes |
| metrics support | partial | full |
| std.log bridge | no | yes |
| spans | working | working |
| logs | working | working |
| maturity | simple/focused | comprehensive |
| Logfire-specific | yes (token, endpoint) | no |

## recommendation

**adopt otel-zig as a dependency** rather than reimplementing.

### rationale

1. **otel-zig is already 70-75% production-ready** - reimplementing would take months
2. **proper architecture** - API/SDK separation enables future extensibility
3. **semantic conventions** - we get http, database, messaging, etc. for free
4. **W3C propagation** - distributed tracing across services
5. **ecosystem potential** - instrumentation plugins can target otel-zig API
6. **same zig version** - no compatibility concerns

### what logfire-zig becomes

1. **thin wrapper around otel-zig**
2. **Logfire-specific configuration** (token parsing, endpoint selection)
3. **Logfire OTLP exporter** (configured otel-zig exporter pointing to Logfire)
4. **convenience APIs** (optional simpler interface for common cases)

### migration path

**phase 1: add otel-zig dependency**
- add to build.zig.zon
- verify builds and tests pass
- verify OTLP export works with Logfire endpoint

**phase 2: refactor internals**
- replace `Span.Data` with otel-zig spans
- replace `LogRecord` with otel-zig logs
- replace `MetricData` with otel-zig metrics
- keep `Config` for Logfire-specific settings
- use otel-zig pipeline architecture

**phase 3: update public API**
- option A: keep simple API, wrap otel internally
  ```zig
  // current API preserved
  const span = logfire.span("http.request", .{ .method = "GET" });
  defer span.end();
  ```
- option B: expose otel API with convenience wrapper
  ```zig
  // full otel access when needed
  var tracer = logfire.getTracer();
  var span = tracer.startSpan("http.request", .{...}, ctx);
  ```

**phase 4: deprecate redundant code**
- remove custom OTLP JSON serialization (use otel-zig protobuf)
- remove custom span/log types
- keep only Logfire-specific additions

### risks and mitigations

| risk | mitigation |
|------|------------|
| otel-zig protobuf may not work with Logfire | Logfire accepts OTLP protobuf; test early |
| otel-zig API may change | pin to specific commit/version |
| maintenance burden | contribute fixes upstream |
| otel-zig abandoned | fork if necessary (MIT licensed) |

### open questions

1. **should we contribute instrumentation plugins to otel-zig?**
   - http server instrumentation
   - database instrumentation
   - or separate zig-otel-contrib repo?

2. **how much of current logfire-zig API to preserve?**
   - simpler API is nice for quick usage
   - but full otel API enables advanced use cases

3. **should we help complete otel-zig's gaps?**
   - thread-local context storage
   - trace state handling
   - histogram configurations

## next steps

1. [x] add otel-zig as dependency in build.zig.zon
2. [x] test OTLP export to Logfire endpoint (validated with `zig build validate-otel`)
3. [x] prototype wrapper API (`src/otel_wrapper.zig`, exposed as `logfire-otel` module)
4. [ ] benchmark performance vs current implementation
5. [ ] complete wrapper API (logs, metrics)
6. [ ] create migration PR

## appendix: key otel-zig files to understand

- `src/api/trace/span.zig` - span interface
- `src/sdk/trace/root.zig` - tracer provider setup
- `src/exporters/otlp/root.zig` - OTLP exporter config
- `src/semconv/http.zig` - HTTP semantic conventions
- `src/api/trace/w3c_propagator.zig` - context propagation
- `examples/simple_trace_sdk.zig` - usage example
