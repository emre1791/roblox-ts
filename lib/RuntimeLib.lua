local Promise = require(script.Parent.Promise)

local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local TS = {}

TS.Promise = Promise

local function isPlugin(object)
	return RunService:IsStudio() and object:FindFirstAncestorWhichIsA("Plugin") ~= nil
end

function TS.getModule(object, scope, moduleName)
	if moduleName == nil then
		moduleName = scope
		scope = "@rbxts"
	end

	if RunService:IsRunning() and object:IsDescendantOf(ReplicatedFirst) then
		warn("roblox-ts packages should not be used from ReplicatedFirst!")
	end

	-- ensure modules have fully replicated
	if RunService:IsRunning() and RunService:IsClient() and not isPlugin(object) and not game:IsLoaded() then
		game.Loaded:Wait()
	end

	local globalModules = script.Parent:FindFirstChild("node_modules")
	if not globalModules then
		error("Could not find any modules!", 2)
	end

	repeat
		local modules = object:FindFirstChild("node_modules")
		if modules and modules ~= globalModules then
			modules = modules:FindFirstChild("@rbxts")
		end
		if modules then
			local module = modules:FindFirstChild(moduleName)
			if module then
				return module
			end
		end
		object = object.Parent
	until object == nil or object == globalModules

	local scopedModules = globalModules:FindFirstChild(scope or "@rbxts");
	return (scopedModules or globalModules):FindFirstChild(moduleName) or error("Could not find module: " .. moduleName, 2)
end

-- This is a hash which TS.import uses as a kind of linked-list-like history of [Script who Loaded] -> Library
local currentlyLoading = {}
local registeredLibraries = {}

function TS.import(caller, module, ...)
	for i = 1, select("#", ...) do
		module = module:WaitForChild((select(i, ...)))
	end

	if module.ClassName ~= "ModuleScript" then
		error("Failed to import! Expected ModuleScript, got " .. module.ClassName, 2)
	end

	currentlyLoading[caller] = module

	-- Check to see if a case like this occurs:
	-- module -> Module1 -> Module2 -> module

	-- WHERE currentlyLoading[module] is Module1
	-- and currentlyLoading[Module1] is Module2
	-- and currentlyLoading[Module2] is module

	local currentModule = module
	local depth = 0

	while currentModule do
		depth = depth + 1
		currentModule = currentlyLoading[currentModule]

		if currentModule == module then
			local str = currentModule.Name -- Get the string traceback

			for _ = 1, depth do
				currentModule = currentlyLoading[currentModule]
				str = str .. "  ⇒ " .. currentModule.Name
			end

			error("Failed to import! Detected a circular dependency chain: " .. str, 2)
		end
	end

	if not registeredLibraries[module] then
		if _G[module] then
			error(
				"Invalid module access! Do you have two TS runtimes trying to import this? " .. module:GetFullName(),
				2
			)
		end

		_G[module] = TS
		registeredLibraries[module] = true -- register as already loaded for subsequent calls
	end

	local data = require(module)

	if currentlyLoading[caller] == module then -- Thread-safe cleanup!
		currentlyLoading[caller] = nil
	end

	return data
end

function TS.instanceof(obj, class)
	-- custom Class.instanceof() check
	if type(class) == "table" and type(class.instanceof) == "function" then
		return class.instanceof(obj)
	end

	-- metatable check
	if type(obj) == "table" then
		obj = getmetatable(obj)
		while obj ~= nil do
			if obj == class then
				return true
			end
			local mt = getmetatable(obj)
			if mt then
				obj = mt.__index
			else
				obj = nil
			end
		end
	end

	return false
end

function TS.async(callback)
	return function(...)
		local n = select("#", ...)
		local args = { ... }
		return Promise.new(function(resolve, reject)
			coroutine.wrap(function()
				local ok, result = pcall(callback, unpack(args, 1, n))
				if ok then
					resolve(result)
				else
					reject(result)
				end
			end)()
		end)
	end
end

function TS.await(promise)
	if not Promise.is(promise) then
		return promise
	end

	local status, value = promise:awaitStatus()
	if status == Promise.Status.Resolved then
		return value
	elseif status == Promise.Status.Rejected then
		error(value, 2)
	else
		error("The awaited Promise was cancelled", 2)
	end
end

function TS.bit_lrsh(a, b)
	local absA = math.abs(a)
	local result = bit32.rshift(absA, b)
	if a == absA then
		return result
	else
		return -result - 1
	end
end

TS.TRY_RETURN = 1
TS.TRY_BREAK = 2
TS.TRY_CONTINUE = 3

