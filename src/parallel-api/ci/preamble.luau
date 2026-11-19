--[[
	Minimal stand-ins for the Roblox services used by `src/api.luau`.

	The Luau CLI has no `SharedTable`, `SharedTableRegistry`, `HttpService`
	or scheduler, so the test runner concatenates this preamble, the module
	source and `tests.luau` into one chunk.

	`make_api` evaluates the module body in a closure. Every simulated VM
	gets its own `private` state and marker, while `store` and `now` are
	shared, which is enough to exercise multi-VM registry behaviour.
]]

local ST_MT = {}

local SharedTable = {}

function SharedTable.new(initial)
	local stored = setmetatable({}, ST_MT)

	if initial ~= nil then
		for key, value in initial do
			stored[key] = value
		end
	end

	return stored
end

function SharedTable.update(container, key, callback)
	if SHAREDTABLE_STRICT and container[key] == nil then
		error(`key {key} does not exist`, 2)
	end

	container[key] = callback(container[key])
end

function SharedTable.increment(container, key, delta)
	local previous = container[key] or 0
	container[key] = previous + delta
	return previous
end

local builtin_typeof = typeof

local function typeof(value)
	if type(value) == "table" and getmetatable(value) == ST_MT then
		return "SharedTable"
	end

	return builtin_typeof(value)
end

local function make_api(id, store, now)
	local HttpService = {
		GenerateGUID = function()
			return id
		end,
	}

	local SharedTableRegistry = {
		GetSharedTable = function(_, name)
			local existing = store[name]

			if existing == nil then
				existing = SharedTable.new()
				store[name] = existing
			end

			return existing
		end,

		SetSharedTable = function(_, name, value)
			store[name] = value
		end,
	}

	local game = {
		GetService = function(_, name)
			if name == "HttpService" then
				return HttpService
			end

			if name == "SharedTableRegistry" then
				return SharedTableRegistry
			end

			error(`unknown service: {name}`, 2)
		end,
	}

	local task = {
		defer = function() end,
		wait = function() end,
		desynchronize = function() end,
		synchronize = function() end,
	}

	local os = {
		time = function()
			return now.value
		end,
	}

	local warn = function() end

	return (function()
