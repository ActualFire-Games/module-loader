--!strict
--[[
	----
	crusherfire's Module Loader!
	08/05/2025
	Updated: 05/22/26
	----
	
	-- FEATURES --
	"LoaderPriority" number attribute:
	Set this attribute on a ModuleScript to modify the loading priority. Larger number == higher priority.
	Defaults to 0.

	"RelocateToServerScriptService" boolean attribute:
	Relocates a module to ServerScriptService and leave a pointer in its place to hide server code from clients.
	This should only be performed on server-only modules that you want to organize within the same containers in Studio.
	NOTE: relocation happens AFTER the module is required, so yielding in top-level code widens the window where
	server code is still client-visible (see [SECURITY] warnings below).
	
	"RelocateToReplicatedStorage" boolean attribute (on ModuleScript OR Folder):
	Inverse of RelocateToServerScriptService and keeps the recommended default of having everything living in
	ServerScriptService while still exposing modules that need to reach the client (shared libraries, client-only modules).
	Relocates the module BEFORE any require() call via a server-side pre-pass, so there is no in-flight window
	where server code is client-visible.
	
	The module is moved to ReplicatedStorage.RELOCATED_MODULES, with the full folder hierarchy between
	the container and the module mirrored under that root. This preserves relative require paths such as
	require(script.Parent.Sibling) and string requires like require("../Sibling"), provided every endpoint
	of those requires is also relocated.
	
	When set on a Folder, the attribute cascades to every descendant ModuleScript (and the mirrored
	hierarchy is built for the whole subtree). Use this for tightly-coupled shared subtrees so all
	relative requires inside them keep resolving.
	
	A hierarchy-aware pointer is left at the original ServerScriptService location so that server modules
	requiring the relocated module via relative paths continue to work transparently.
	
	Children of the module (e.g., assets stored as descendants) move with the module.
	Convention: when another module needs to access those children, the owning module should expose them
	via its return table rather than other modules indexing for them.
	
	Setting both RelocateToServerScriptService and RelocateToReplicatedStorage directly on the same
	module emits a warning and skips relocation. Modules already in ReplicatedStorage also emit a
	warning and are skipped.

	OPT-OUT FROM CASCADE: When a Folder ancestor cascades RelocateToReplicatedStorage, you can keep
	specific descendant modules on the server by setting RelocateToServerScriptService = true on them
	directly. Those modules skip the ReplicatedStorage pre-pass and are instead picked up by the
	standard ServerScriptService relocation flow during loading.
	NOTE: relative requires inside an RS-relocated module pointing at SSS opt-out siblings will not
	resolve at runtime (the mirrored ReplicatedStorage folder doesn't contain them). Cross-realm
	references must go through the loader, absolute paths, or remotes.
	
	"ClientOnly" or "ServerOnly" boolean attributes:
	Allows you to restrict a module from being loaded on a specific run context.
	
	"Parallel" boolean attribute:
	Requires the module from another script within its own actor for executing code in parallel.
	
	"IgnoreLoader" boolean attribute:
	Allows you to prevent a module from being loaded.
	
	Supports CollectionService tags on ModuleScripts AND Folders. Tagging a Folder loads every
	descendant ModuleScript (subject to ClientOnly / ServerOnly / IgnoreLoader filtering).
	If a tagged folder is also marked for RelocateToReplicatedStorage, the relocation pre-pass
	mirrors the tag onto the corresponding folder under ReplicatedStorage.RELOCATED_MODULES so
	clients discover the relocated modules via the same tag without extra setup. A module that
	resolves to an already-loaded value (e.g. via both a pointer and its real target) is
	deduplicated automatically so Init/Start fire once per loaded result.
	
	-- LOADER ATTRIBUTE SETTINGS --
	ClientWaitForPersistentLoaded: Client waits for all persistent models to be loaded in workspace if instance streaming is enabled.
	ClientWaitForServer: Client avoids starting the module loading process until the server finishes.
	FolderSearchDepth: How deep the loader will search for modules to load in a folder. '1' represents the direct children.
	LoaderTag: Tag to be set on ModuleScripts (or Folders, to load every descendant ModuleScript)
	you want to load that are not within loaded containers.
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
	
	-- LOADER STATE ATTRIBUTES (on this ModuleLoader script itself) --
	"RelocationComplete": Set to true by the server immediately after the RelocateToReplicatedStorage
	pre-pass completes. Clients yield on this attribute before starting their own loader pass.
	
	"ServerLoaded" / "ServerLoadedTimestamp": Replaces the previous workspace.ServerLoaded /
	workspace.ServerLoadedTimestamp attributes. Read via ModuleLoader.IsServerLoaded() and
	ModuleLoader.GetServerLoadedTimestamp().
	BREAKING CHANGE: external code that read these flags from workspace directly must switch
	to reading from the ModuleLoader script (or use the API methods).
	--------------
]]

-----------------------------
-- SERVICES --
-----------------------------
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-----------------------------
-- VARIABLES --
-----------------------------
local parallelModuleLoader = script.ParallelModuleLoader
local actorForServer: Actor? = script:FindFirstChild("ActorForServer") :: any
local actorForClient: Actor? = script:FindFirstChild("ActorForClient") :: any
local isClient = RunService:IsClient()
local isServer = RunService:IsServer()
local require = require
local loadedEvent: RemoteEvent
if isClient then
	loadedEvent = script:WaitForChild("LoadedEvent") :: RemoteEvent
else
	loadedEvent = Instance.new("RemoteEvent")
	loadedEvent.Name = "LoadedEvent"
	loadedEvent.Parent = script
end

local started = false

local tracker = {
	Load = {} :: { [ModuleScript]: any },
	Init = {} :: { [ModuleScript]: boolean },
	Start = {} :: { [ModuleScript]: boolean }
}

local trackerForActors = {
	Load = {} :: { [ModuleScript]: Actor },
	Init = {},
	Start = {}
}

-- Indexed by the table that a successful require() returned. Lets the loader
-- skip duplicate Init/Start when two ModuleScripts resolve to the same value
-- (most notably a relocation pointer and its real target both being discovered).
local seenResults: { [any]: true } = {}

export type LoaderSettings = {
	WAIT_FOR_PERSISTENT: boolean?,
	FOLDER_SEARCH_DEPTH: number?,
	YIELD_THRESHOLD: number?,
	VERBOSE_LOADING: boolean?,
	WAIT_FOR_SERVER: boolean?,
	USE_COLLECTION_SERVICE: boolean?,
}

export type KeepModulePredicate = (container: Instance, module: ModuleScript) -> (boolean)

-- CONSTANTS --
local SETTINGS: LoaderSettings = {
	WAIT_FOR_PERSISTENT = script:GetAttribute("ClientWaitForPersistentLoaded") == true or false,
	FOLDER_SEARCH_DEPTH = (script:GetAttribute("FolderSearchDepth") :: number?) or 1,
	YIELD_THRESHOLD = (script:GetAttribute("YieldThreshold") :: number?) or 10, -- how long until the module starts warning for a module that is taking too long
	VERBOSE_LOADING = script:GetAttribute("VerboseLoading") == true or false,
	WAIT_FOR_SERVER = script:GetAttribute("ClientWaitForServer") == true or false,
	USE_COLLECTION_SERVICE = script:GetAttribute("UseCollectionService") == true or false,
}

local PRINT_IDENTIFIER = if isClient then "[C]" else "[S]"
local LOADED_IDENTIFIER = if isClient then "Client" else "Server"
local ACTOR_PARENT = if isClient then (Players.LocalPlayer :: Player).PlayerScripts else game:GetService("ServerScriptService")
local TAG: string = (script:GetAttribute("LoaderTag") :: string?) or "LOAD_MODULE"
local RELOCATED_MODULES do
	if RunService:IsServer() then
		RELOCATED_MODULES = Instance.new("Folder")
		RELOCATED_MODULES.Name = "RELOCATED_MODULES"
		RELOCATED_MODULES.Parent = ServerScriptService
	end
end
-- Lazily created on the server only when the first RelocateToReplicatedStorage target is
-- encountered. Keeping creation lazy lets the client short-circuit waitForRelocationReady
-- when no modules were relocated, avoiding a baseline startup cost.
local REPLICATED_RELOCATED_MODULES: Folder? = nil
local function ensureReplicatedRelocatedFolder(): Folder
	local cached = REPLICATED_RELOCATED_MODULES
	if cached then
		return cached
	end
	local existing = ReplicatedStorage:FindFirstChild("RELOCATED_MODULES")
	local folder: Folder
	if existing and existing:IsA("Folder") then
		folder = existing :: Folder
	else
		folder = Instance.new("Folder")
		folder.Name = "RELOCATED_MODULES"
		folder.Parent = ReplicatedStorage
	end
	REPLICATED_RELOCATED_MODULES = folder
	return folder
end


-----------------------------
-- PRIVATE FUNCTIONS --
-----------------------------

--[[
	Yields until either signal fires.
]]
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
		local newObject = setmetatable({}, getmetatable(object)) :: any -- Clone metaData

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

	local tbl = table.clone(src) :: any

	for k, v in (template :: any) do
		local sv = (src :: any)[k]
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

--[[
	Returns a new array that is the result of array1 and array2
]]
local function mergeArrays(array1: {[number]: any}, array2: {[number]: any})
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

--[[
	Returns the 'depth' of <code>descendant</code> in the child hierarchy of <code>root</code>.
	If the descendant is not found in <code>root</code>, then this function will return 0.
]]
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

-----------------------------
-- RELOCATION HELPERS --
-----------------------------

--[[
	Returns the dot-separated path from <code>module</code> up to (but excluding) <code>container</code>.
]]
local function getDottedPathToContainer(module: Instance, container: Instance): string
	local segments = { module.Name }
	local current: Instance? = module.Parent
	while current and current ~= container do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end
	return table.concat(segments, ".")
end

--[[
	Given the ordered list of original ancestor folders (outermost to innermost,
	exclusive of both the container and the module itself), creates or reuses
	Folder instances under <code>rootFolder</code> to mirror the chain. Returns the deepest
	mirrored folder (or <code>rootFolder</code> itself if <code>ancestor</code> is empty).
]]
local function getOrCreateMirroredParent(rootFolder: Folder, ancestors: { Instance }): Folder
	local current: Folder = rootFolder
	for _, original in ipairs(ancestors) do
		local existing = current:FindFirstChild(original.Name)
		if existing and existing:IsA("Folder") then
			current = existing :: Folder
		else
			local folder = Instance.new("Folder")
			folder.Name = original.Name
			folder.Parent = current
			current = folder
		end
		-- Mirror the configured loader tag onto the mirror folder if the original
		-- carries it, so the client (which can't see the SSS original) discovers
		-- relocated modules via the same tag walk that the server uses.
		if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" and CollectionService:HasTag(original, TAG) then
			if not CollectionService:HasTag(current, TAG) then
				CollectionService:AddTag(current, TAG)
			end
		end
	end
	return current
end

--[[
	Returns true if <code>module</code> is marked for RelocateToReplicatedStorage either
	directly or via a Folder ancestor (cascade) between it and <code>container</code>.
]]
local function isMarkedForReplicatedRelocation(module: ModuleScript, container: Instance): boolean
	if module:GetAttribute("RelocateToReplicatedStorage") then
		return true
	end
	local ancestor = module.Parent
	while ancestor and ancestor ~= container do
		if ancestor:IsA("Folder") and ancestor:GetAttribute("RelocateToReplicatedStorage") then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

--[[
	Server-only pre-pass: Walks each container for modules marked with
	RelocateToReplicatedStorage (directly or via folder cascade) and moves each
	to a mirrored hierarchy under ReplicatedStorage.RELOCATED_MODULES, leaving
	a hierarchy-aware pointer behind so relative requires from neighboring
	server modules still resolve.
]]
local function relocateToReplicatedStoragePass(containers: { Instance })
	if not RunService:IsServer() then
		return
	end

	local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")

	local destination: Folder? = nil

	for _, container in ipairs(containers) do
		local modules = findAllFromClass("ModuleScript", container) :: { ModuleScript }
		for _, module in ipairs(modules) do
			-- Pointers from previous passes (or overlapping containers) are already
			-- mirroring the real module — never try to relocate one again.
			if module:GetAttribute("_RelocatedService") ~= nil then
				continue
			end
			local directRS = module:GetAttribute("RelocateToReplicatedStorage") == true
			local directSSS = module:GetAttribute("RelocateToServerScriptService") == true
			-- Both attributes set directly on the same module is genuine user confusion;
			-- warn and skip so neither relocation runs.
			if directRS and directSSS then
				newWarn(
					`RelocateToReplicatedStorage conflicts with RelocateToServerScriptService on module '{module:GetFullName()}'; skipping relocation.`
				)
				continue
			end
			-- An explicit RelocateToServerScriptService on a descendant opts out of any
			-- ancestor folder's RelocateToReplicatedStorage cascade. The SSS relocation
			-- in loadModule.attemptRelocate will handle it during the load pass.
			if directSSS then
				continue
			end
			if not isMarkedForReplicatedRelocation(module, container) then
				continue
			end
			-- A module already inside our destination is a child of a module that
			-- was relocated earlier in this same pass (children move with parents).
			-- Skip silently — relocating it would tear the parent's subtree apart.
			if REPLICATED_RELOCATED_MODULES and module:IsDescendantOf(REPLICATED_RELOCATED_MODULES) then
				continue
			end
			if module:IsDescendantOf(ReplicatedStorage) then
				newWarn(
					`RelocateToReplicatedStorage is enabled on module '{module:GetFullName()}' that's already in ReplicatedStorage; skipping.`
				)
				continue
			end

			-- Collect ancestor folders between container (exclusive) and module's parent (inclusive)
			local ancestors: { Instance } = {}
			local cursor: Instance? = module.Parent
			while cursor and cursor ~= container do
				table.insert(ancestors, 1, cursor)
				cursor = cursor.Parent
			end
			if cursor ~= container then
				newWarn(
					`Module '{module:GetFullName()}' is not a descendant of any provided container; skipping RelocateToReplicatedStorage.`
				)
				continue
			end

			if not destination then
				destination = ensureReplicatedRelocatedFolder()
			end
			local originalParent = module.Parent
			local dottedPath = getDottedPathToContainer(module, container)
			local mirroredParent = getOrCreateMirroredParent(destination :: Folder, ancestors)

			local pointer = relocatedTemplate:Clone()
			pointer.Name = module.Name
			pointer:SetAttribute("_RelocatedService", "ReplicatedStorage")
			pointer:SetAttribute("_RelocatedPath", dottedPath)
			-- Mirror loader-filter attributes onto the pointer so the server's main
			-- load pass treats the pointer the same way it would treat the real module.
			-- Without this, ClientOnly modules would be loaded by the server via
			-- their pointer (because the pointer itself isn't tagged ClientOnly).
			for _, attrName in ipairs({ "ClientOnly", "ServerOnly", "IgnoreLoader", "LoaderPriority", "Parallel" }) do
				local value = module:GetAttribute(attrName)
				if value ~= nil then
					pointer:SetAttribute(attrName, value)
				end
			end

			module.Parent = mirroredParent
			pointer.Parent = originalParent
		end
	end
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
		clone:SetAttribute("_RelocatedService", "ServerScriptService")
		clone:SetAttribute("_RelocatedPath", module.Name)
		clone.Parent = module.Parent
		module.Parent = RELOCATED_MODULES
	end

	if module:GetAttribute("Parallel") then
		local actorTemplate = if isClient then actorForClient else actorForServer

		if actorTemplate == nil then
			newWarn(`Parallel module {module.Name} requested but no Actor template is configured - loading normally`)
		else
			-- This module needs to be run in parallel, so create new actor and script.
			local newActorSystem = actorTemplate:Clone()
			local loaderClone = parallelModuleLoader:Clone()
			loaderClone.Parent = newActorSystem
			local actorScript: BaseScript = newActorSystem:FindFirstChildWhichIsA("BaseScript") :: any

			actorScript.Enabled = true
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
				-- Yielding here is the inherent actor handoff, not a module-level yield --
				-- no security implication. Just wait for the actor to finish requiring.
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
			-- If another ModuleScript already produced this same loaded value
			-- (e.g. a relocation pointer and its real target were both discovered),
			-- skip tracker registration so Init/Start fire exactly once per result.
			if seenResults[result] then
				executionSuccess = true
			else
				seenResults[result] = true
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
			end
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
		-- Only flag yielding modules that are scheduled for SSS-direction relocation,
		-- because that's the only flow where yielding widens a real race window
		-- (relocation happens AFTER require). RelocateToReplicatedStorage uses a
		-- pre-pass and isn't affected by post-require yielding.
		if RunService:IsServer() and module:GetAttribute("RelocateToServerScriptService") then
			newWarn(
				`[SECURITY] Module '{module.Name}' yielded during require()!\n`,
				`Modules with RelocateToServerScriptService may still be accessible to clients.\n`,
				`Avoid yielding in module top-level code to ensure timely relocation.`
			)
		end

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

		local startTime = os.clock()
		if not actorScript:GetAttribute("Initialized") then
			actorScript:GetAttributeChangedSignal("Initialized"):Wait()
		end
		local endTime = os.clock()

		if SETTINGS.VERBOSE_LOADING and not actorScript:GetAttribute("Errored") then
			newPrint(`>> Initialized PARALLEL module {actorScript.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
		elseif actorScript:GetAttribute("Errored") then
			newWarn(`>> Failed to init PARALLEL module {actorScript.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
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
	local startTime = os.clock()
	local endTime
	local executionSuccess, errMsg = false, ""
	local thread: thread = task.spawn(function()
		debug.setmemorycategory(`Module::{module.Name}::Init`)
		local success, err = xpcall(function()
			loadedModule:Init()
		end, debug.traceback)
		debug.resetmemorycategory()
		executionSuccess = success
		if success then
			tracker.Init[module] = true
		else
			errMsg = err
		end
		endTime = os.clock()
		if coroutine.status(mainThread) == "suspended" then
			task.spawn(mainThread)
		end
	end)
	if not endTime then
		endTime = os.clock()
	end
	if coroutine.status(thread) == "suspended" then
		local loopThread = task.spawn(function()
			task.wait(SETTINGS.YIELD_THRESHOLD)
			while true do
				if coroutine.status(thread) == "suspended" then
					newWarn(`>> :Init() for Module '{module.Name}' is taking a while!`, ("(%.3f seconds elapsed)"):format(os.clock() - startTime))
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
		newWarn(`>> Failed to init module {module.Name}`, ("(took %.3f seconds)\n%s"):format(endTime - startTime, errMsg))
	end
end

local function startModule(loadedModule, module: ModuleScript)
	if trackerForActors.Load[module] then
		local actorScript: BaseScript = trackerForActors.Load[module]:FindFirstChildWhichIsA("BaseScript") :: any
		trackerForActors.Load[module]:SendMessage("StartModule")

		if SETTINGS.VERBOSE_LOADING then
			newPrint(("Starting PARALLEL module '%s'"):format(actorScript.Name))
		end

		local startTime = os.clock()
		if not actorScript:GetAttribute("Started") then
			actorScript:GetAttributeChangedSignal("Started"):Wait()
		end
		local endTime = os.clock()

		if SETTINGS.VERBOSE_LOADING and not actorScript:GetAttribute("Errored") then
			newPrint(`>> Started PARALLEL module {actorScript.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
		elseif actorScript:GetAttribute("Errored") then
			newWarn(`>> Failed to start PARALLEL module {actorScript.Name}`, ("(took %.3f seconds)"):format(endTime - startTime))
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
	local startTime = os.clock()
	local endTime
	local executionSuccess, errMsg = false, ""
	local thread: thread = task.spawn(function()
		debug.setmemorycategory(`Module::{module.Name}::Start`)
		local success, err = xpcall(function()
			loadedModule:Start()
		end, debug.traceback)
		debug.resetmemorycategory()
		executionSuccess = success
		if success then
			tracker.Start[module] = true
		else
			errMsg = err
		end
		endTime = os.clock()
		if coroutine.status(mainThread) == "suspended" then
			task.spawn(mainThread)
		end
	end)
	if not endTime then
		endTime = os.clock()
	end
	if coroutine.status(thread) == "suspended" then
		local loopThread = task.spawn(function()
			task.wait(SETTINGS.YIELD_THRESHOLD)
			while true do
				if coroutine.status(thread) == "suspended" then
					newWarn(`>> :Start() for Module '{module.Name}' is taking a while!`, ("(%.3f seconds elapsed)"):format(os.clock() - startTime))
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
		newWarn(`>> Failed to start module {module.Name}`, ("(took %.3f seconds)\n%s"):format(endTime - startTime, errMsg))
	end
end

--[[
	Gets all modules to be loaded in order.
]]
local function getModules(containers: { Instance }): { ModuleScript }
	local totalModules = {}
	for _, container in ipairs(containers) do
		local modules = findAllFromClass("ModuleScript", container, SETTINGS.FOLDER_SEARCH_DEPTH)
		modules = filter(modules, function(module)
			return keepModule(container, module)
		end)
		totalModules = mergeArrays(totalModules, modules)
	end
	if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" then
		local function addTaggedModule(parent: Instance, module: ModuleScript)
			if not keepModule(parent, module) then
				return
			end
			if table.find(totalModules, module) then
				return
			end
			table.insert(totalModules, module)
		end

		for _, tagged in CollectionService:GetTagged(TAG) do
			if tagged:IsA("ModuleScript") then
				local parent = tagged.Parent
				if parent then
					addTaggedModule(parent, tagged)
				end
			elseif tagged:IsA("Folder") then
				for _, descendant in tagged:GetDescendants() do
					if descendant:IsA("ModuleScript") then
						addTaggedModule(tagged, descendant)
					end
				end
			else
				warn(`item: {tagged} with tag: {TAG} is not a ModuleScript or Folder!`)
			end
		end
	end

	table.sort(totalModules, function(a, b)
		local aPriority = a:GetAttribute("LoaderPriority") or 0
		local bPriority = b:GetAttribute("LoaderPriority") or 0

		return aPriority > bPriority
	end)
	return totalModules
end

--[[
	Client-only: Yields until the server's relocation pre-pass is done and the
	ReplicatedStorage relocation tree has settled. The quiet-period gate
	(no DescendantAdded fires for QUIET_PERIOD seconds on RELOCATED_MODULES)
	absorbs replication lag for the first joining client.
	Hard cap of HARD_CAP seconds end-to-end so a missing flag can't hang the client.
]]
local function waitForRelocationReady()
	if not RunService:IsClient() then
		return
	end
	local HARD_CAP = 15
	local QUIET_PERIOD = 5
	local deadline = os.clock() + HARD_CAP

	if not script:GetAttribute("RelocationComplete") then
		local thread = coroutine.running()
		local resumed = false
		local function resume()
			if resumed then
				return
			end
			resumed = true
			if coroutine.status(thread) == "suspended" then
				task.spawn(thread)
			end
		end
		local connection: RBXScriptConnection? = nil
		connection = script:GetAttributeChangedSignal("RelocationComplete"):Connect(function()
			if script:GetAttribute("RelocationComplete") then
				if connection then
					connection:Disconnect()
				end
				resume()
			end
		end)
		task.delay(math.max(0, deadline - os.clock()), function()
			if connection then
				connection:Disconnect()
			end
			resume()
		end)
		coroutine.yield()
	end

	-- The server only creates ReplicatedStorage.RELOCATED_MODULES when it actually
	-- moves at least one module. If RelocationComplete is true and the folder hasn't
	-- shown up, the server had nothing to relocate; skip the quiet-period gate so we
	-- don't tax every client with a 5-second wait when the feature isn't in use.
	local NO_RELOCATION_WINDOW = 1
	local detectionBudget = math.min(NO_RELOCATION_WINDOW, math.max(0, deadline - os.clock()))
	local relocated = ReplicatedStorage:FindFirstChild("RELOCATED_MODULES")
	if not relocated and detectionBudget > 0 then
		relocated = ReplicatedStorage:WaitForChild("RELOCATED_MODULES", detectionBudget)
	end
	if not relocated then
		return
	end

	local lastFire = os.clock()
	local connection = relocated.DescendantAdded:Connect(function()
		lastFire = os.clock()
	end)
	while true do
		local now = os.clock()
		local sinceLast = now - lastFire
		if sinceLast >= QUIET_PERIOD then
			break
		end
		if now >= deadline then
			newWarn(`waitForRelocationReady hit {HARD_CAP}s hard cap; proceeding regardless`)
			break
		end
		task.wait(math.min(QUIET_PERIOD - sinceLast, math.max(0, deadline - now)))
	end
	connection:Disconnect()
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
	local containers = {...}
	if isServer then
		relocateToReplicatedStoragePass(containers)
		script:SetAttribute("RelocationComplete", true)
	else
		waitForRelocationReady()
	end
	if
		isClient
		and SETTINGS.WAIT_FOR_SERVER
		and not script:GetAttribute("ServerLoaded")
	then
		script:GetAttributeChangedSignal("ServerLoaded"):Wait()
	end
	if
		isClient
		and SETTINGS.WAIT_FOR_PERSISTENT
		and not workspace:GetAttribute("IsPersistentLoaded")
	then
		workspace:GetAttributeChangedSignal("IsPersistentLoaded"):Wait()
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
			initializeModule(tracker.Load[module], module)
		end
		for _, module in modules do
			if not tracker.Load[module] then
				continue
			end
			startModule(tracker.Load[module], module)
		end
	end

	script:SetAttribute(`{LOADED_IDENTIFIER}LoadedTimestamp`, workspace:GetServerTimeNow())
	script:SetAttribute(`{LOADED_IDENTIFIER}Loaded`, true)
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
	Client-only.
]]
local function isPersistentLoaded()
	assert(RunService:IsClient(), "isPersistentLoaded is client-only!")
	return workspace:GetAttribute("IsPersistentLoaded") == true
end

--[[
	Returns if the server finished loading, initializing, and starting all modules.
]]
local function isServerLoaded(): boolean
	return script:GetAttribute("ServerLoaded") == true
end

--[[
	<strong><code>!YIELDS!</code></strong>
	Yields until the client has loaded all their modules.
	Returns true if loaded or returns false if player left.
]]
local function waitForLoadedClient(player: Player): boolean
	if not player:GetAttribute("_ModulesLoaded") then
		return waitForEither(player:GetAttributeChangedSignal("_ModulesLoaded"), player:GetPropertyChangedSignal("Parent"))
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
	return script:GetAttribute("ServerLoadedTimestamp")
end

if isServer then
	local clone = script.PersistentLoadedCheck:Clone()
	clone.Enabled = true
	clone.Parent = ReplicatedFirst
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
	IsPersistentLoaded = isPersistentLoaded,
	WaitForLoadedClient = waitForLoadedClient,
	GetServerLoadedTimestamp = getServerLoadedTimestamp
}