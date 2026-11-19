--!strict
--!native
--!optimize 2

--[[
	parallel-api — a small shared action bus for parallel Luau.

	Every Luau VM (usually a script under an `Actor`) gets a unique
	`luau_instance_marker`. A `registry` is a named `SharedTable` that stores:

	  * `events`   — map `action_id -> action`;
	  * `readers`  — map `marker -> luau_reader`;
	  * `sequence` — monotonically increasing action counter;
	  * `path`     — name in `SharedTableRegistry`;
	  * `source`   — marker of the VM that created the registry.

	`publish` appends an action, `subscribe` registers a local callback by
	topic, and `process` (also called by the background heartbeat) delivers
	pending actions to local subscribers and records the local reader in
	`who_readed` / `who_processed`.

	`SharedTable` supports only a subset of Luau values. Values that cannot be
	stored (functions, Instances, userdata, ...) are replaced with
	`unsupported_marker`. Unsupported table keys are dropped.

	The nested `events` / `readers` / `who_*` values are represented as plain
	tables in the public types for ergonomics, but at runtime they are
	`SharedTable` objects. Use the library methods instead of mutating them
	directly.

	Readers refresh their `last_seen` every few seconds. Readers that stop
	refreshing are removed after `reader_timeout`; actions that nobody
	processed are removed after `event_ttl`.
]]

const SharedTableRegistry = game:GetService("SharedTableRegistry")

--[[
	One Luau VM registered in a registry. `last_seen` is a Unix timestamp in
	seconds and is refreshed by the heartbeat.
]]
export type luau_reader<T = { read unknown }> = {
	--[[
		Unique marker of the VM that owns this reader.
	]]
	read luau_instance_marker: string,

	--[[
		User-defined data attached with `set_reader_attributes`.
	]]
	read attributes: T?,

	--[[
		Last time this reader refreshed itself, in Unix seconds.
	]]
	read last_seen: number,
}

--[[
	A single published message. `who_readed` and `who_processed` map reader
	markers to reader snapshots, so other VMs can see who has already received
	the action.
]]
export type action<T = { read unknown }> = {
	--[[
		Topic the action was published to.
	]]
	read topic: string,

	--[[
		Sanitised payload passed to `publish`.
	]]
	read content: T?,

	--[[
		Readers that have started processing the action.
	]]
	read who_readed: { read [string]: luau_reader },

	--[[
		Readers that have finished processing the action.
	]]
	read who_processed: { read [string]: luau_reader },

	--[[
		Number of readers that have marked the action as processed. Kept as a
		counter so `is_processed_by_all` is O(1) instead of walking every
		reader for every action.
	]]
	read processed_count: number,

	--[[
		Monotonically increasing position of the action in the registry.
	]]
	read sequence: number,

	--[[
		Marker of the VM that published the action.
	]]
	read source: string,

	--[[
		Publication time, in Unix seconds.
	]]
	read created_at: number,
}

--[[
	Plain-table description of a registry. At runtime a registry is a
	`SharedTable`, so `registry` is the intersection of both.
]]
export type registry_template<T = { read unknown }, U = { read unknown }> = {
	--[[
		Published actions, keyed by action id.
	]]
	read events: { read [string]: action<T> },

	--[[
		Known readers, keyed by `luau_instance_marker`.
	]]
	read readers: { read [string]: luau_reader<U> },

	--[[
		Last sequence number handed out by `publish`.
	]]
	read sequence: number,

	--[[
		Name of the registry in `SharedTableRegistry`.
	]]
	read path: string,

	--[[
		Marker of the VM that created the registry.
	]]
	read source: string,
}

--[[
	A registry is a `SharedTable` with the fields described by
	`registry_template`. Access it through the library methods.
]]
export type registry = SharedTable & registry_template

--[[
	Handle returned by `subscribe`. Call `disconnect` to stop receiving
	actions for that subscription.
]]
export type connection = {
	--[[
		Removes the callback from the local subscriber list.
	]]
	read disconnect: (self: connection) -> (),

	--[[
		Returns `true` while the callback is still subscribed.
	]]
	read is_connected: (self: connection) -> boolean,
}

