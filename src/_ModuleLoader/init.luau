--!strict
--[[
	----
	crusherfire's Module Loader!
	08/05/2025
	----
	
	-- FEATURES --
	"LoaderPriority" number attribute:
	Set this attribute on a ModuleScript to modify the loading priority. Larger number == higher priority.

	"RelocateToServerScriptService" boolean attribute:
	Relocates a module to ServerScriptService and leave a pointer in its place to hide server code from clients.
	This should only be performed on server-only modules that you want to organize within the same containers in Studio.
	
	"ClientOnly" or "ServerOnly" boolean attributes:
	Allows you to restrict a module from being loaded on a specific run context.
	
	"Parallel" boolean attribute:
	Requires the module from another script within its own actor for executing code in parallel.
	
	"IgnoreLoader" boolean attribute:
	Allows you to prevent a module from being loaded.
	
	Supports CollectionService tags by placing the tag name (defined by LoaderTag attribute) on ModuleScript instances.
	
	-- LOADER ATTRIBUTE SETTINGS --
	ClientWaitForServer: Client avoids starting the module loading process until the server finishes.
	FolderSearchDepth: How deep the loader will search for modules to load in a folder. '1' represents the direct children.
	LoaderTag: Tag to be set on modules you want to load that are not within loaded containers.
	VerboseLoading: If messages should be output that document the loading process
	YieldThreshold: How long to wait (in seconds) before displaying warning messages when a particular module is yielidng for too long
	UseCollectionService: If the loader should search for modules to load based on LoaderTag
	
	-- DEFAULT FILTERING BEHAVIOR --
	Respects "ClientOnly", "ServerOnly", and "IgnoreLoader" attributes.
	
	Modules that are not a direct child of a given container or whose ancestry are not folders
	that lead back to a container will not be loaded when the FolderSearchDepth is a larger value.
	
	NOTE:
	If you do not like this default filtering behavior, you can pass your own filtering predicate to the StartCustom() function
	and define your own behavior. Otherwise, use the Start() function for the default behavior!
	--------------
]]

-----------------------------
-- SERVICES --
-----------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

-----------------------------
-- VARIABLES --
-----------------------------
local actorForServer: Actor? = script:FindFirstChild("ActorForServer") :: any
local actorForClient: Actor? = script:FindFirstChild("ActorForClient") :: any
local isClient = RunService:IsClient()
local require = require
local loadedEvent: RemoteEvent
if isClient then
	loadedEvent = script:WaitForChild("LoadedEvent") :: any
else
	loadedEvent = Instance.new("RemoteEvent")
	loadedEvent.Name = "LoadedEvent"
	loadedEvent.Parent = script
end

local started = false

local tracker = {
	Load = {} :: { [ModuleScript]: any },
	Init = {} :: { [ModuleScript]: boolean },
	Start = {} :: { [ModuleScript]: boolean },
}

local trackerForActors = {
	Load = {} :: { [ModuleScript]: Actor },
	Init = {},
	Start = {},
}

export type LoaderSettings = {
	FOLDER_SEARCH_DEPTH: number?,
	YIELD_THRESHOLD: number?,
	VERBOSE_LOADING: boolean?,
	WAIT_FOR_SERVER: boolean?,
	USE_COLLECTION_SERVICE: boolean?,
}

export type KeepModulePredicate = (container: Instance, module: ModuleScript) -> boolean

-- CONSTANTS --
local SETTINGS: LoaderSettings = {
	FOLDER_SEARCH_DEPTH = script:GetAttribute("FolderSearchDepth") or 1,
	YIELD_THRESHOLD = script:GetAttribute("YieldThreshold") or 10, -- how long until the module starts warning for a module that is taking too long
	VERBOSE_LOADING = script:GetAttribute("VerboseLoading") == true or false,
	WAIT_FOR_SERVER = script:GetAttribute("ClientWaitForServer") == true or false,
	USE_COLLECTION_SERVICE = script:GetAttribute("UseCollectionService") == true or false,
}

