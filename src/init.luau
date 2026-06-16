--!strict
--[[
	----
	crusherfire's Module Loader
	Created: 08/05/2025
	Updated: 06/15/2026
	----

	A lightweight loader that finds ModuleScripts, loads them in priority order, and runs
	an optional :Init() then :Start() lifecycle method on each. Runs on the server and the
	client. Configure it with attributes on modules, on folders (which cascade to their
	descendant modules), or on the loader script itself.

	-- MODULE ATTRIBUTES --
	Set on a ModuleScript, or on a Folder to cascade to every descendant ModuleScript.

	LoaderPriority (number, default 0)
		Higher numbers load first.

	ClientOnly / ServerOnly (boolean)
		Restrict a module to one run context. A value set on the module itself (even
		false) overrides a cascading folder value, and the closest folder wins.

	IgnoreLoader (boolean)
		Skip the module completely. Same cascade and override rules as ClientOnly.

	Parallel (boolean)
		Require the module inside its own Actor so its code can run in parallel.

	RelocateToServerScriptService (boolean)
		Move a server-only module into ServerScriptService after it is required and leave
		a pointer in its place. Hides server code from clients while keeping modules
		organized inside shared containers.
		Gotcha: the move happens after the require, so yielding in top-level code keeps the
		module visible to clients for longer. Avoid yielding at the top level.

	RelocateToReplicatedStorage (boolean)
		The inverse. Keep everything in ServerScriptService by default and expose only the
		modules clients need. A server pre-pass moves the module into
		ReplicatedStorage.RELOCATED_MODULES before any require runs, so the code is never
		briefly visible to clients.

		The folders between the container and the module are mirrored under that root, so
		relative requires like require(script.Parent.Sibling) and string requires like
		require("../Sibling") keep working when every endpoint is also relocated. A
		pointer stays at the original location so server-side requires still resolve.

		Client rebuild (default since v3.0):
			Every client recreates the module's original ServerScriptService path inside its
			own local ServerScriptService, with a pointer at the leaf that resolves to the
			real module in ReplicatedStorage. A path such as require(game.ServerScriptService.A.B.C)
			then resolves the same on client and server. The real module still exists only once,
			in ReplicatedStorage.

		Cascade: set on a Folder to relocate the whole subtree (folders discovered by a
		container OR by LoaderTag).
			A module's own value wins over an ancestor folder, closest folder wins among
			nested folders. RelocateToReplicatedStorage = false on a module opts it out of
			an ancestor's cascade while staying loadable on the server. RelocateToServerScriptService
			= true opts out and hides it on the server instead. Only modules whose ancestry up
			to the folder is made of Folders are relocated.

		Gotchas:
			Descendants of a relocated module (assets, child modules) move with it. Expose
			them through the module's return table instead of indexing for them directly.

			An opted-out, server-only sibling cannot be reached by a relative require on the
			client, since it stays in ServerScriptService. Cross realms through the loader,
			an absolute path, or a remote.

			Setting both Relocate attributes on one module warns and skips it. A module
			already in ReplicatedStorage also warns and is skipped.

	-- COLLECTION SERVICE --
	Enable UseCollectionService and tag ModuleScripts or Folders with LoaderTag to load
	modules that live outside the containers you pass in. Tagging a Folder loads every
	descendant ModuleScript, subject to the filtering attributes above. Tags on a
	relocated folder are mirrored into ReplicatedStorage so clients find the modules by
	the same tag. A module that resolves to an already loaded value is deduplicated, so
	Init and Start run once per result.

	-- LOADER SETTINGS --
	Set as attributes on the ModuleLoader script. ChangeSettings() overrides them at runtime.

	FolderSearchDepth (number, default 1)
		How deep to search a container, where 1 is its direct children.
	YieldThreshold (number, default 10)
		Seconds a module may run before a slow-load warning logs.
	VerboseLoading (boolean)
		Log each step of the loading process.
	UseCollectionService (boolean)
		Discover modules to load by LoaderTag.
	LoaderTag (string, default LOAD_MODULE)
		The tag used for CollectionService discovery.
	ClientWaitForServer (boolean)
		Client waits for the server to finish loading before it starts.
	ClientWaitForPersistentLoaded (boolean)
		Client waits for persistent models to stream into workspace first.

	-- DEFAULT FILTERING --
	Start() loads a module only when its path back to the container is all folders and it
	sits within FolderSearchDepth, and it respects ClientOnly, ServerOnly, and IgnoreLoader.
	Pass your own predicate to StartCustom() to replace this behavior.

	-- LOADER STATE (attributes on this script) --
	RelocationComplete
		Set by the server once the relocation pre-pass finishes.
		Clients wait on it before running their own pass.
	ServerLoaded / ServerLoadedTimestamp
		Read them through IsServerLoaded() and GetServerLoadedTimestamp().

	Breaking change:
		ServerLoaded and ServerLoadedTimestamp now live on this script instead of on workspace.
		Code that read them from workspace must use the API methods.
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
	-- ClientOnly / ServerOnly / IgnoreLoader cascade from Folder ancestors. A value
	-- set directly on the module (including explicit `false`) wins over the cascade;
	-- within the ancestor chain, the closest Folder with a non-nil value wins.
	local clientOnly: any = module:GetAttribute("ClientOnly")
	local serverOnly: any = module:GetAttribute("ServerOnly")
	local ignore: any = module:GetAttribute("IgnoreLoader")

	local ancestor: Instance? = module.Parent
	local foundContainer = false
	while ancestor do
		if ancestor:IsA("Folder") then
			if clientOnly == nil then
				clientOnly = ancestor:GetAttribute("ClientOnly")
			end
			if serverOnly == nil then
				serverOnly = ancestor:GetAttribute("ServerOnly")
			end
			if ignore == nil then
				ignore = ancestor:GetAttribute("IgnoreLoader")
			end
		end
		if ancestor == container then
			foundContainer = true
			break
		elseif not ancestor:IsA("Folder") then
			return false
		end
		ancestor = ancestor.Parent
	end
	if not foundContainer then
		return false
	end

	if clientOnly and RunService:IsServer() then
		return false
	elseif serverOnly and RunService:IsClient() then
		return false
	elseif ignore then
		return false
	end
	return true
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
	Returns the dot-separated path from <code>service</code> (exclusive) down to <code>instance</code>
	(inclusive), e.g. "Gameplay.Combat.DamageMath". Returns <code>nil</code> if <code>instance</code>
	is not a descendant of <code>service</code>. Unlike getDottedPathToContainer this anchors to a
	service so the client can rebuild the full original hierarchy under its own local ServerScriptService.
]]
local function getDottedPathFromService(instance: Instance, service: Instance): string?
	local segments = { instance.Name }
	local current: Instance? = instance.Parent
	while current and current ~= service do
		table.insert(segments, 1, current.Name)
		current = current.Parent
	end
	if current ~= service then
		return nil
	end
	return table.concat(segments, ".")
