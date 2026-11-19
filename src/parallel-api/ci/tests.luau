--[[
	Behaviour tests for `src/api.luau`.

	The runner concatenates the fake Roblox services from `preamble.luau`,
	the module source and this file. `task.defer` is a no-op in the fake, so
	the background heartbeat is disabled and `process` is called explicitly.
]]

local checks = 0

local function check(condition, message)
	checks += 1

	if not condition then
		error(`FAIL: {message}`, 2)
	end
end

local function check_error(callback, message)
	check(not pcall(callback), message)
end

local function new_vm(id)
	local store = {}
	local now = { value = 1000 }
	return make_api(id, store, now), store, now
end

local function add_reader(registry, marker, now)
	local reader = SharedTable.new()
	reader.luau_instance_marker = marker
	reader.last_seen = now
	registry.readers[marker] = reader
	return reader
end

--[[
	Module surface and registry initialisation.
]]
do
	local api, store = new_vm("vm1")

	check(api.luau_instance_marker == "vm1", "marker")
	check(api.luau_parallel == true, "parallel detection")
	check(type(api.unsupported_marker) == "string", "unsupported marker")
	check(api.action_template.sequence == 0, "action template")
	check(api.registry_template.source == "vm1", "registry template")

	local registry = api:fetch_registry()

	check(typeof(registry) == "SharedTable", "registry is a sharedtable")
	check(registry.path == "@IFMNB/registry", "default path")
	check(registry.source == "vm1", "registry source")
	check(registry.sequence == 0, "initial sequence")
	check(typeof(registry.events) == "SharedTable", "events table")
	check(typeof(registry.readers) == "SharedTable", "readers table")
	check(registry.readers["vm1"].luau_instance_marker == "vm1", "reader marker")
	check(registry.readers["vm1"].last_seen == 1000, "reader last_seen")
	check(api:fetch_registry() == registry, "fetch is idempotent")
	check(store["@IFMNB/registry"] == registry, "registry stored by path")
end

