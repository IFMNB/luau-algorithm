# parallel-api

A shared action bus for parallel [Luau](https://luau.org/) built on `SharedTable`.

`parallel-api` lets several Luau VMs — for example scripts running under `Actor` instances — publish actions into a named registry, subscribe to topics locally, and process pending actions without a central dispatcher. The registry records which VMs have read and processed each action, while every VM keeps its own subscriptions and callbacks.

## Features

* Named registries backed by `SharedTable` and `SharedTableRegistry`
* Topic subscriptions, including the `"*"` wildcard
* Optional parallel callbacks executed under `task.desynchronize`
* Automatic sanitisation of values that `SharedTable` cannot store
* Reader presence tracking with `last_seen`
* Processed-by tracking with an O(1) counter
* TTL cleanup for actions nobody claimed
* Background heartbeat started when the module is required
* Strict typing, native code generation and `--!optimize 2`
* No central publisher or server script required

## Requirements

* A Roblox Luau runtime with `SharedTable`, `SharedTableRegistry`, `HttpService` and `task`
* Support for `--!native` (annotation only; execution still works without it)

The plain Luau CLI does not provide `SharedTable`, so the test suite runs the module against minimal fakes.

## Installation

This package lives in the `LuauAlgorithm` monorepo at `src/parallel-api`. Add the package directory as a path dependency or copy it into your project, then require the module:

```lua
local parallel_api = require(path.to.parallel_api)
```

The Crater manifest points at `src/api.luau` as the package entry point. You can also use `crater add ifmnb/parallel-api^`.

## Quick start

```lua
--!strict

local parallel_api = require(path.to.parallel_api)

local registry = parallel_api:fetch_registry("my-game/actions")

local connection = parallel_api:subscribe("damage", function(action)
	local content = action.content

	if content ~= nil then
		print(content.target, content.amount)
	end
end)

parallel_api:publish("damage", {
	target = "boss",
	amount = 25,
}, registry)

-- The heartbeat normally does this once per frame. Calling it manually
-- delivers pending actions immediately.
parallel_api:process(registry)
```

## Core concepts

### Registry

A registry is a named `SharedTable` with these fields:

| Field      | Description                                       |
| ---------- | ------------------------------------------------- |
| `events`   | Published actions, keyed by action id             |
| `readers`  | Known readers, keyed by `luau_instance_marker`    |
| `sequence` | Last sequence number handed out by `publish`      |
| `path`     | Name of the registry in `SharedTableRegistry`     |
| `source`   | Marker of the VM that created the registry        |

`fetch_registry` is idempotent: it returns the existing registry and refreshes the current reader. Calling it without an argument uses `@IFMNB/registry`.

### Reader

Every VM gets a unique `luau_instance_marker`. A reader stored in `registry.readers` contains:

* `luau_instance_marker` — the VM marker;
* `attributes` — optional user data set with `set_reader_attributes`;
* `last_seen` — the last refresh time in Unix seconds.

Readers refresh at most once every 5 seconds. Explicit `fetch_registry` and `set_reader_attributes` calls force a refresh. Readers that have not refreshed for 30 seconds are removed by cleanup, and their markers are removed from pending actions.

### Action

An action is a `SharedTable` with:

* `topic` — the topic it was published to;
* `content` — the sanitised payload;
* `who_readed` — readers that started processing it;
* `who_processed` — readers that finished processing it;
* `processed_count` — number of readers in `who_processed`;
* `sequence` — publication order inside the registry;
* `source` — marker of the publishing VM;
* `created_at` — publication time in Unix seconds.

Action ids have the form `{luau_instance_marker}:{sequence}`.

### Delivery

`process` collects actions that the current reader has not processed, sorts them by `sequence`, and delivers them in that order. An action is marked as processed before its callbacks run, so callbacks receive a payload that already contains the current reader, and a callback that throws is not retried on every pass.

An action is deleted when every current reader has processed it. If the registry has no readers at all, nothing can be considered processed, so the action expires by TTL instead. Actions that no VM claimed are deleted after 300 seconds. If a VM has no local subscribers at all, `process` skips the scan and only runs cleanup.

### Heartbeat

Requiring the module starts a background loop:

```lua
task.defer(function()
	while alive do
		task.wait()
		-- process every registry known to this VM
	end
end)
```

The heartbeat processes known registries once per frame and runs cleanup at most once per second. Errors are reported with `warn` and do not stop the loop. Call `destroy` to stop it.

## API

### Fields

| Field                    | Type                    | Description                                              |
| ------------------------ | ----------------------- | -------------------------------------------------------- |
| `unsupported_marker`     | `string`                | Replacement for values `SharedTable` cannot store        |
| `luau_instance_marker`   | `string`                | Unique marker of the current VM                          |
| `luau_parallel`          | `boolean`               | `true` when `task.desynchronize` is available            |
| `luau_reader_template`   | `luau_reader`           | Frozen reader template                                   |
| `action_template`        | `action`                | Frozen action template                                   |
| `registry_template`      | `registry_template`     | Frozen registry template                                 |

### `fetch_registry`

```lua
parallel_api:fetch_registry(override_sharedtable_path: string?): registry
```

Returns the named registry, creating and initialising it when needed. The current reader is registered in `registry.readers`. An empty path is rejected.

### `delete_registry`

```lua
parallel_api:delete_registry(...registry)
```

Unregisters the given registries from `SharedTableRegistry`, removes the current reader from them, and forgets its markers in pending actions. Only registries whose `source` matches the current VM can be deleted. VMs that already hold a reference to the registry keep using that table until they fetch the path again, at which point they get a fresh registry. Use this for teardown, not for routine cleanup.

### `get_reader`

```lua
parallel_api:get_reader(): luau_reader
```

Returns a detached copy of the current reader snapshot, including sanitised attributes.

### `set_reader_attributes`

```lua
parallel_api:set_reader_attributes(attributes: { read unknown }?)
```

Replaces the attributes of the current reader in every registry known to this VM. Passing `nil` clears them. Attributes go through the same sanitisation as action content.

### `publish`

```lua
parallel_api:publish(topic: string, content: { read unknown }?, registry: registry?): string
```

Publishes an action and returns its id. When `registry` is omitted, the default registry is used. The topic must be a non-empty string; `content` must be a table or `nil`.

### `subscribe`

```lua
parallel_api:subscribe(
	topic: string,
	callback: (action: action) -> (),
	parallel: boolean?
): connection
```

Registers a local callback. The topic `"*"` receives every topic. Subscribing the same function to the same topic twice keeps a single callback; disconnecting either connection removes it.

`parallel = true` marks the callback as safe for parallel execution. When `luau_parallel` is `true`, the callback is invoked after `task.desynchronize` and the VM returns to the synchronous phase afterwards.

### `process`

```lua
parallel_api:process(registry: registry?): number
```

Delivers pending actions and returns the number of actions for which at least one callback ran. Without an argument, every registry known to this VM is processed. Cleanup runs as part of this call.

### `destroy`

```lua
parallel_api:destroy()
```

Stops the heartbeat, removes the current reader from known registries, forgets its processed markers, and clears local subscriptions. Registries themselves are not deleted. Calling `destroy` repeatedly is safe.

### `connection`

```lua
connection:disconnect()
connection:is_connected(): boolean
```

`disconnect` removes the callback from the local subscriber list. `is_connected` returns `true` while the callback is still subscribed.

## Payload sanitisation

`SharedTable` supports a limited set of values. Before an action or reader is stored, nested tables are converted to nested `SharedTable`s and every unsupported value is replaced with `unsupported_marker`.

Supported values are `nil`, booleans, numbers, strings, Luau vectors, `SharedTable`s, and the Roblox value types accepted by `SharedTable` (CFrame, Vector2/Vector3, Color3, UDim/UDim2, NumberSequence, EnumItem, DateTime, and so on). Functions, threads, userdata, Instances and other unsupported values become `unsupported_marker`.

Table keys must be strings or non-negative integers below `2^32`; all other keys are dropped. Cyclic tables are preserved with a shared `SharedTable` for each table, and decoded back into cyclic plain tables for callbacks.

Because the marker is a normal string, a payload string equal to `unsupported_marker` is indistinguishable from a replaced value.

## Lifecycle and timing

The timing constants are private and fixed at runtime:

| Constant           | Value | Meaning                                            |
| ------------------ | ----- | -------------------------------------------------- |
| `reader_refresh`   | 5 s   | Minimum interval between `last_seen` writes         |
| `reader_timeout`   | 30 s  | A reader without a refresh for this long is removed |
| `event_ttl`        | 300 s | Unprocessed actions expire after this long          |
| `cleanup_interval` | 1 s   | Heartbeat cleanup frequency                         |

Cleanup removes stale readers first, then drops their markers from every action and decrements `processed_count` accordingly. This keeps the counter equal to the number of current readers that processed the action.

## Multiple VMs

Each VM requires the module independently and receives its own `luau_instance_marker`, local subscriptions and private state. Registries are shared through `SharedTableRegistry`, so all VMs see the same `events` and `readers` tables.

```lua
-- Actor script A
local registry = parallel_api:fetch_registry("work")
parallel_api:subscribe("job", function(action)
	-- handle the job
end)

-- Actor script B
local registry = parallel_api:fetch_registry("work")
parallel_api:publish("job", { id = 7 }, registry)
```

Both VMs process the same action once, and the action is deleted after both have marked it as processed. When a new VM joins late, it does not receive actions that were already deleted after the old readers finished them.

## Types

The module exports:

* `luau_reader<T>` — reader snapshot;
* `action<T>` — published action;
* `registry_template<T, U>` — plain-table description of a registry;
* `registry` — `SharedTable & registry_template`;
* `connection` — subscription handle;
* `library` — public module surface.

The public types describe nested shared values as plain tables for ergonomics. At runtime they are `SharedTable`s; use the library methods instead of mutating them directly.

## Performance

The hot paths avoid repeated work:

* `processed_count` makes the “all readers processed” check O(1);
* the reader marker set is built once per `process`/cleanup pass;
* actions are deleted immediately after dispatch when they are fully processed;
* a VM without local subscribers skips the event scan and sort entirely;
* cleanup is throttled in the heartbeat, and the pending-entry comparator is hoisted.

Local benchmarks against the fake `SharedTable` (single-threaded Luau CLI, `-O2 --codegen`) give roughly:

* `publish` of a small table: ~1.9 µs per call;
* `process` of 10 000 small actions: ~3.4 µs per action;
* `process` of 1 000 unclaimed actions: ~26–31 µs per call, nearly independent of reader count;
* `process` of 1 000 fully processed actions with 51 readers: ~0.1–0.15 ms per call.

These numbers measure library overhead, not real shared-memory access, so treat them as relative guidance rather than Roblox timings.

## Limitations

* `process` still scans every event in the registry: O(events). A sequence or topic watermark would be needed for very large registries, and it would change late-subscriber and TTL behaviour.
* Delivery order is defined per registry by `sequence`; there is no global ordering across registries.
* Late subscribers do not replay actions that were already processed by every reader at the time of joining.
* Expiration only happens while some VM runs the heartbeat or calls `process`.
* Callback errors are reported with `warn`; the action is still considered processed.
* The module depends on Roblox-only services (`SharedTable`, `SharedTableRegistry`, `HttpService`).

## Testing

The `ci` directory contains the harness used during development:

```sh
cd src/parallel-api
python3 ci/run.py --luau /path/to/luau
```

`run.py` builds a temporary chunk from:

* `ci/preamble.luau` — fake `SharedTable`, registry, `HttpService`, `task` and clock;
* `src/api.luau` — the real module source;
* `ci/tests.luau` — behaviour tests.

The suite runs twice: with a lenient `SharedTable.update` and with a strict one that rejects missing keys. It covers publishing, sanitisation, ordering, wildcards, parallel callbacks, failing callbacks, TTL expiry, reader refresh, multi-reader removal, stale-reader cleanup, `delete_registry`, `destroy`, and two simulated VMs sharing a registry.

## License

MPLv2 — see [LICENSE.md](../../LICENSE.md).