end

--[[
	Client-only: FindFirstChild-or-creates a plain Folder for each segment under <code>root</code>,
	mirroring an original ServerScriptService folder chain. Returns the deepest folder (or
	<code>root</code> itself if <code>segments</code> is empty). These folders are passive scaffolding
	for relocated-module pointers, so no tags/attributes are mirrored onto them.
]]
local function getOrCreateClientFolderPath(root: Instance, segments: { string }): Instance
	local current: Instance = root
	for _, name in ipairs(segments) do
		local existing = current:FindFirstChild(name)
		if existing and existing:IsA("Folder") then
			current = existing
		else
			local folder = Instance.new("Folder")
			folder.Name = name
			folder.Parent = current
			current = folder
		end
	end
	return current
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
		-- Mirror cascade-relevant attributes so client-side keepModule resolves the
		-- same run-context restrictions the user expressed on the original folder.
		for _, attrName in ipairs({ "ClientOnly", "ServerOnly", "IgnoreLoader" }) do
			local value = original:GetAttribute(attrName)
			if value ~= nil and current:GetAttribute(attrName) == nil then
				current:SetAttribute(attrName, value)
			end
		end
	end
	return current
end

--[[
	Returns true if <code>module</code> should be relocated to ReplicatedStorage. Mirrors keepModule's
	cascade precedence: the module's own RelocateToReplicatedStorage value (including an explicit
	<code>false</code>) wins, then the closest Folder ancestor up to and including <code>container</code>.
	The ancestry up to <code>container</code> must be made of Folders only -- a module nested under a
	non-folder (e.g. a child of another module) is not an independent relocation target; it moves with
	its parent. Returns false if <code>container</code> is never reached.
]]
local function isMarkedForReplicatedRelocation(module: ModuleScript, container: Instance): boolean
	local effective: any = module:GetAttribute("RelocateToReplicatedStorage")
	local ancestor: Instance? = module.Parent
	local foundContainer = false
	while ancestor do
		if ancestor:IsA("Folder") and effective == nil then
			effective = ancestor:GetAttribute("RelocateToReplicatedStorage")
		end
		if ancestor == container then
			-- Read the container's own value (above) before stopping; never walk past it.
			foundContainer = true
			break
		elseif not ancestor:IsA("Folder") then
			return false
		end
		ancestor = ancestor.Parent
	end
	if not foundContainer then
		return false
	end
	return effective == true