--[[
	Publishing, delivery and payload sanitisation.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("payload")
	local seen = {}

	local connection = api:subscribe("hello", function(action)
		table.insert(seen, action)
	end)

	check(connection:is_connected(), "connection connected")

	local id = api:publish("hello", {
		text = "world",
		nested = { n = 5 },
		fn = function() end,
		thread = coroutine.create(function() end),
		instance = newproxy(true),
		[true] = "dropped",
		[-1] = "dropped",
		[1.5] = "dropped",
		[0] = "kept",
	}, registry)

	check(id == "vm1:1", "action id")
	check(api:process(registry) == 1, "one action delivered")
	check(#seen == 1, "callback called once")

	local payload = seen[1]

	check(payload.topic == "hello", "payload topic")
	check(payload.content.text == "world", "payload string")
	check(payload.content.nested.n == 5, "nested payload")
	check(payload.content.fn == api.unsupported_marker, "function sanitised")
	check(payload.content.thread == api.unsupported_marker, "thread sanitised")
	check(payload.content.instance == api.unsupported_marker, "userdata sanitised")
	check(payload.content[0] == "kept", "valid numeric key kept")
	check(payload.content[true] == nil, "boolean key dropped")
	check(payload.content[-1] == nil, "negative key dropped")
	check(payload.content[1.5] == nil, "fractional key dropped")
	check(payload.who_readed["vm1"] ~= nil, "read marker recorded")
	check(payload.who_processed["vm1"] ~= nil, "processed marker recorded")
	check(payload.who_processed["vm1"].luau_instance_marker == "vm1", "processed reader snapshot")
	check(payload.sequence == 1, "payload sequence")
	check(payload.source == "vm1", "payload source")
	check(payload.created_at == 1000, "payload creation time")
	check(next(registry.events) == nil, "processed action removed")

	connection:disconnect()
	check(not connection:is_connected(), "connection disconnected")
end

--[[
	Cyclic payloads and omitted content.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("cycle")
	local received
	local empty_received

	api:subscribe("cycle", function(action)
		received = action
	end)

	api:subscribe("empty", function(action)
		empty_received = action
	end)

	local cyclic = { label = "root" }
	cyclic.self = cyclic

	api:publish("cycle", cyclic, registry)
	api:publish("empty", nil, registry)

	check(api:process(registry) == 2, "cyclic actions delivered")
	check(received.content.label == "root", "cyclic label")
	check(received.content.self == received.content, "cyclic content preserved")
	check(empty_received.content == nil, "nil content")
end

--[[
	Publication order, wildcard subscribers and specific-before-wildcard calls.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("order")
	local trace = {}

	local specific = api:subscribe("mix", function()
		table.insert(trace, "sync")
	end)

	local parallel = api:subscribe("mix", function()
		table.insert(trace, "parallel")
	end, true)

	local wildcard = api:subscribe("*", function(action)
		table.insert(trace, "wild:" .. action.content.n)
	end)

	api:publish("mix", { n = 1 }, registry)
	api:publish("mix", { n = 2 }, registry)
	api:publish("mix", { n = 3 }, registry)

	check(api:process(registry) == 3, "three actions delivered")
	check(
		table.concat(trace, ",") == "sync,wild:1,parallel,sync,wild:2,parallel,sync,wild:3,parallel",
		"publication order and callback order: " .. table.concat(trace, ",")
	)

	specific:disconnect()
	parallel:disconnect()
	wildcard:disconnect()
end

--[[
	Duplicate subscriptions share one callback slot; disconnecting one
	connection removes it for all handles.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("duplicates")
	local calls = 0

	local function callback()
		calls += 1
	end

	local first = api:subscribe("dup", callback)
	local second = api:subscribe("dup", callback)

	api:publish("dup", {}, registry)

	check(api:process(registry) == 1, "duplicate callback delivered once")
	check(calls == 1, "duplicate callback called once")

	first:disconnect()
	check(not second:is_connected(), "disconnect removes the shared callback")

	second:disconnect()
	second:disconnect()
	check(not second:is_connected(), "double disconnect is safe")

	check_error(function()
		first.disconnect({})
	end, "disconnect validates self")
end

--[[
	A failing callback must not be retried on every pass.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("errors")
	local attempts = 0

	api:subscribe("boom", function()
		attempts += 1
		error("boom")
	end)

	local id = api:publish("boom", {}, registry)

	check(api:process(registry) == 1, "failing callback counts as delivered")
	check(attempts == 1, "failing callback called once")
	check(registry.events[id] == nil, "failing callback action removed")
	check(api:process(registry) == 0, "failing callback is not retried")
	check(attempts == 1, "failing callback not called again")
end

--[[
	Actions without a local subscriber stay until their TTL expires.
]]
do
	local api, _, now = new_vm("vm1")
	local registry = api:fetch_registry("ttl")
	local id = api:publish("nobody", { value = 1 }, registry)

	check(api:process(registry) == 0, "unclaimed action not delivered")
	check(registry.events[id] ~= nil, "unclaimed action kept")

	now.value += 300
	check(api:process(registry) == 0, "unclaimed action still kept at ttl")
	check(registry.events[id] ~= nil, "unclaimed action kept at ttl")

	now.value += 1
	check(api:process(registry) == 0, "expired action not delivered")
	check(registry.events[id] == nil, "unclaimed action expired")
end

--[[
	Argument validation.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("validation")

	check_error(function()
		api:publish("", {}, registry)
	end, "empty topic rejected")

	check_error(function()
		api:publish("t", "nope", registry)
	end, "non-table content rejected")

	check_error(function()
		api:subscribe("t", 1)
	end, "non-function callback rejected")

	check_error(function()
		api:fetch_registry("")
	end, "empty registry path rejected")

	check_error(function()
		api:set_reader_attributes(1)
	end, "non-table attributes rejected")

	check_error(function()
		api:delete_registry(1, registry)
	end, "non-sharedtable registry rejected")

	check(api:process({}) == 0, "process ignores a plain table")
end

--[[
	Reader attributes are sanitised, copied and pushed to known registries.
]]
do
	local api = new_vm("vm1")
	local registry = api:fetch_registry("attributes")

	api:set_reader_attributes({
		tag = "worker",
		count = 2,
		fn = function() end,
		[true] = "dropped",
	})

	local reader = api:get_reader()

	check(reader.luau_instance_marker == "vm1", "snapshot marker")
	check(reader.last_seen == 1000, "snapshot last_seen")
	check(reader.attributes.tag == "worker", "attribute string")
	check(reader.attributes.count == 2, "attribute number")
	check(reader.attributes.fn == api.unsupported_marker, "unsupported attribute")
	check(reader.attributes[true] == nil, "unsupported attribute key dropped")
	check(registry.readers["vm1"].attributes.tag == "worker", "attributes synced to registry")

	reader.attributes.tag = "mutated"
	check(api:get_reader().attributes.tag == "worker", "snapshot is a copy")

	api:set_reader_attributes(nil)
	check(api:get_reader().attributes == nil, "attributes cleared")
	check(registry.readers["vm1"].attributes == nil, "cleared attributes synced")
end

--[[
	`last_seen` is refreshed at most once per `reader_refresh` seconds.
]]
do
	local api, _, now = new_vm("vm1")
	local registry = api:fetch_registry("refresh")

	check(registry.readers["vm1"].last_seen == 1000, "initial refresh")

	now.value = 1003
	api:process(registry)
	check(registry.readers["vm1"].last_seen == 1000, "refresh is throttled")

	now.value = 1006
	api:process(registry)
	check(registry.readers["vm1"].last_seen == 1006, "refresh after interval")

	now.value = 1012
	api:process()
	check(registry.readers["vm1"].last_seen == 1012, "default process refreshes")
end

--[[
	An action is removed only after every known reader has processed it.
]]
do
	local api, _, now = new_vm("vm1")
	local registry = api:fetch_registry("multi")
	local connection = api:subscribe("t", function() end)
	local id = api:publish("t", { x = 1 }, registry)
	local other = add_reader(registry, "vm2", now.value)

	check(api:process(registry) == 1, "first reader delivered")
	check(registry.events[id] ~= nil, "action waits for the second reader")
	check(registry.events[id].processed_count == 1, "one processed reader")
	check(registry.events[id].who_processed["vm1"] ~= nil, "current reader marked")
	check(registry.events[id].who_processed["vm2"] == nil, "second reader pending")

	registry.events[id].who_processed["vm2"] = other
	registry.events[id].processed_count = 2

	api:process(registry)
	check(registry.events[id] == nil, "action removed after all readers")

	connection:disconnect()
end

--[[
	Actions published without `processed_count` fall back to `who_processed`.
]]
do
	local api, _, now = new_vm("vm1")
	local registry = api:fetch_registry("legacy")
	local connection = api:subscribe("t", function() end)
	local legacy = SharedTable.new()

	legacy.topic = "t"
	legacy.sequence = 1
	legacy.source = "vm1"
	legacy.created_at = now.value
	legacy.who_readed = SharedTable.new()
	legacy.who_processed = SharedTable.new()
	legacy.who_processed["vm1"] = registry.readers["vm1"]

	registry.events["legacy:1"] = legacy

	api:process(registry)
	check(registry.events["legacy:1"] == nil, "legacy action detected as processed")

	connection:disconnect()
end

--[[
	Removing a stale reader also updates `processed_count`.
]]
do
	local api, _, now = new_vm("vm1")
	local registry = api:fetch_registry("stale")
	local connection = api:subscribe("t", function() end)
	local id = api:publish("t", { x = 1 }, registry)
	local stale = add_reader(registry, "vm3", 0)
	local stored = registry.events[id]

	stored.who_processed["vm3"] = stale
	stored.who_processed["vm1"] = registry.readers["vm1"]
	stored.processed_count = 2

	now.value += 31
	api:process(registry)

	check(registry.readers["vm3"] == nil, "stale reader removed")
	check(stored.who_processed["vm3"] == nil, "stale marker forgotten")
	check(stored.processed_count == 1, "stale reader decremented count")
	check(registry.events[id] == nil, "action removed after stale cleanup")

	connection:disconnect()
end

--[[
	`delete_registry` unregisters the registry and forgets the current reader.
]]
do
	local api, store, now = new_vm("vm1")
	local registry = api:fetch_registry("delete")
	local connection = api:subscribe("t", function() end)
	local id = api:publish("t", { x = 1 }, registry)

	add_reader(registry, "vm2", now.value)
	api:process(registry)

	check(registry.events[id].processed_count == 1, "processed before delete")

	api:delete_registry(registry)

	check(store["delete"] == nil, "registry unregistered")
	check(registry.readers["vm1"] == nil, "reader removed from registry")
	check(registry.events[id].who_processed["vm1"] == nil, "processed marker forgotten")
	check(registry.events[id].processed_count == 0, "processed count decremented")

	connection:disconnect()
end

--[[
	A VM cannot delete a registry created by another VM.
]]
do
	local first, store = new_vm("vm-a")
	local second = make_api("vm-b", store, { value = 1000 })
	local registry = second:fetch_registry("foreign")

	check_error(function()
		first:delete_registry(registry)
	end, "foreign registry cannot be deleted")

	check(store["foreign"] ~= nil, "foreign registry kept")
end

--[[
	`destroy` stops the library and forgets the current reader everywhere.
]]
do
	local api, _, now = new_vm("vm-destroy")
	local registry = api:fetch_registry("destroy")
	local connection = api:subscribe("t", function() end)
	local id = api:publish("t", { x = 1 }, registry)
	local other = add_reader(registry, "vm4", now.value)
	local stored = registry.events[id]

	stored.who_processed["vm4"] = other
	stored.who_processed["vm-destroy"] = registry.readers["vm-destroy"]
	stored.processed_count = 2

	api:destroy()

	check(registry.readers["vm-destroy"] == nil, "destroy removes reader")
	check(stored.who_processed["vm-destroy"] == nil, "destroy forgets processed marker")
	check(stored.processed_count == 1, "destroy keeps other reader count")
	check_error(function()
		api:fetch_registry()
	end, "fetch after destroy fails")
	check_error(function()
		api:publish("x", {})
	end, "publish after destroy fails")
	check_error(function()
		api:process()
	end, "process after destroy fails")
	check_error(function()
		api:subscribe("x", function() end)
	end, "subscribe after destroy fails")
	check_error(function()
		api:set_reader_attributes({})
	end, "attributes after destroy fail")

	api:destroy()
	check(not connection:is_connected(), "destroy clears subscriptions")
	connection:disconnect()
end

--[[
	Two simulated VMs share a registry and process actions independently.
]]
do
	local store = {}
	local now = { value = 1000 }
	local first = make_api("vm-a", store, now)
	local second = make_api("vm-b", store, now)
	local registry = first:fetch_registry("shared")

	check(second:fetch_registry("shared") == registry, "registries shared")

	local first_calls = 0
	local second_calls = 0

	local first_connection = first:subscribe("t", function()
		first_calls += 1
	end)

	local second_connection = second:subscribe("t", function()
		second_calls += 1
	end)

	local first_id = first:publish("t", { x = 1 }, registry)
	local second_id = second:publish("t", { x = 2 }, registry)

	check(registry.sequence == 2, "sequence shared across VMs")
	check(first_id == "vm-a:1", "first action id")
	check(second_id == "vm-b:2", "second action id")

	check(first:process(registry) == 2, "first VM delivered both actions")
	check(first_calls == 2, "first VM callbacks")
	check(second_calls == 0, "second VM did not receive yet")
	check(registry.events[first_id].processed_count == 1, "first VM processed one reader")
	check(registry.events[second_id].processed_count == 1, "first VM processed second action")

	check(second:process(registry) == 2, "second VM delivered both actions")
	check(second_calls == 2, "second VM callbacks")
	check(next(registry.events) == nil, "actions removed after both VMs")

	first_connection:disconnect()
	second_connection:disconnect()
end

--[[
	`process` without an argument walks every registry known to the VM.
]]
do
	local api = new_vm("vm1")
	local first = api:fetch_registry("first")
	local second = api:fetch_registry("second")

	api:subscribe("t", function() end)
	api:publish("t", {}, first)
	api:publish("t", {}, second)

	check(api:process() == 2, "all known registries processed")
	check(next(first.events) == nil, "first registry cleaned")
	check(next(second.events) == nil, "second registry cleaned")
	check(api:process({}) == 0, "plain table ignored")
end

print(`parallel-api: {checks} checks passed (strict SharedTable.update = {tostring(SHAREDTABLE_STRICT == true)})`)
