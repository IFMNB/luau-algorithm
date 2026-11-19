# Changelog

All notable changes to `parallel-api` are documented in this file.

## [0.1.0] - 2026-11-20

### Added

* Initial shared action bus built on `SharedTable` and `SharedTableRegistry`.
* Named registries with `fetch_registry` and `delete_registry`.
* Reader registration with `luau_instance_marker`, attributes and `last_seen`.
* Topic subscriptions, including the `"*"` wildcard.
* Optional parallel callbacks executed under `task.desynchronize`.
* `publish`, `process`, `subscribe`, `get_reader`, `set_reader_attributes` and `destroy`.
* Payload sanitisation: unsupported values become `unsupported_marker`, unsupported keys are dropped, cyclic tables are preserved.
* Action metadata: `who_readed`, `who_processed`, `processed_count`, `sequence`, `source` and `created_at`.
* Automatic heartbeat that processes known registries and cleans them up.
* Stale-reader removal and TTL expiration for unclaimed actions.
* Strict public types, `--!native` and `--!optimize 2`.
* Test harness in `ci/` with fake Roblox services and a configurable `SharedTable.update` implementation.
* README with installation, API reference, lifecycle notes and limitations.

### Changed

* Actions are marked as processed before callbacks run, so failing callbacks are not retried every pass.
* Reader markers are removed from pending actions when a reader leaves, keeping `processed_count` in sync with current readers.
* `process` skips the event scan and sort when the VM has no local subscribers, but still runs cleanup.
* Heartbeat cleanup is throttled independently from action delivery.
* Action deletion happens immediately after dispatch when every reader has processed the action.

### Performance

* The “processed by all readers” check is O(1) through `processed_count`, with a `who_processed` fallback for actions published before the counter existed.
* The reader marker set is built once per `process`/cleanup pass instead of once per action.
* The pending-entry sort comparator is hoisted to a shared function.
* Pending entries no longer allocate a frozen table per action.

Local fake-`SharedTable` benchmarks:

* `process` of 1 000 unclaimed actions improved from ~610 µs to ~26–31 µs per call.
* `process` of 1 000 fully processed actions with 51 readers improved from ~543 µs to ~115 µs per call.
* The unclaimed path is roughly 20× faster than the first implementation.

[0.1.0]: https://github.com/IFMNB/luau-algorithm