end

--[[
	Returns true if <code>module</code> sits under a Folder marked RelocateToReplicatedStorage, in which
	case a RelocateToServerScriptService attribute on it is acting as a cascade opt-out (intentionally
	keeping the module on the server) rather than a redundant request to move an already-server module
	into ServerScriptService. The closest Folder ancestor with the attribute set wins, mirroring the
	cascade precedence used elsewhere.
]]
local function isOptingOutOfReplicatedRelocation(module: Instance): boolean
	local ancestor: Instance? = module.Parent
	while ancestor do
		if ancestor:IsA("Folder") then
			local value = ancestor:GetAttribute("RelocateToReplicatedStorage")
			if value ~= nil then
				return value == true
			end
		end
		ancestor = ancestor.Parent
	end
	return false
end

--[[
	Relocates a single module to ReplicatedStorage.RELOCATED_MODULES if eligible, leaving a
	hierarchy-aware pointer behind. <code>container</code> is the discovery boundary the mirror is built
	relative to. <code>seen</code> (keyed on the real module) guards a module reachable via both a
	container and a tag. Returns the (possibly newly created) <code>destination</code> folder so the
	caller's lazy creation stays threaded across calls.
]]
local function tryRelocateModule(
	module: ModuleScript,
	container: Instance,
	seen: { [ModuleScript]: true },
	relocatedTemplate: Instance,
	destination: Folder?
): Folder?
	-- Pointers from previous passes (or overlapping containers) are already mirroring the real
	-- module — never try to relocate one again.
	if module:GetAttribute("_RelocatedService") ~= nil then
		return destination
	end
	-- Set seen before any early return so a second discovery (e.g. via a tag) doesn't re-warn.
	if seen[module] then
		return destination
	end
	seen[module] = true

	local directRS = module:GetAttribute("RelocateToReplicatedStorage") == true
	local directSSS = module:GetAttribute("RelocateToServerScriptService") == true
	-- Both attributes set directly on the same module is genuine user confusion;
	-- warn and skip so neither relocation runs.
	if directRS and directSSS then
		newWarn(
			`RelocateToReplicatedStorage conflicts with RelocateToServerScriptService on module '{module:GetFullName()}'; skipping relocation.`
		)
		return destination
	end
	-- An explicit RelocateToServerScriptService on a descendant opts out of any
	-- ancestor folder's RelocateToReplicatedStorage cascade. The SSS relocation
	-- in loadModule.attemptRelocate will handle it during the load pass.
	if directSSS then
		return destination
	end
	if not isMarkedForReplicatedRelocation(module, container) then
		return destination
	end
	-- A module already inside our destination is a child of a module that
	-- was relocated earlier in this same pass (children move with parents).
	-- Skip silently — relocating it would tear the parent's subtree apart.
	if REPLICATED_RELOCATED_MODULES and module:IsDescendantOf(REPLICATED_RELOCATED_MODULES) then
		return destination
	end
	if module:IsDescendantOf(ReplicatedStorage) then
		newWarn(
			`RelocateToReplicatedStorage is enabled on module '{module:GetFullName()}' that's already in ReplicatedStorage; skipping.`
		)
		return destination
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
		return destination
	end

	if not destination then
		destination = ensureReplicatedRelocatedFolder()
	end
	local originalParent = module.Parent
	local dottedPath = getDottedPathToContainer(module, container)
	-- Record the module's full original ServerScriptService path so each client can
	-- rebuild that hierarchy locally and drop a pointer at the leaf. This is what lets
	-- SSS-pointing require paths (e.g. require(game.ServerScriptService.A.B.C)) resolve
	-- on the client even though the real module now lives in ReplicatedStorage. The
	-- attribute travels with the instance into RS and replicates to clients.
	local originalSSSPath = getDottedPathFromService(module, ServerScriptService)
	if originalSSSPath then
		module:SetAttribute("_OriginalSSSPath", originalSSSPath)
	end
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
	return destination
end