function TS.try(func, catch, finally)
	local err, traceback
	local success, exitType, returns = xpcall(
		func,
		function(errInner)
			err = errInner
			traceback = debug.traceback()
		end
	)
	if not success and catch then
		local newExitType, newReturns = catch(err, traceback)
		if newExitType then
			exitType, returns = newExitType, newReturns
		end
	end
	if finally then
		local newExitType, newReturns = finally()
		if newExitType then
			exitType, returns = newExitType, newReturns
		end
	end
	return exitType, returns
end

function TS.generator(callback)
	local co = coroutine.create(callback)
	return {
		next = function(...)
			if coroutine.status(co) == "dead" then
				return { done = true }
			else
				local success, value = coroutine.resume(co, ...)
				if success == false then
					error(value, 2)
				end
				return {
					value = value,
					done = coroutine.status(co) == "dead",
				}
			end
		end,
	}
end

-- LEGACY RUNTIME FUNCTIONS --

-- @rbxts/projectile
function TS.array_concat(...)
	local result = {}
	local len = 0
	for i = 1, select("#", ...) do
		local list2 = select(i, ...)
		local len2 = #list2
		for j = 1, len2 do
			result[len + j] = list2[j]
		end
		len = len + len2
	end
	return result
end

-- @rbxts/jack-utils
function TS.array_find(list, callback)
	for i = 1, #list do
		local v = list[i]
		if callback(v, i - 1, list) == true then
			return v
		end
	end
end

-- @rbxts/algorite
-- @rbxts/debouncelib
-- @rbxts/firestore
function TS.array_forEach(list, callback)
	for i = 1, #list do
		callback(list[i], i - 1, list)
	end
end

-- @rbxts/basic-utilities
function TS.array_reverse(list)
	local result = {}
	local length = #list
	local n = length + 1
	for i = 1, length do
		result[i] = list[n - i]
	end
	return result
end

-- @rbxts/basic-utilities
-- @rbxts/roact-studio-components
-- @rbxts/server-networked-values
-- @rbxts/timer
-- @rbxts/touch-screen-joysticks
function TS.exportNamespace(module, ancestor)
	for key, value in pairs(module) do
		ancestor[key] = value
	end
end

-- @rbxts/basic-utilities
function TS.map_entries(object)
	local result = {}
	for key, value in pairs(object) do
		result[#result + 1] = { key, value }
	end
	return result
end

-- @rbxts/basic-utilities
-- @rbxts/firestore
function TS.map_forEach(map, callback)
	for key, value in pairs(map) do
		callback(value, key, map)
	end
end

-- @rbxts/basic-utilities
function TS.map_keys(object)
	local result = {}
	for key in pairs(object) do
		result[#result + 1] = key
	end
	return result
end

-- @rbxts/basic-utilities
function TS.map_new(pairs)
	local result = {}
	if pairs then
		for i = 1, #pairs do
			local pair = pairs[i]
			result[pair[1]] = pair[2]
		end
	end
	return result
end

-- @rbxts/basic-utilities
function TS.map_size(map)
	local result = 0
	for _ in pairs(map) do
		result = result + 1
	end
	return result
end

-- @rbxts/basic-utilities
function TS.map_toString(data)
	return game:GetService("HttpService"):JSONEncode(data)
end

-- @rbxts/basic-utilities
function TS.map_values(object)
	local result = {}
	for _, value in pairs(object) do
		result[#result + 1] = value
	end
	return result
end

-- @rbxts/baseplate
function TS.Object_assign(toObj, ...)
	for i = 1, select("#", ...) do
		local arg = select(i, ...)
		if type(arg) == "table" then
			for key, value in pairs(arg) do
				toObj[key] = value
			end
		end
	end
	return toObj
end

-- @rbxts/datastore-light
function TS.opcall(func, ...)
	local success, valueOrErr = pcall(func, ...)
	if success then
		return {
			success = true,
			value = valueOrErr,
		}
	else
		return {
			success = false,
			error = valueOrErr,
		}
	end
end

-- @rbxts/roact-studio-components
function TS.Roact_combine(...)
	local args = { ... }
	local result = {}
	for i = 1, #args do
		for key, value in pairs(args[i]) do
			if (type(key) == "number") then
				table.insert(result, value)
			else
				result[key] = value
			end
		end
	end
	return result
end

-- @rbxts/hook
function TS.set_values(object)
	local result = {}
	for key in pairs(object) do
		result[#result + 1] = key
	end
	return result
end

-- @rbxts/algorite
function TS.string_endsWith(str1, str2, pos)
	local n1 = #str1
	local n2 = #str2

	if pos == nil then
		pos = n1
	elseif pos ~= pos then
		pos = 0
	else
		pos = math.clamp(pos, 0, n1)
	end

	local start = pos - n2 + 1
	return start > 0 and string.sub(str1, start, pos) == str2
end

return TS