local TAG = script:GetAttribute("LoaderTag") or "LOAD_MODULE"
local PRINT_IDENTIFIER = if isClient then "[C]" else "[S]"
local LOADED_IDENTIFIER = if isClient then "Client" else "Server"
local ACTOR_PARENT = if isClient
	then game:GetService("Players").LocalPlayer.PlayerScripts
	else game:GetService("ServerScriptService")
local RELOCATED_MODULES
do
	if RunService:IsServer() then
		RELOCATED_MODULES = Instance.new("Folder")
		RELOCATED_MODULES.Name = "RELOCATED_MODULES"
		RELOCATED_MODULES.Parent = ServerScriptService
	end
end

-----------------------------
-- PRIVATE FUNCTIONS --
-----------------------------

-- <strong><code>!YIELDS!</code></strong>
local function waitForEither<Func, T...>(eventYes: RBXScriptSignal, eventNo: RBXScriptSignal): boolean
	local thread = coroutine.running()

	local connection1: any = nil
	local connection2: any = nil

	connection1 = eventYes:Once(function(...)
		if connection1 == nil then
			return
		end

		connection1:Disconnect()
		connection2:Disconnect()
		connection1 = nil
		connection2 = nil

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, true, ...)
		end
	end)

	connection2 = eventNo:Once(function(...)
		if connection2 == nil then
			return
		end

		connection1:Disconnect()
		connection2:Disconnect()
		connection1 = nil
		connection2 = nil

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, false, ...)
		end
	end)

	return coroutine.yield()
end

local function copy<T>(t: T, deep: boolean?): T
	if not deep then
		return (table.clone(t :: any) :: any) :: T
	end
	local function deepCopy(object: any)
		assert(typeof(object) == "table", "Expected table for deepCopy!")
		-- Returns a deep copy of the provided table.
		local newObject = setmetatable({}, getmetatable(object)) -- Clone metaData

		for index: any, value: any in object do
			if typeof(value) == "table" then
				newObject[index] = deepCopy(value)
				continue
			end

			newObject[index] = value
		end

		return newObject
	end
	return deepCopy(t :: any) :: T
end

local function reconcile<S, T>(src: S, template: T): S & T
	assert(type(src) == "table", "First argument must be a table")
	assert(type(template) == "table", "Second argument must be a table")

	local tbl = table.clone(src)

	for k, v in template do
		local sv = src[k]
		if sv == nil then
			if type(v) == "table" then
				tbl[k] = copy(v, true)
			else
				tbl[k] = v
			end
		elseif type(sv) == "table" then
			if type(v) == "table" then
				tbl[k] = reconcile(sv, v)
			else
				tbl[k] = copy(sv, true)
			end
		end
	end

	return (tbl :: any) :: S & T
end

-- Returns a new array that is the result of array1 and array2
local function mergeArrays(array1: { [number]: any }, array2: { [number]: any })
	local length = #array2
	local newArray = table.clone(array2)
	for i, v in ipairs(array1) do
		newArray[length + i] = v
	end
	return newArray
end