--[[
	Server-only pre-pass: discovers modules the same way getModules does (each passed container,
	plus CollectionService-tagged ModuleScripts and Folders when UseCollectionService is enabled)
	and relocates the ones marked with RelocateToReplicatedStorage (directly or via folder cascade)
	to a mirrored hierarchy under ReplicatedStorage.RELOCATED_MODULES, leaving a hierarchy-aware
	pointer behind so relative requires from neighboring server modules still resolve.
]]
local function relocateToReplicatedStoragePass(containers: { Instance })
	if not RunService:IsServer() then
		return
	end

	local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")

	local destination: Folder? = nil
	local seen: { [ModuleScript]: true } = {}

	for _, container in ipairs(containers) do
		for _, module in ipairs(findAllFromClass("ModuleScript", container) :: { ModuleScript }) do
			destination = tryRelocateModule(module, container, seen, relocatedTemplate, destination)
		end
	end

	-- Mirror getModules' tag discovery so tag-only setups (Start() with no containers) relocate too.
	-- For a tagged Folder the container is the folder's PARENT, not the folder itself, so the tagged
	-- folder lands in the mirror and getOrCreateMirroredParent copies its LoaderTag onto the
	-- ReplicatedStorage mirror folder — which is how the client later discovers these modules.
	if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" then
		for _, tagged in CollectionService:GetTagged(TAG) do
			if tagged:IsA("ModuleScript") and tagged.Parent then
				destination = tryRelocateModule(tagged :: ModuleScript, tagged.Parent, seen, relocatedTemplate, destination)
			elseif tagged:IsA("Folder") and tagged.Parent then
				-- A descendant reachable via both the outer folder here and its own tag entry is
				-- relocated once (seen-set); which entry wins the mirror depth is order-dependent.
				for _, descendant in tagged:GetDescendants() do
					if descendant:IsA("ModuleScript") then
						destination = tryRelocateModule(descendant :: ModuleScript, tagged.Parent, seen, relocatedTemplate, destination)
					end
				end
			end
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
			-- A module under a RelocateToReplicatedStorage folder uses RelocateToServerScriptService
			-- as a cascade opt-out: it is meant to stay on the server, so being already in
			-- ServerScriptService is correct, not a mistake. Only warn about a genuinely redundant
			-- attribute (no relocating ancestor folder to opt out of).
			if not isOptingOutOfReplicatedRelocation(module) then
				warn(
					`RelocateToServerScriptService attribute is enabled on module '{module:GetFullName()}' that's already in ServerScriptService`
				)
			end
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

--[[
	Client-only: Reconstructs the original ServerScriptService folder hierarchy inside the client's
	OWN local ServerScriptService, placing a pointer at each leaf that resolves to the real module in
	ReplicatedStorage.RELOCATED_MODULES. This makes require paths that point at ServerScriptService
	(both instance requires like require(game.ServerScriptService.A.B.C) and string/relative requires)
	resolve identically to the server, even though the real module now lives in ReplicatedStorage.

	The real module lives exactly once (in RS); each rebuilt leaf is a stock RelocatedTemplate clone,
	so there is no duplicated module code. Discovery is unaffected: the loader still loads the real
	modules out of RELOCATED_MODULES — these pointers exist purely so SSS paths resolve at runtime.

	Must run AFTER waitForRelocationReady (so RELOCATED_MODULES is fully populated and pointer
	resolution is instant) and BEFORE the load/init/start phases (so the tree exists before any module
	code can hit an SSS require path).
]]
local function rebuildServerScriptServiceHierarchy()
	if not RunService:IsClient() then
		return
	end
	local relocated = ReplicatedStorage:FindFirstChild("RELOCATED_MODULES")
	if not relocated then
		-- Nothing was relocated this session; costs the client nothing.
		return
	end
	local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")

	for _, module in ipairs(findAllFromClass("ModuleScript", relocated) :: { ModuleScript }) do
		local originalSSSPath = module:GetAttribute("_OriginalSSSPath")
		-- Only top-level relocated modules carry _OriginalSSSPath; child/asset modules that moved
		-- with their parent don't, and are intentionally not rebuilt (accessed via the parent's
		-- return table by convention).
		if typeof(originalSSSPath) ~= "string" or originalSSSPath == "" then
			continue
		end

		local segments: { string } = string.split(originalSSSPath, ".")
		local leafName = table.remove(segments) :: string

		local parent = getOrCreateClientFolderPath(ServerScriptService, segments)
		-- Idempotent: never build a second pointer over an existing leaf.
		if parent:FindFirstChild(leafName) then
			continue
		end

		-- Path under RELOCATED_MODULES is exactly what the pointer must resolve to. Derived from the
		-- module's actual RS position so it can't drift from where the module really lives.
		local relocatedPath = getDottedPathToContainer(module, relocated)

		local pointer = relocatedTemplate:Clone()
		pointer.Name = leafName
		pointer:SetAttribute("_RelocatedService", "ReplicatedStorage")
		pointer:SetAttribute("_RelocatedPath", relocatedPath)
		pointer.Parent = parent
	end
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
		rebuildServerScriptServiceHierarchy()
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