--[[
	Public API of the module.
]]
export type library = {
	--[[
		Replaces values that cannot be stored in a `SharedTable`.
	]]
	read unsupported_marker: string,

	--[[
		Unique marker of the current Luau VM.
	]]
	read luau_instance_marker: string,

	--[[
		`true` when the current script can use `task.desynchronize`.
	]]
	read luau_parallel: boolean,

	--[[
		Frozen template of a reader.
	]]
	read luau_reader_template: luau_reader,

	--[[
		Frozen template of an action.
	]]
	read action_template: action,

	--[[
		Frozen template of a registry.
	]]
	read registry_template: registry_template,

	--[[
		Returns the named registry, creating and initialising it when needed.
		The current reader is registered in `registry.readers`.
	]]
	read fetch_registry: (self: library, override_sharedtable_path: string?) -> registry,

	--[[
		Unregisters the given registries from `SharedTableRegistry`. Only
		registries created by this VM (matching `source`) can be deleted.
	]]
	read delete_registry: (self: library, ...registry) -> (),

	--[[
		Returns a snapshot of the current reader.
	]]
	read get_reader: (self: library) -> luau_reader,

	--[[
		Replaces the attributes stored for the current reader in every known
		registry. Attributes are sanitised like action content.
	]]
	read set_reader_attributes: (self: library, attributes: { read unknown }?) -> (),

	--[[
		Publishes an action and returns its id. When `registry` is omitted, the
		default registry is used.
	]]
	read publish: (self: library, topic: string, content: { read unknown }?, registry: registry?) -> string,

	--[[
		Subscribes to a topic. `parallel = true` marks the callback as safe to
		run in a parallel context; `process` will try to desynchronise before
		calling it when the VM supports parallel execution.
	]]
	read subscribe: (
		self: library,
		topic: string,
		callback: (action: action) -> (),
		parallel: boolean?
	) -> connection,

	--[[
		Delivers pending actions to local subscribers. When `registry` is
		omitted, every registry known to this VM is processed. Returns the
		number of actions delivered.
	]]
	read process: (self: library, registry: registry?) -> number,

	--[[
		Stops the heartbeat, removes the current reader from known registries
		and clears local subscriptions. Registries themselves are not deleted.
	]]
	read destroy: (self: library) -> (),
}

--[[
	Action waiting to be dispatched, paired with its registry id and sequence
	so pending actions can be delivered in publication order.
]]
type pending_entry = {
	read id: string,
	read action: SharedTable,
	read sequence: number,
}

const private = {
	--[[
		Default name of the registry in `SharedTableRegistry`.
	]]
	path = "@IFMNB/registry",

	--[[
		Value written instead of anything that `SharedTable` cannot store.
	]]
	unsupported_marker = "SJKF@#90DSJFOSDUf23jSDFSDYf#@H$khfdsdyFIK@Y#$OuspfdjWEfg8203iriJSF()*()@reipaWUCD(@!E!@S:LDu980UT98l32hOf98UFOU@(*#rkSDSHF(*@U#(*LKJHDS*(FUAS(*f7(#Q&UR_random_string",

	--[[
		Readers that have not refreshed for this many seconds are removed.
	]]
	reader_timeout = 30,

	--[[
		Minimum interval between two `last_seen` writes for the same reader.
	]]
	reader_refresh = 5,

	--[[
		Unprocessed actions are removed after this many seconds.
	]]
	event_ttl = 300,

	--[[
		How often the heartbeat runs registry cleanup. Explicit `process`
		calls always clean up.
	]]
	cleanup_interval = 1,

	--[[
		Unique marker of the current Luau VM.
	]]
	luau_instance_marker = game:GetService("HttpService"):GenerateGUID(false),

	--[[
		`true` when `task.desynchronize` is available in this VM.
	]]
	luau_parallel = pcall(function(...)
		task.desynchronize()
		task.synchronize()
	end),

	--[[
		Mutable per-VM state. `attributes` is shared by every registry this VM
		knows about.
	]]
	state = {
		alive = true,
		attributes = nil,
	},

	--[[
		Known registries, keyed by path.
	]]
	init = {},

	--[[
		Local subscribers for synchronous callbacks, keyed by topic.
	]]
	sync = {} :: { [string]: { [(action) -> ()]: boolean } },

	--[[
		Local subscribers for parallel callbacks, keyed by topic.
	]]
	prll = {} :: { [string]: { [(action) -> ()]: boolean } },

	--[[
		Last cleanup time per registry path, in Unix seconds.
	]]
	cleanup_at = {} :: { [string]: number },
}

