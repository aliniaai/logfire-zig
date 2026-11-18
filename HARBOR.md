# harbor's fork of logfire-zig

- **Branch `harbor`** is what [aliniaai/harbor](https://github.com/aliniaai/harbor) builds,
  as the submodule `services/moderations/vendor/logfire-zig`: upstream's 0.4.0 (`81e2b57`)
  plus harbor's changes, never upstreamed. `git log 81e2b57..harbor` is the list.
- **It builds inside harbor's layout:** its `opentelemetry` dependency is `../otel-zig`, the
  sibling submodule ([aliniaai/otel-zig](https://github.com/aliniaai/otel-zig), branch
  `harbor`), so harbor builds one otel-zig, the one it tests.
- **Origin:** <https://tangled.org/zzstoatzz.io/logfire-zig>. MIT, by its [README](README.md)
  (upstream ships no `LICENSE` file).
- `main` and `batched-export` here are earlier, separate work; `harbor` does not use them.