local function filter<T>(t: { T }, predicate: (T, any, { T }) -> boolean): { T }
	assert(type(t) == "table", "First argument must be a table")
	assert(type(predicate) == "function", "Second argument must be a function")
	local newT = table.create(#t)
	if #t > 0 then
		local n = 0
		for i, v in t do
			if predicate(v, i, t) then
				n += 1
				newT[n] = v
			end
		end
	else
		for k, v in t do
			if predicate(v, k, t) then
				newT[k] = v
			end
		end
	end
	return newT
end

-- Returns the 'depth' of <code>descendant</code> in the child hierarchy of <code>root</code>.
-- If the descendant is not found in <code>root</code>, then this function will return 0.
local function getDepthInHierarchy(descendant: Instance, root: Instance): number
	local depth = 0
	local current: Instance? = descendant
	while current and current ~= root do
		current = current.Parent
		depth += 1
	end
	if not current then
		depth = 0
	end
	return depth
end

local function findAllFromClass(class: string, searchIn: Instance, searchDepth: number?): { any }
	assert(class and typeof(class) == "string", "class is invalid or nil")
	assert(searchIn and typeof(searchIn) == "Instance", "searchIn is invalid or nil")

	local foundObjects = {}

	if searchDepth then
		for _, object in pairs(searchIn:GetDescendants()) do
			if object:IsA(class) and getDepthInHierarchy(object, searchIn) <= searchDepth then
				table.insert(foundObjects, object)
			end
		end
	else
		for _, object in pairs(searchIn:GetDescendants()) do
			if object:IsA(class) then
				table.insert(foundObjects, object)
			end
		end
	end

	return foundObjects
end

local function keepModule(container: Instance, module: ModuleScript): boolean
	if module:GetAttribute("ClientOnly") and RunService:IsServer() then
		return false
	elseif module:GetAttribute("ServerOnly") and RunService:IsClient() then
		return false
	elseif module:GetAttribute("IgnoreLoader") then
		return false
	end
	local ancestor = module.Parent
	while ancestor do
		if ancestor == container then
			-- The ancestry should eventually lead to the container (if ancestors were always folders)
			return true
		elseif not ancestor:IsA("Folder") then
			return false
		end
		ancestor = ancestor.Parent
	end
	return false
end

local function newPrint(...)
	print(PRINT_IDENTIFIER, ...)
end

local function newWarn(...)
	warn(PRINT_IDENTIFIER, ...)
end

local function loadModule(module: ModuleScript)
	-- attempts to relocate the module, if eligible
	local function attemptRelocate(module: ModuleScript)
		if RunService:IsClient() then
			return
		end
		if not module:GetAttribute("RelocateToServerScriptService") then
			return
		end
		if module:IsDescendantOf(ServerScriptService) then
			warn(
				`RelocateToServerScriptService attribute is enabled on module '{module:GetFullName()}' that's already in ServerScriptService`
			)
			return
		end
		local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
		assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")
		local clone = relocatedTemplate:Clone()
		clone.Name = module.Name
		clone:SetAttribute("ServerOnly", true)
		clone.Parent = module.Parent
		module.Parent = RELOCATED_MODULES
	end

	if module:GetAttribute("Parallel") then
		local actorTemplate = if isClient then actorForClient else actorForServer

		if actorTemplate == nil then
			newWarn(`Parallel module {module.Name} requested but no Actor template is configured - loading normally`)
		else
			-- This module needs to be run in parallel, so create new actor and script.
			local newActorSystem = if isClient then actorForClient:Clone() else actorForServer:Clone()
			local actorScript = newActorSystem:FindFirstChildWhichIsA("BaseScript")

			actorScript.Name = `Required{module.Name}`
			newActorSystem.Parent = ACTOR_PARENT

			if not actorScript:GetAttribute("Loaded") then
				actorScript:GetAttributeChangedSignal("Loaded"):Wait()
			end

			newActorSystem:SendMessage("RequireModule", module)

			if SETTINGS.VERBOSE_LOADING then
				newPrint(("Loading PARALLEL module '%s'"):format(module.Name))
			end

			local startTime = tick()
			if not actorScript:GetAttribute("Required") then
				actorScript:GetAttributeChangedSignal("Required"):Wait()
			end
			local endTime = tick()

			if SETTINGS.VERBOSE_LOADING and not actorScript:GetAttribute("Errored") then
				newPrint(`>> Loaded PARALLEL module {module.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
			elseif actorScript:GetAttribute("Errored") then
				newWarn(
					`>> Failed to load PARALLEL module {module.Name}`,
					("(took %.3f seconds)"):format(endTime - startTime)
				)
			end

			-- relocate after loading to maintain relative paths within modules
			attemptRelocate(module)

			trackerForActors.Load[module] = newActorSystem
			tracker.Load[module] = true
			tracker.Init[module] = true
			tracker.Start[module] = true
			return
		end
	end

	if SETTINGS.VERBOSE_LOADING then
		newPrint(("Loading module '%s'"):format(module.Name))
	end
	local mainThread = coroutine.running()
	local startTime = tick()
	local endTime
	local executionSuccess, errMsg = false, ""
	local thread: thread = task.spawn(function()
		debug.setmemorycategory(`Module::{module.Name}`)
		local success, result = xpcall(function()
			return require(module)
		end, debug.traceback)
		debug.resetmemorycategory()
		if success then
			tracker.Load[module] = result
			if result.Init then
				tracker.Init[module] = false
			end
			if result.Start then
				tracker.Start[module] = false
			end
			executionSuccess = true

			-- relocate after loading to maintain relative paths within modules
			attemptRelocate(module)
		else
			errMsg = result
		end
		endTime = tick()
		if coroutine.status(mainThread) == "suspended" then
			task.spawn(mainThread)
		end
	end)
	if not endTime then
		endTime = tick()
	end
	if coroutine.status(thread) == "suspended" then
		local loopThread = task.spawn(function()
			task.wait(SETTINGS.YIELD_THRESHOLD)
			while true do
				if coroutine.status(thread) == "suspended" then
					newWarn(
						`>> Loading Module '{module.Name}' is taking a while!`,
						("(%.3f seconds elapsed)"):format(tick() - startTime)
					)
				end
				task.wait(5)
			end
		end)
		coroutine.yield()
		if coroutine.status(loopThread) ~= "dead" then
			task.cancel(loopThread)
		end
	end

	if SETTINGS.VERBOSE_LOADING and executionSuccess then
		newPrint(`>> Loaded module {module.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
	elseif not executionSuccess then
		newWarn(
			`>> Failed to load module {module.Name}`,
			("(took %.3f seconds)\n%s"):format(endTime - startTime, errMsg)
		)
	end
end

local function initializeModule(loadedModule, module: ModuleScript)
	if trackerForActors.Load[module] then
		local actorScript: BaseScript = trackerForActors.Load[module]:FindFirstChildWhichIsA("BaseScript") :: any
		trackerForActors.Load[module]:SendMessage("InitModule")

		if SETTINGS.VERBOSE_LOADING then
			newPrint(("Initializing PARALLEL module '%s'"):format(actorScript.Name))
		end

		local startTime = tick()
		if not actorScript:GetAttribute("Initialized") then
			actorScript:GetAttributeChangedSignal("Initialized"):Wait()
		end
		local endTime = tick()

		if SETTINGS.VERBOSE_LOADING and not actorScript:GetAttribute("Errored") then
			newPrint(
				`>> Initialized PARALLEL module {actorScript.Name}`,
				("(took %.3f seconds)"):format(endTime - startTime)
			)
		elseif actorScript:GetAttribute("Errored") then
			newWarn(
				`>> Failed to init PARALLEL module {actorScript.Name}`,
				("(took %.3f seconds)"):format(endTime - startTime)
			)
		end
		return
	end

	if not loadedModule.Init then
		return
	end

	if SETTINGS.VERBOSE_LOADING then
		newPrint(("Initializing module '%s'"):format(module.Name))
	end
	local mainThread = coroutine.running()
	local startTime = tick()
	local endTime
	local executionSuccess, errMsg = false, ""
	local thread: thread = task.spawn(function()
		local success, err = xpcall(function()
			loadedModule:Init()
		end, function(err)
			return `{err}\n{debug.traceback()}`
		end)
		executionSuccess = success
		if success then
			tracker.Init[module] = true
		else
			errMsg = err
		end
		endTime = tick()
		if coroutine.status(mainThread) == "suspended" then
			task.spawn(mainThread)
		end
	end)
	if not endTime then
		endTime = tick()
	end
	if coroutine.status(thread) == "suspended" then
		local loopThread = task.spawn(function()
			task.wait(SETTINGS.YIELD_THRESHOLD)
			while true do
				if coroutine.status(thread) == "suspended" then
					newWarn(
						`>> :Init() for Module '{module.Name}' is taking a while!`,
						("(%.3f seconds elapsed)"):format(tick() - startTime)
					)
				end
				task.wait(5)
			end
		end)
		coroutine.yield()
		if coroutine.status(loopThread) ~= "dead" then
			task.cancel(loopThread)
		end
	end

	if SETTINGS.VERBOSE_LOADING and executionSuccess then
		newPrint(`>> Initialized module {module.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
	elseif not executionSuccess then
		newWarn(
			`>> Failed to init module {module.Name}`,
			("(took %.3f seconds)\n%s"):format(endTime - startTime, errMsg)
		)
	end
end

local function startModule(loadedModule, module: ModuleScript)
	if trackerForActors.Load[module] then
		local actorScript: BaseScript = trackerForActors.Load[module]:FindFirstChildWhichIsA("BaseScript") :: any
		trackerForActors.Load[module]:SendMessage("StartModule")

		if SETTINGS.VERBOSE_LOADING then
			newPrint(("Starting PARALLEL module '%s'"):format(actorScript.Name))
		end

		local startTime = tick()
		if not actorScript:GetAttribute("Started") then
			actorScript:GetAttributeChangedSignal("Started"):Wait()
		end
		local endTime = tick()

		if SETTINGS.VERBOSE_LOADING and not actorScript:GetAttribute("Errored") then
			newPrint(
				`>> Started PARALLEL module {actorScript.Name}`,
				("(took %.3f seconds)"):format(endTime - startTime)
			)
		elseif actorScript:GetAttribute("Errored") then
			newWarn(
				`>> Failed to start PARALLEL module {actorScript.Name}`,
				("(took %.3f seconds)"):format(endTime - startTime)
			)
		end
		return
	end

	if not loadedModule.Start then
		return
	end

	if SETTINGS.VERBOSE_LOADING then
		newPrint(("Starting module '%s'"):format(module.Name))
	end
	local mainThread = coroutine.running()
	local startTime = tick()
	local endTime
	local executionSuccess, errMsg = false, ""
	local thread: thread = task.spawn(function()
		local success, err = xpcall(function()
			loadedModule:Start()
		end, function(err)
			return `{err}\n{debug.traceback()}`
		end)
		executionSuccess = success
		if success then
			tracker.Start[module] = true
		else
			errMsg = err
		end
		endTime = tick()
		if coroutine.status(mainThread) == "suspended" then
			task.spawn(mainThread)
		end
	end)
	if not endTime then
		endTime = tick()
	end
	if coroutine.status(thread) == "suspended" then
		local loopThread = task.spawn(function()
			task.wait(SETTINGS.YIELD_THRESHOLD)
			while true do
				if coroutine.status(thread) == "suspended" then
					newWarn(
						`>> :Start() for Module '{module.Name}' is taking a while!`,
						("(%.3f seconds elapsed)"):format(tick() - startTime)
					)
				end
				task.wait(5)
			end
		end)
		coroutine.yield()
		if coroutine.status(loopThread) ~= "dead" then
			task.cancel(loopThread)
		end
	end

	if SETTINGS.VERBOSE_LOADING and executionSuccess then
		newPrint(`>> Started module {module.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
	elseif not executionSuccess then
		newWarn(
			`>> Failed to start module {module.Name}`,
			("(took %.3f seconds)\n%s"):format(endTime - startTime, errMsg)
		)
	end
end

-- Gets all modules to be loaded in order.
local function getModules(containers: { Instance }): { ModuleScript }
	local totalModules = {}
	for _, container in ipairs(containers) do
		local modules = findAllFromClass("ModuleScript", container)
		modules = filter(modules, function(module)
			return keepModule(container, module)
		end)
		totalModules = mergeArrays(totalModules, modules)
	end
	if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" then
		for _, module in CollectionService:GetTagged(TAG) do
			if not module:IsA("ModuleScript") then
				warn(`item: {module} with tag: {TAG} is not a module script!`)
				continue
			end
			if not keepModule(module.Parent, module) then
				continue
			end
			if table.find(totalModules, module) then
				continue
			end
			table.insert(totalModules, module)
		end
	end

	table.sort(totalModules, function(a, b)
		local aPriority = a:GetAttribute("LoaderPriority") or 0
		local bPriority = b:GetAttribute("LoaderPriority") or 0

		return aPriority > bPriority
	end)
	return totalModules
end

-----------------------------
-- MAIN --
-----------------------------

--[[
	Starts the loader with the default module filtering behavior.
]]
local function start(...: Instance)
	assert(not started, "attempt to start module loader more than once")
	started = true
	local containers = { ... }
	if isClient and SETTINGS.WAIT_FOR_SERVER and not workspace:GetAttribute("ServerLoaded") then
		workspace:GetAttributeChangedSignal("ServerLoaded"):Wait()
	end

	if SETTINGS.VERBOSE_LOADING then
		newWarn("=== LOADING MODULES ===")
		local modules = getModules(containers)
		for _, module in modules do
			loadModule(module)
		end

		newWarn("=== INITIALIZING MODULES ===")
		for _, module in modules do
			if not tracker.Load[module] then
				continue
			end
			initializeModule(tracker.Load[module], module)
		end

		newWarn("=== STARTING MODULES ===")
		for _, module in modules do
			if not tracker.Load[module] then
				continue
			end
			startModule(tracker.Load[module], module)
		end

		newWarn("=== LOADING FINISHED ===")
	else
		local modules = getModules(containers)
		for _, module in modules do
			loadModule(module)
		end
		for _, module in modules do
			if not tracker.Load[module] then
				continue
			end
			if tracker.Load[module] then
				initializeModule(tracker.Load[module], module)
			end
		end
		for _, module in modules do
			if not tracker.Load[module] then
				continue
			end
			if tracker.Load[module] then
				startModule(tracker.Load[module], module)
			end
		end
	end

	workspace:SetAttribute(`{LOADED_IDENTIFIER}LoadedTimestamp`, workspace:GetServerTimeNow())
	workspace:SetAttribute(`{LOADED_IDENTIFIER}Loaded`, true)
	if RunService:IsClient() then
		loadedEvent:FireServer()
	end
end

--[[
	Starts the loader with your own custom module filtering behavior for determining what modules should be loaded.
]]
local function startCustom(shouldKeep: KeepModulePredicate, ...: Instance)
	keepModule = shouldKeep
	start(...)
end

--[[
	Returns if the client finished loading, initializing, and starting all modules.
]]
local function isClientLoaded(player: Player): boolean
	return player:GetAttribute("_ModulesLoaded") == true
end

--[[
	Returns if the server finished loading, initializing, and starting all modules.
]]
local function isServerLoaded(): boolean
	return workspace:GetAttribute("ServerLoaded") == true
end

--[[
	<strong><code>!YIELDS!</code></strong>
	Yields until the client has loaded all their modules.
	Returns true if loaded or returns false if player left.
]]
local function waitForLoadedClient(player: Player): boolean
	if not player:GetAttribute("_ModulesLoaded") then
		return waitForEither(
			player:GetAttributeChangedSignal("_ModulesLoaded"),
			player:GetPropertyChangedSignal("Parent")
		)
	end
	return true
end

--[[
	Modify the default settings determined by the attributes on the module loader.
	The given <code>settings</code> are reconciled with the current settings.
]]
local function changeSettings(settings: LoaderSettings)
	SETTINGS = reconcile(settings, SETTINGS)
end

--[[
	Errors if the server is not loaded yet.
]]
local function getServerLoadedTimestamp()
	assert(isServerLoaded(), "server is not loaded yet!")
	return workspace:GetAttribute("ServerLoadedTimestamp")
end

if not isClient then
	loadedEvent.OnServerEvent:Connect(function(player)
		player:SetAttribute("_ModulesLoaded", true)
	end)
end

return {
	Start = start,
	StartCustom = startCustom,
	ChangeSettings = changeSettings,
	IsServerLoaded = isServerLoaded,
	IsClientLoaded = isClientLoaded,
	WaitForLoadedClient = waitForLoadedClient,
	GetServerLoadedTimestamp = getServerLoadedTimestamp,
}