--[[
	The single public instance returned by this module.
]]
const library: library = {
	unsupported_marker = private.unsupported_marker,
	luau_instance_marker = private.luau_instance_marker,
	luau_parallel = private.luau_parallel,

	luau_reader_template = table.freeze({
		luau_instance_marker = "",
		attributes = nil,
		last_seen = 0,
	}) :: luau_reader,

	action_template = table.freeze({
		topic = "",
		content = nil,
		who_readed = table.freeze({}),
		who_processed = table.freeze({}),
		processed_count = 0,
		sequence = 0,
		source = "",
		created_at = 0,
	}) :: action,

	registry_template = table.freeze({
		events = table.freeze({}),
		readers = table.freeze({}),
		sequence = 0,
		path = "",
		source = private.luau_instance_marker,
	}) :: registry_template,

	fetch_registry = function(self: library, override_sharedtable_path: string?): registry
		assert(private.self == self, "received incorrect library")
		assert(private.state.alive, "library was destroyed")
		assert(
			override_sharedtable_path == nil
				or (type(override_sharedtable_path) == "string" and override_sharedtable_path ~= ""),
			"received incorrect sharedtable path"
		)

		const path = override_sharedtable_path or private.path
		const registry = SharedTableRegistry:GetSharedTable(path) :: registry

		private.touch(self, registry, path, true)

		return registry
	end,

	delete_registry = function(self: library, ...: registry): ()
		assert(private.self == self, "received incorrect library")

		for _, v in { ... } do
			assert(typeof(v) == "SharedTable", "received non-sharedtable value")
			assert(type(v.path) == "string" and v.path ~= "", "path is not a non-empty string")
			assert(v.source == nil or v.source == self.luau_instance_marker, "registry was not created by this VM")

			const readers = v.readers :: any

			if typeof(readers) == "SharedTable" then
				private.forget_reader(v, self.luau_instance_marker)
				readers[self.luau_instance_marker] = nil
			end

			SharedTableRegistry:SetSharedTable(v.path, nil)
			private.init[v.path] = nil
			private.cleanup_at[v.path] = nil
		end
	end,

	get_reader = function(self: library): luau_reader
		assert(private.self == self, "received incorrect library")

		const reader: any = private.snapshot_reader(self)
		reader.attributes = private.copy(reader.attributes)

		return reader
	end,

	set_reader_attributes = function(self: library, attributes: { read unknown }?): ()
		assert(private.self == self, "received incorrect library")
		assert(private.state.alive, "library was destroyed")
		assert(attributes == nil or type(attributes) == "table", "attributes must be a table or nil")

		private.state.attributes = private.copy(attributes)

		for path, registry in private.init do
			private.touch(self, registry, path, true)
		end
	end,

	publish = function(self: library, topic: string, content: { read unknown }?, registry: registry?): string
		assert(private.self == self, "received incorrect library")
		assert(private.state.alive, "library was destroyed")
		assert(type(topic) == "string" and topic ~= "", "topic must be a non-empty string")
		assert(content == nil or type(content) == "table", "content must be a table or nil")

		const target = registry or self:fetch_registry()
		assert(typeof(target) == "SharedTable", "received non-sharedtable registry")

		const path = if type(target.path) == "string" and target.path ~= "" then target.path else private.path
		private.touch(self, target, path)

		const sequence = SharedTable.increment(target, "sequence", 1) + 1
		const id = `{self.luau_instance_marker}:{sequence}`

		const stored: any = SharedTable.new()
		stored.topic = topic
		stored.sequence = sequence
		stored.source = self.luau_instance_marker
		stored.created_at = os.time()
		stored.who_readed = SharedTable.new()
		stored.who_processed = SharedTable.new()
		stored.processed_count = 0

		if content ~= nil then
			const encoded = private.encode(content)
			const ok = pcall(function()
				stored.content = encoded
			end)

			if not ok then
				stored.content = self.unsupported_marker
			end
		end

		const events = target.events :: any
		events[id] = stored

		return id
	end,

	subscribe = function(
		self: library,
		topic: string,
		callback: (action: action) -> (),
		parallel: boolean?
	): connection
		assert(private.self == self, "received incorrect library")
		assert(private.state.alive, "library was destroyed")
		assert(type(topic) == "string" and topic ~= "", "topic must be a non-empty string")
		assert(type(callback) == "function", "callback must be a function")
		assert(parallel == nil or type(parallel) == "boolean", "parallel must be a boolean or nil")

		const set: { [string]: { [(action) -> ()]: boolean } } = if parallel then private.prll else private.sync
		const callbacks = set[topic] or {}
		callbacks[callback] = true
		set[topic] = callbacks

		local connection: connection
		connection = {
			disconnect = function(self: connection): ()
				assert(self == connection, "received non-connection self")

				const current = set[topic]

				if current ~= nil then
					current[callback] = nil

					if next(current) == nil then
						set[topic] = nil
					end
				end
			end,

			is_connected = function(self: connection): boolean
				assert(self == connection, "received non-connection self")

				const current = set[topic]
				return current ~= nil and current[callback] == true
			end,
		}

		return connection
	end,

	process = function(self: library, registry: registry?): number
		assert(private.self == self, "received incorrect library")
		assert(private.state.alive, "library was destroyed")

		if registry ~= nil then
			return private.process_registry(self, registry)
		end

		local registries: { registry } = {}

		for _, v in private.init do
			table.insert(registries, v)
		end

		local count = 0

		for _, v in registries do
			count += private.process_registry(self, v)
		end

		return count
	end,

	destroy = function(self: library): ()
		assert(private.self == self, "received incorrect library")

		if not private.state.alive then
			return
		end

		private.state.alive = false

		for _, registry in private.init do
			const readers = registry.readers :: any

			if typeof(readers) == "SharedTable" then
				pcall(function()
					private.forget_reader(registry, self.luau_instance_marker)
					readers[self.luau_instance_marker] = nil
				end)
			end
		end

		table.clear(private.init)
		table.clear(private.sync)
		table.clear(private.prll)
		table.clear(private.cleanup_at)
	end,
}

--[[
	Private helpers. They live in a separate scope so the public `library`
	table can reference them through `private`.
]]
do
	--[[
		`typeof` names that `SharedTable` can store directly.
	]]
	private.supported_types = table.freeze({
		boolean = true,
		number = true,
		string = true,
		vector = true,

		CFrame = true,
		Vector2 = true,
		Vector3 = true,
		Vector2int16 = true,
		Vector3int16 = true,
		Color3 = true,
		BrickColor = true,
		NumberRange = true,
		NumberSequence = true,
		ColorSequence = true,
		NumberSequenceKeypoint = true,
		ColorSequenceKeypoint = true,
		Rect = true,
		Region3 = true,
		Region3int16 = true,
		Ray = true,
		UDim = true,
		UDim2 = true,
		Font = true,
		PathWaypoint = true,
		PhysicalProperties = true,
		TweenInfo = true,
		EnumItem = true,
		DateTime = true,
	} :: { [string]: boolean })

	--[[
		Returns `key` if `SharedTable` accepts it, otherwise `nil`.
		`SharedTable` keys must be strings or non-negative integers below 2^32.
	]]
	private.encode_key = function(key: unknown): (string | number)?
		if type(key) == "string" then
			return key
		end

		if type(key) == "number" and key >= 0 and key < 4294967296 and math.floor(key) == key then
			return key
		end

		return nil
	end

	--[[
		Converts an arbitrary Luau value into something `SharedTable` can
		store. Tables become nested `SharedTable`s, unsupported values become
		`unsupported_marker`, and unsupported keys are skipped. `seen` guards
		against cycles.
	]]
	private.encode = function(value: unknown, seen: { [any]: SharedTable }?): unknown
		if value == nil then
			return nil
		end

		const kind = typeof(value)

		if kind == "table" then
			const cache = seen or {}
			const existing = cache[value]

			if existing ~= nil then
				return existing
			end

			const out: any = SharedTable.new()
			cache[value :: any] = out

			const raw = value :: { [any]: any }
			for key, item in next, raw do
				const encoded_key = private.encode_key(key)

				if encoded_key ~= nil then
					const encoded = private.encode(item, cache)

					if encoded ~= nil then
						const ok = pcall(function()
							out[encoded_key] = encoded
						end)

						if not ok then
							out[encoded_key] = private.unsupported_marker
						end
					end
				end
			end

			return out
		end

		if kind == "SharedTable" or private.supported_types[kind] then
			return value
		end

		return private.unsupported_marker
	end

	--[[
		Converts nested `SharedTable`s back into plain tables. `seen` guards
		against cycles.
	]]
	private.decode = function(value: unknown, seen: { [any]: any }?): any
		if typeof(value) ~= "SharedTable" then
			return value
		end

		const cache = seen or {}
		const existing = cache[value]

		if existing ~= nil then
			return existing
		end

		const out = {}
		cache[value] = out

		const raw = value
		for key, item in raw :: { unknown } do
			out[key] = private.decode(item, cache)
		end

		return out
	end

	--[[
		Returns a detached plain-table copy of `value`, sanitised the same way
		as data written to a registry.
	]]
	private.copy = function(value: unknown): any
		return private.decode(private.encode(value))
	end

	--[[
		Builds a reader value for the current VM using the current time.
	]]
	private.snapshot_reader = function(self: library): luau_reader
		return {
			luau_instance_marker = self.luau_instance_marker,
			attributes = private.state.attributes,
			last_seen = os.time(),
		}
	end

	--[[
		Converts a reader into a `SharedTable` suitable for
		`registry.readers`.
	]]
	private.encode_reader = function(reader: luau_reader): SharedTable
		const out = SharedTable.new()
		out.luau_instance_marker = reader.luau_instance_marker
		out.last_seen = reader.last_seen

		if reader.attributes ~= nil then
			const encoded = private.encode(reader.attributes)
			const ok = pcall(function()
				out.attributes = encoded
			end)

			if not ok then
				out.attributes = private.unsupported_marker
			end
		end

		return out
	end

	--[[
		Calls `SharedTable.update` and reports whether it succeeded. Some
		engines reject `update` for a key that does not exist yet.
	]]
	private.update = function(container: SharedTable, key: string, callback: (any) -> any): boolean
		const ok = pcall(function()
			SharedTable.update(container, key, callback)
		end)

		return ok
	end

	--[[
		Atomically gets or creates a nested `SharedTable` field. `update` is
		used first so two VMs cannot end up writing into two different tables;
		the fallback covers engines that reject `update` for a missing key.
	]]
	private.ensure_table = function(container: SharedTable, key: string)
		const raw = container
		const current = raw[key]

		if typeof(current) == "SharedTable" then
			return current
		end

		const ok = private.update(container, key, function(value: any)
			if typeof(value) == "SharedTable" then
				return value
			end

			return SharedTable.new()
		end)

		const stored = raw[key]

		if ok and typeof(stored) == "SharedTable" then
			return stored
		end

		const created = SharedTable.new()
		raw[key] = created

		return raw[key] or created
	end

	--[[
		Initialises a registry if needed and refreshes the current reader.
		When `force` is `false`, `last_seen` is written at most once every
		`reader_refresh` seconds.
	]]
	private.touch = function(self: library, registry: registry, path: string, force: boolean?): ()
		const raw = registry

		if raw.path ~= path then
			if not private.update(registry, "path", function(_current)
				return path
			end) then
				raw.path = path
			end
		end

		if type(raw.source) ~= "string" or raw.source == "" then
			if
				not private.update(registry, "source", function(current)
					if type(current) == "string" and current ~= "" then
						return current
					end

					return self.luau_instance_marker
				end)
			then
				if type(raw.source) ~= "string" or raw.source == "" then
					raw.source = self.luau_instance_marker
				end
			end
		end

		if type(raw.sequence) ~= "number" then
			if
				not private.update(registry, "sequence", function(current)
					if type(current) == "number" then
						return current
					end

					return 0
				end)
			then
				if type(raw.sequence) ~= "number" then
					raw.sequence = 0
				end
			end
		end

		private.ensure_table(registry, "events")
		private.ensure_table(registry, "readers")

		private.init[path] = registry

		const readers = raw.readers

		if not force then
			const existing = readers[self.luau_instance_marker]

			if typeof(existing) == "SharedTable" then
				const last_seen = existing.last_seen

				if type(last_seen) == "number" and os.time() - last_seen < private.reader_refresh then
					return
				end
			end
		end

		readers[self.luau_instance_marker] = private.encode_reader(private.snapshot_reader(self))
	end

	--[[
		Records the current reader in both `who_readed` and `who_processed`.
	]]
	private.mark_processed = function(self: library, stored: SharedTable, reader: SharedTable): ()
		const marker = self.luau_instance_marker
		const processed = private.ensure_table(stored, "who_processed")
		const already_processed = processed[marker] ~= nil

		processed[marker] = reader

		const read = private.ensure_table(stored, "who_readed")
		read[marker] = reader

		if not already_processed then
			if type(stored.processed_count) ~= "number" then
				stored.processed_count = 0
			end

			SharedTable.increment(stored, "processed_count", 1)
		end
	end

	--[[
		Removes `marker` from `who_processed` / `who_readed` of every action in
		`registry` and keeps `processed_count` in sync. Called when a reader is
		removed so the counter only counts current readers.
	]]
	private.forget_reader = function(registry: registry, marker: string): ()
		const events = registry.events :: any

		if typeof(events) ~= "SharedTable" then
			return
		end

		for _, stored in events do
			if typeof(stored) ~= "SharedTable" then
				continue
			end

			const action = stored :: any
			const processed = action.who_processed

			if typeof(processed) == "SharedTable" and processed[marker] ~= nil then
				processed[marker] = nil

				if type(action.processed_count) == "number" and action.processed_count > 0 then
					SharedTable.increment(stored, "processed_count", -1)
				end
			end

			const read = action.who_readed

			if typeof(read) == "SharedTable" then
				read[marker] = nil
			end
		end
	end

	--[[
		Builds a flat set of reader markers and returns it with the number of
		readers. The set is cached for one process/cleanup pass so that
		`who_processed` checks do not walk `registry.readers` for every action.
	]]
	private.reader_set = function(registry: registry): ({ [string]: boolean }, number)
		const readers = registry.readers :: any
		const set: { [string]: boolean } = {}
		local count = 0

		if typeof(readers) == "SharedTable" then
			for marker in readers do
				set[marker] = true
				count += 1
			end
		end

		return set, count
	end

	--[[
		Returns `true` when every known reader has processed the action and
		there is at least one reader. `reader_set` and `reader_count` are
		cached by the caller for the duration of one pass.
	]]
	private.is_processed_by_all = function(
		reader_set: { [string]: boolean },
		reader_count: number,
		action: action
	): boolean
		if reader_count == 0 then
			return false
		end

		--[[
			`processed_count` is kept in sync when readers leave, so it counts
			only current readers. That makes the common case O(1). The set
			check is only a fallback for actions published before the counter
			existed.
		]]
		const count = action.processed_count

		if type(count) == "number" then
			return count >= reader_count
		end

		const processed = action.who_processed :: any

		if typeof(processed) ~= "SharedTable" then
			return false
		end

		local seen = 0

		for marker in processed do
			if reader_set[marker] then
				seen += 1

				if seen >= reader_count then
					return true
				end
			end
		end

		return false
	end

	--[[
		Removes stale readers and expired or fully processed actions. Keys are
		collected before mutation because changing a `SharedTable` while
		iterating it is not guaranteed to be safe.
	]]
	private.cleanup = function(self: library, registry: registry): ()
		const now = os.time()
		const readers = registry.readers
		const dead_set: { [string]: boolean } = {}

		if typeof(readers) == "SharedTable" then
			--[[
				Collect first: mutating a `SharedTable` while iterating it is
				not guaranteed to behave like mutating a plain Luau table.
			]]
			local dead = {}

			for marker, stored in readers do
				const last_seen = if typeof(stored) == "SharedTable" and type(stored.last_seen) == "number"
					then stored.last_seen
					else 0

				if marker ~= self.luau_instance_marker and now - last_seen > private.reader_timeout then
					table.insert(dead, marker)
				end
			end

			for _, marker in dead do
				const stored = readers[marker]

				if typeof(stored) ~= "SharedTable" then
					readers[marker] = nil
					dead_set[marker] = true
					continue
				end

				const last_seen = stored.last_seen

				if type(last_seen) ~= "number" or now - last_seen > private.reader_timeout then
					readers[marker] = nil
					dead_set[marker] = true
				end
			end
		end

		const reader_set, reader_count = private.reader_set(registry)
		const events = registry.events

		if typeof(events) == "SharedTable" then
			local expired: { any } = {}
			const has_dead = next(dead_set) ~= nil

			for id, stored in events do
				if typeof(stored) ~= "SharedTable" then
					table.insert(expired, id)
					continue
				end

				const action = stored :: any

				--[[
					Drop markers of readers that were just removed. This keeps
					`processed_count` equal to the number of *current* readers
					that processed the action.
				]]
				if has_dead then
					const processed = action.who_processed

					if typeof(processed) == "SharedTable" then
						for marker in dead_set do
							if processed[marker] ~= nil then
								processed[marker] = nil

								if type(action.processed_count) == "number" and action.processed_count > 0 then
									SharedTable.increment(stored, "processed_count", -1)
								end
							end
						end
					end

					const read = action.who_readed

					if typeof(read) == "SharedTable" then
						for marker in dead_set do
							read[marker] = nil
						end
					end
				end

				const created_at = action.created_at

				if type(created_at) == "number" and now - created_at > private.event_ttl then
					table.insert(expired, id)
					continue
				end

				if private.is_processed_by_all(reader_set, reader_count, action) then
					table.insert(expired, id)
				end
			end

			for _, id in expired do
				events[id] = nil
			end
		end
	end

	--[[
		Invokes a callback, optionally in a parallel context. Returns
		`(ok, error)` like `pcall` and always returns to the synchronous phase.
	]]
	private.call = function(
		self: library,
		callback: (action: action) -> (),
		action: action,
		parallel: boolean
	): (boolean, any)
		if parallel and self.luau_parallel then
			const desynchronized = pcall(task.desynchronize)

			if desynchronized then
				const ok, err = pcall(callback, action)
				pcall(task.synchronize)
				return ok, err
			end
		end

		return pcall(callback, action)
	end

	--[[
		Delivers one stored action to local subscribers. Returns `true` when at
		least one callback was called.
	]]
	private.dispatch = function(self: library, stored: SharedTable): boolean
		const action = stored :: any
		const marker = self.luau_instance_marker
		const processed = action.who_processed

		if typeof(processed) == "SharedTable" and processed[marker] ~= nil then
			return false
		end

		const topic = action.topic

		if type(topic) ~= "string" then
			return false
		end

		local has_subscribers = false

		for _, set in { private.sync, private.prll } do
			if set[topic] ~= nil or set["*"] ~= nil then
				has_subscribers = true
				break
			end
		end

		if not has_subscribers then
			return false
		end

		--[[
			Mark the action as processed before invoking callbacks so that the
			payload a callback receives already contains the current reader,
			and so that a failing callback is not retried on every heartbeat.
		]]
		private.mark_processed(self, stored, private.encode_reader(private.snapshot_reader(self)))

		const payload = private.decode(stored) :: action
		local called = false

		for _, set in { private.sync, private.prll } do
			const parallel = set == private.prll
			const specific = if topic ~= "*" then set[topic] else nil
			const wildcard = set["*"]

			if specific ~= nil then
				for callback in specific do
					called = true
					const ok, err = private.call(self, callback, payload, parallel)

					if not ok then
						warn(`[parallel-api] topic {topic} callback failed: {err}`)
					end
				end
			end

			if wildcard ~= nil then
				for callback in wildcard do
					called = true
					const ok, err = private.call(self, callback, payload, parallel)

					if not ok then
						warn(`[parallel-api] wildcard callback for {topic} failed: {err}`)
					end
				end
			end
		end

		if not called then
			return false
		end

		return true
	end

	--[[
		Sorts pending actions by their publication order.
	]]
	private.by_sequence = function(left: pending_entry, right: pending_entry): boolean
		return left.sequence < right.sequence
	end

	--[[
		Returns `true` when at least one local topic has a callback.
	]]
	private.has_subscribers = function(): boolean
		return next(private.sync) ~= nil or next(private.prll) ~= nil
	end

	--[[
		Delivers pending actions of one registry in sequence order and then
		cleans the registry up. `cleanup = false` is used by the heartbeat to
		avoid scanning the registry every frame.
	]]
	private.process_registry = function(self: library, registry: registry, cleanup: boolean?): number
		if typeof(registry) ~= "SharedTable" then
			return 0
		end

		const path = if type(registry.path) == "string" and registry.path ~= "" then registry.path else private.path
		private.touch(self, registry, path)

		const events = registry.events :: any

		if typeof(events) ~= "SharedTable" then
			return 0
		end

		--[[
			Without local subscribers no action can be delivered, so skip the
			scan and the sort. Cleanup still has to run to expire old actions.
		]]
		if not private.has_subscribers() then
			if cleanup ~= false then
				private.cleanup(self, registry)
			end

			return 0
		end

		const marker = self.luau_instance_marker
		const pending: { pending_entry } = {}

		for id, stored in events do
			if typeof(stored) == "SharedTable" then
				const action = stored :: any
				const processed = action.who_processed

				if typeof(processed) ~= "SharedTable" or processed[marker] == nil then
					table.insert(pending, {
						id = id,
						action = stored,
						sequence = if type(action.sequence) == "number" then action.sequence else 0,
					})
				end
			end
		end

		table.sort(pending, private.by_sequence)

		local reader_set: { [string]: boolean } = {}
		local reader_count = 0

		if cleanup ~= false then
			reader_set, reader_count = private.reader_set(registry)
		end

		local count = 0

		for _, item in pending do
			if private.dispatch(self, item.action) then
				count += 1
			end

			--[[
				Delete actions that every reader has processed right away, so
				the cleanup pass does not have to scan and delete them again.
			]]
			if cleanup ~= false and private.is_processed_by_all(reader_set, reader_count, item.action :: any) then
				events[item.id] = nil
			end
		end

		if cleanup ~= false then
			private.cleanup(self, registry)
		end

		return count
	end

	--[[
		Starts the background loop that processes known registries once per
		frame. The loop stops when the library is destroyed.
	]]
	private.heartbeat = function(self: library): ()
		task.defer(function()
			while private.state.alive do
				task.wait()

				if not private.state.alive then
					break
				end

				local registries: { registry } = {}

				for _, registry in private.init do
					table.insert(registries, registry)
				end

				for _, registry in registries do
					const path = if type(registry.path) == "string" and registry.path ~= ""
						then registry.path
						else private.path
					const now = os.time()
					const last_cleanup = private.cleanup_at[path] or 0
					const should_cleanup = now - last_cleanup >= private.cleanup_interval

					if should_cleanup then
						private.cleanup_at[path] = now
					end

					const ok, err = pcall(private.process_registry, self, registry, should_cleanup)

					if not ok then
						warn(`[parallel-api] heartbeat failed: {err}`)
					end
				end
			end
		end)
	end

	private.self = library

	table.freeze(private)
	table.freeze(library)

	private.heartbeat(library)
end

return library
