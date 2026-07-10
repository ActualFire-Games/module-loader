--!strict
--[[
	----
	crusherfire's Module Loader
	Created: 08/05/2025
	Updated: 07/09/2026
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
		The pre-pass stamps ServerOnly onto marked modules so loader-driven clients filter
		them out before the move; direct path requires from client code can still race it.

	RelocateToReplicatedStorage (boolean)
		The inverse. Keep everything in ServerScriptService by default and expose only the
		modules clients need. A server pre-pass moves the module into
		ReplicatedStorage.RELOCATED_MODULES before any require runs, so the code is never
		briefly visible to clients.

		The folders between the container and the module are mirrored under that root, so
		relative requires like require(script.Parent.Sibling) and string requires like
		require("../Sibling") keep working when every endpoint is also relocated. A
		pointer stays at the original location so server-side requires still resolve.
		Each mirrored folder also receives a one-time snapshot of its original folder's
		attributes, so a relocated module's script.Parent:GetAttribute(...) keeps working
		(e.g. system config stored on a folder/package root).

		Client rebuild (manifest-driven since v3.0.4):
			The server writes a manifest of every relocated module to the _RelocationManifest
			attribute before setting RelocationComplete. When the loader is first required on
			a client (before Start), a bootstrap rebuilds each module's original
			ServerScriptService path locally, with a pointer at the leaf that resolves to the
			real module in ReplicatedStorage, so require(game.ServerScriptService.A.B.C)
			resolves the same on client and server. The real module exists once, in
			ReplicatedStorage. The bootstrap re-applies the manifest whenever it changes, so
			a server that calls Start() late is still recovered.

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
	RelocationComplete / _RelocationManifest
		Written by the server when the relocation pre-pass finishes (manifest first). Clients
		rebuild their local pointer tree from the manifest at require time and re-apply it on
		change. Both attributes are cleared at server require time to guard against stale
		values baked into a place file.
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
local HttpService = game:GetService("HttpService")

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

-- Client relocation state, owned by clientRelocationBootstrap (spawned at require time in MAIN).
-- start() only waits on these, so a late server Start() recovers in the background.
local relocationManifest: { any }? = nil
local relocationRebuildDone = false
local relocationRebuildSignal = Instance.new("BindableEvent")

-- Actor VMs each have their own require() cache, so parallel modules dedup on the canonical
-- instance instead of the required value.
local seenParallelTargets: { [ModuleScript]: true } = {}

export type LoaderSettings = {
	WAIT_FOR_PERSISTENT: boolean?,
	FOLDER_SEARCH_DEPTH: number?,
	YIELD_THRESHOLD: number?,
	VERBOSE_LOADING: boolean?,
	WAIT_FOR_SERVER: boolean?,
	USE_COLLECTION_SERVICE: boolean?,
}

export type KeepModulePredicate = (container: Instance, module: ModuleScript) -> (boolean)

-- One entry per relocated module, JSON-encoded into the _RelocationManifest attribute.
type RelocationManifestEntry = {
	RelocatedPath: string, -- dotted path under RELOCATED_MODULES (where the real module now lives)
	ServerScriptServicePath: string?, -- original dotted path under ServerScriptService (nil when relocated from elsewhere)
	Attributes: { [string]: any }?, -- loader-filter attributes mirrored onto rebuilt client pointers
	DescendantCount: number?, -- subtree size at relocation time (nil when zero), so clients can await the full subtree
}

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
if isServer then
	-- Attributes copied out of a running play session survive in the place file; stale relocation
	-- state would make clients skip the gate before the real pre-pass runs.
	script:SetAttribute("RelocationComplete", nil)
	script:SetAttribute("_RelocationManifest", nil)
end
-- Lazily created on the server only when the first RelocateToReplicatedStorage target is
-- encountered, so games that don't use the feature never pay for the folder (and clients see an
-- empty relocation manifest instead of an empty folder).
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
		if existing then
			-- Clients resolve RELOCATED_MODULES by name, so a same-named squatter makes every
			-- pointer walk ambiguous.
			warn(
				PRINT_IDENTIFIER,
				`'{existing:GetFullName()}' occupies the name RELOCATED_MODULES in ReplicatedStorage; relocated paths may resolve against the wrong instance. Rename or remove it.`
			)
		end
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
			continue
		end
		if existing then
			-- Requires resolve by name alone, so paths through this segment are ambiguous.
			newWarn(
				`Rebuilt ServerScriptService path segment '{name}' collides with existing non-Folder '{existing:GetFullName()}'; creating a duplicate-named sibling Folder.`
			)
		end
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = current
		current = folder
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
			if existing then
				-- Pointer paths resolve by name, so requires through this segment are ambiguous.
				newWarn(
					`Mirror folder '{original.Name}' collides with existing non-Folder '{existing:GetFullName()}' under RELOCATED_MODULES; creating a duplicate-named sibling.`
				)
			end
			local folder = Instance.new("Folder")
			folder.Name = original.Name
			folder.Parent = current
			current = folder
		end
		-- Clients cannot see the SSS original, so they discover relocated modules through the
		-- mirrored tag instead.
		if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" and CollectionService:HasTag(original, TAG) then
			if not CollectionService:HasTag(current, TAG) then
				CollectionService:AddTag(current, TAG)
			end
		end
		-- Snapshot the original folder's attributes so script.Parent:GetAttribute(...) and the
		-- cascade attributes keep working after relocation. The loader's own flags are skipped,
		-- and already-set values are kept so a mirror shared by siblings is not re-stomped.
		for name, value in original:GetAttributes() do
			if name == "RelocateToReplicatedStorage" or name == "RelocateToServerScriptService" then
				continue
			end
			if current:GetAttribute(name) == nil then
				current:SetAttribute(name, value)
			end
		end
	end
	return current
end

--[[
	Follows relocation-pointer attributes (non-yielding) to the real module. Returns the module
	itself when it isn't a pointer or when the target hasn't replicated/resolved yet.
]]
local function resolveRelocationTarget(module: ModuleScript, depth: number?): ModuleScript
	local serviceName = module:GetAttribute("_RelocatedService")
	local path = module:GetAttribute("_RelocatedPath")
	if typeof(serviceName) ~= "string" or typeof(path) ~= "string" or path == "" then
		return module
	end
	local service: Instance? = if serviceName == "ReplicatedStorage"
		then ReplicatedStorage
		elseif serviceName == "ServerScriptService" then ServerScriptService
		else nil
	if not service then
		return module
	end
	local current: Instance? = service:FindFirstChild("RELOCATED_MODULES")
	for segment in string.gmatch(path, "[^%.]+") do
		if not current then
			return module
		end
		current = current:FindFirstChild(segment)
	end
	if current and current:IsA("ModuleScript") and current ~= module then
		if (depth or 0) >= 4 then
			return current :: ModuleScript
		end
		return resolveRelocationTarget(current :: ModuleScript, (depth or 0) + 1)
	end
	return module
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
	hierarchy-aware pointer behind. <code>container</code> is the discovery boundary the mirror is
	built relative to. <code>seen</code> guards modules reachable through multiple discovery routes;
	only container-independent outcomes mark it, so a route that fails eligibility can be retried by
	a later valid one. Successful relocations append a <code>manifest</code> entry for the client
	rebuild. Returns the (possibly newly created) <code>destination</code> folder so lazy creation
	threads across calls.
]]
local function tryRelocateModule(
	module: ModuleScript,
	container: Instance,
	seen: { [ModuleScript]: true },
	relocatedTemplate: Instance,
	destination: Folder?,
	manifest: { RelocationManifestEntry }
): Folder?
	-- Pointers from previous passes are already mirroring the real module.
	if module:GetAttribute("_RelocatedService") ~= nil then
		return destination
	end
	if seen[module] then
		return destination
	end

	local directRS = module:GetAttribute("RelocateToReplicatedStorage") == true
	local directSSS = module:GetAttribute("RelocateToServerScriptService") == true
	-- Both attributes on one module is contradictory config; no discovery route can
	-- change that, so mark seen to avoid re-warning.
	if directRS and directSSS then
		seen[module] = true
		newWarn(
			`RelocateToReplicatedStorage conflicts with RelocateToServerScriptService on module '{module:GetFullName()}'; skipping relocation.`
		)
		return destination
	end
	-- RelocateToServerScriptService opts out of any ancestor folder's cascade; the move
	-- itself happens post-require in loadModule.attemptRelocate. Stamp ServerOnly now so a
	-- concurrently loading client cannot require the module before it is hidden. Explicit
	-- user values win over the stamp.
	if directSSS then
		seen[module] = true
		if module:GetAttribute("ClientOnly") == true then
			newWarn(
				`ClientOnly conflicts with RelocateToServerScriptService on module '{module:GetFullName()}'; not stamping ServerOnly.`
			)
		elseif module:GetAttribute("ServerOnly") == nil then
			module:SetAttribute("ServerOnly", true)
		end
		return destination
	end
	if not isMarkedForReplicatedRelocation(module, container) then
		return destination
	end
	-- A module already inside the destination moved there with a parent module relocated
	-- earlier in this pass; relocating it again would tear that subtree apart.
	if REPLICATED_RELOCATED_MODULES and module:IsDescendantOf(REPLICATED_RELOCATED_MODULES) then
		seen[module] = true
		return destination
	end
	if module:IsDescendantOf(ReplicatedStorage) then
		seen[module] = true
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
		-- Container-dependent failure: left unseen so a later route with a valid
		-- container can still relocate the module.
		newWarn(
			`Module '{module:GetFullName()}' is not a descendant of any provided container; skipping RelocateToReplicatedStorage.`
		)
		return destination
	end
	seen[module] = true

	if not destination then
		destination = ensureReplicatedRelocatedFolder()
	end
	local originalParent = module.Parent
	local relocatedPath = getDottedPathToContainer(module, container)
	-- The manifest is the authoritative copy of this path; the attribute stays for debugging.
	local originalSSSPath = getDottedPathFromService(module, ServerScriptService)
	if originalSSSPath then
		module:SetAttribute("_OriginalSSSPath", originalSSSPath)
	end
	local mirroredParent = getOrCreateMirroredParent(destination :: Folder, ancestors)

	if mirroredParent:FindFirstChild(module.Name) then
		-- Pointer paths resolve by name, so one of the colliding modules' pointers will
		-- return the wrong instance.
		newWarn(
			`Relocated module '{module:GetFullName()}' collides with an existing same-named child of mirror folder '{mirroredParent:GetFullName()}'; require paths may resolve to the wrong module. Rename one of the colliding instances.`
		)
	end

	local pointer = relocatedTemplate:Clone()
	pointer.Name = module.Name
	pointer:SetAttribute("_RelocatedService", "ReplicatedStorage")
	pointer:SetAttribute("_RelocatedPath", relocatedPath)
	-- Without these, the load pass would treat the pointer differently than the real module
	-- (e.g. the server would load a ClientOnly module through its unfiltered pointer).
	local mirroredAttributes: { [string]: any } = {}
	for _, attributeName in ipairs({ "ClientOnly", "ServerOnly", "IgnoreLoader", "LoaderPriority", "Parallel" }) do
		local value = module:GetAttribute(attributeName)
		if value ~= nil then
			pointer:SetAttribute(attributeName, value)
			mirroredAttributes[attributeName] = value
		end
	end

	module.Parent = mirroredParent
	pointer.Parent = originalParent
	local descendantCount = #module:GetDescendants()
	table.insert(manifest, {
		RelocatedPath = relocatedPath,
		ServerScriptServicePath = originalSSSPath,
		Attributes = if next(mirroredAttributes) ~= nil then mirroredAttributes else nil,
		DescendantCount = if descendantCount > 0 then descendantCount else nil,
	})
	return destination
end

--[[
	Server-only pre-pass: discovers modules the same way getModules does (each passed container,
	plus CollectionService-tagged ModuleScripts and Folders when UseCollectionService is enabled)
	and relocates the ones marked with RelocateToReplicatedStorage (directly or via folder cascade)
	to a mirrored hierarchy under ReplicatedStorage.RELOCATED_MODULES, leaving a hierarchy-aware
	pointer behind so relative requires from neighboring server modules still resolve.
	Returns the manifest of everything it relocated, which start() publishes to clients.
]]
local function relocateToReplicatedStoragePass(containers: { Instance }): { RelocationManifestEntry }
	local manifest: { RelocationManifestEntry } = {}
	if not RunService:IsServer() then
		return manifest
	end

	local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")

	local destination: Folder? = nil
	local seen: { [ModuleScript]: true } = {}

	for _, container in ipairs(containers) do
		-- A tagged Folder passed as a container anchors at its parent, same as tag discovery
		-- below, so the folder and its LoaderTag land in the mirror where clients can find them.
		local anchor: Instance = container
		if
			SETTINGS.USE_COLLECTION_SERVICE
			and TAG ~= ""
			and container:IsA("Folder")
			and container.Parent
			and CollectionService:HasTag(container, TAG)
		then
			anchor = container.Parent :: Instance
		end
		for _, module in ipairs(findAllFromClass("ModuleScript", container) :: { ModuleScript }) do
			destination = tryRelocateModule(module, anchor, seen, relocatedTemplate, destination, manifest)
		end
	end

	-- Mirror getModules' tag discovery so tag-only setups relocate too. GetTagged order is
	-- unspecified and varies per session, so anchoring must not depend on it: folders are
	-- processed first (outermost first), directly tagged modules last. A module covered by both
	-- routes then always keeps its folder chain in the mirror instead of rolling the dice on
	-- mirror depth every session.
	if SETTINGS.USE_COLLECTION_SERVICE and TAG ~= "" then
		local taggedFolders: { Folder } = {}
		local taggedModules: { ModuleScript } = {}
		for _, tagged in CollectionService:GetTagged(TAG) do
			if tagged:IsA("Folder") and tagged.Parent then
				table.insert(taggedFolders, tagged)
			elseif tagged:IsA("ModuleScript") and tagged.Parent then
				table.insert(taggedModules, tagged)
			end
		end
		table.sort(taggedFolders, function(a, b)
			return getDepthInHierarchy(a, game) < getDepthInHierarchy(b, game)
		end)

		for _, folder in ipairs(taggedFolders) do
			for _, descendant in folder:GetDescendants() do
				if descendant:IsA("ModuleScript") then
					destination = tryRelocateModule(descendant :: ModuleScript, folder.Parent :: Instance, seen, relocatedTemplate, destination, manifest)
				end
			end
		end
		for _, module in ipairs(taggedModules) do
			destination = tryRelocateModule(module, module.Parent :: Instance, seen, relocatedTemplate, destination, manifest)
		end
	end

	return manifest
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
			-- Already relocated by this loader (double discovery through overlapping routes).
			if module.Parent == RELOCATED_MODULES then
				return
			end
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
		if RELOCATED_MODULES:FindFirstChild(module.Name) then
			-- The destination is flat and pointers resolve by name, so one of the colliding
			-- modules' pointers will return the wrong module.
			newWarn(
				`Relocating module '{module.Name}' into ServerScriptService.RELOCATED_MODULES beside an existing same-named child; pointers may resolve to the wrong module. Rename one of the colliding modules.`
			)
		end
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
			-- A pointer and its real target can both be discovered, and Actor VMs cannot share a
			-- require() cache, so dedup on the canonical instance or the module runs twice.
			local canonical = resolveRelocationTarget(module)
			if seenParallelTargets[canonical] then
				if SETTINGS.VERBOSE_LOADING then
					newPrint(`Skipping PARALLEL module '{module.Name}' - already loaded via its relocated counterpart`)
				end
				tracker.Load[module] = true
				tracker.Init[module] = true
				tracker.Start[module] = true
				return
			end
			seenParallelTargets[canonical] = true

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
			-- Duplicate loaded values (a pointer and its real target both discovered) register
			-- once so Init/Start run once per result. Only tables dedup: primitives would collide
			-- across unrelated modules, and indexing .Init on them would error outside the xpcall.
			local isTable = type(result) == "table"
			local isDuplicate = isTable and seenResults[result] ~= nil
			if not isDuplicate then
				if isTable then
					seenResults[result] = true
					if result.Init then
						tracker.Init[module] = false
					end
					if result.Start then
						tracker.Start[module] = false
					end
				end
				tracker.Load[module] = result
			end
			executionSuccess = true
			-- Relocation runs after require to keep relative paths valid, and also for
			-- duplicates so an SSS-marked module is hidden no matter which copy loaded first.
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

	-- Non-table results (function/constant modules) are valid loads with no lifecycle.
	if type(loadedModule) ~= "table" or not loadedModule.Init then
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

	-- Non-table results (function/constant modules) are valid loads with no lifecycle.
	if type(loadedModule) ~= "table" or not loadedModule.Start then
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
	Client-only: builds the local ServerScriptService pointer tree from the server-authored
	relocation manifest so SSS require paths resolve identically on both realms. The manifest is the
	source of truth, so no replicated instances need to exist yet: each pointer resolves with its
	own WaitForChild walk at require time. Idempotent, safe to re-run whenever the manifest changes.

	Modules relocated from containers outside ServerScriptService need no rebuilt path and carry no
	ServerScriptServicePath. Child modules that moved with a relocated parent have no manifest entry
	at all (accessed through the parent's return table by convention).
]]
local function rebuildServerScriptServiceHierarchy(manifest: { any })
	if not RunService:IsClient() or #manifest == 0 then
		return
	end
	local relocatedTemplate = script:FindFirstChild("RelocatedTemplate")
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")

	local builtThisPass: { [string]: true } = {}
	for _, entry in ipairs(manifest) do
		if typeof(entry) ~= "table" or typeof(entry.RelocatedPath) ~= "string" or entry.RelocatedPath == "" then
			continue
		end
		local originalPath = entry.ServerScriptServicePath
		if typeof(originalPath) ~= "string" or originalPath == "" then
			continue
		end
		if builtThisPass[originalPath] then
			-- Two entries with one original path means two same-named siblings were relocated;
			-- first entry wins, matching the server-side collision warn.
			newWarn(
				`Duplicate relocated path 'ServerScriptService.{originalPath}' in the relocation manifest; requires of this path may resolve to the wrong module.`
			)
			continue
		end

		local segments: { string } = string.split(originalPath, ".")
		local leafName = table.remove(segments) :: string

		local parent = getOrCreateClientFolderPath(ServerScriptService, segments)
		local existing = parent:FindFirstChild(leafName)
		if existing then
			local isOwnPointer = existing:IsA("ModuleScript") and existing:GetAttribute("_RelocatedService") ~= nil
			if not isOwnPointer then
				newWarn(
					`Cannot rebuild relocated path 'ServerScriptService.{originalPath}': '{existing:GetFullName()}' already occupies that name; requires of this path may resolve to the wrong instance.`
				)
				continue
			end
			if existing:GetAttribute("_RelocatedPath") == entry.RelocatedPath then
				builtThisPass[originalPath] = true
				continue
			end
			-- Stale pointer from an outdated baked manifest. Re-clone instead of re-stamping
			-- because require() caches per instance.
			existing:Destroy()
		end

		local pointer = relocatedTemplate:Clone()
		pointer.Name = leafName
		pointer:SetAttribute("_RelocatedService", "ReplicatedStorage")
		pointer:SetAttribute("_RelocatedPath", entry.RelocatedPath)
		-- Attribute parity with server-side pointers, so a client passing a rebuilt subtree as a
		-- Start() container still filters ServerOnly modules.
		if typeof(entry.Attributes) == "table" then
			for name, value in entry.Attributes do
				pointer:SetAttribute(name, value)
			end
		end
		pointer.Parent = parent
		builtThisPass[originalPath] = true
	end
end

--[[
	Client-only, spawned at require time (not Start) so the pointer tree exists as early as
	possible. Listens for the whole session and re-applies manifest changes, which recovers a server
	that calls Start() after the client's wait cap and heals stale attributes baked into the place
	file.
]]
local function clientRelocationBootstrap()
	local lastAppliedManifest: string? = nil

	local function applyManifest(): boolean
		local raw = script:GetAttribute("_RelocationManifest")
		if typeof(raw) ~= "string" then
			return false
		end
		if raw == lastAppliedManifest then
			return true
		end
		lastAppliedManifest = raw
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not ok or typeof(decoded) ~= "table" then
			newWarn(`Failed to decode relocation manifest; relocated ServerScriptService require paths cannot be rebuilt!\n`, decoded)
			relocationManifest = {}
			return true
		end
		relocationManifest = decoded
		rebuildServerScriptServiceHierarchy(decoded)
		return true
	end

	local function tryComplete()
		if relocationRebuildDone then
			return
		end
		if not script:GetAttribute("RelocationComplete") then
			return
		end
		-- The server writes the manifest before RelocationComplete and attributes replicate
		-- atomically per instance, so a missing manifest here can only be stale baked state.
		-- Keep waiting for the real values instead of latching a wrong result; the wait cap in
		-- waitForRelocationRebuild warns if the server never arrives.
		if not applyManifest() then
			return
		end
		relocationRebuildDone = true
		relocationRebuildSignal:Fire()
	end

	script:GetAttributeChangedSignal("_RelocationManifest"):Connect(function()
		applyManifest()
		tryComplete()
	end)
	script:GetAttributeChangedSignal("RelocationComplete"):Connect(tryComplete)
	tryComplete()
end

--[[
	Client-only: yields until the bootstrap has applied the manifest, capped so a missing server
	cannot hang the client. On timeout the loader warns and proceeds; the bootstrap still rebuilds
	in the background once the server catches up.
]]
local function waitForRelocationRebuild()
	if not RunService:IsClient() or relocationRebuildDone then
		return
	end
	local WAIT_CAP = 15
	local thread = coroutine.running()
	local resumed = false
	local connection: RBXScriptConnection? = nil
	local function resume()
		if resumed then
			return
		end
		resumed = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
	connection = relocationRebuildSignal.Event:Connect(resume)
	task.delay(WAIT_CAP, function()
		if not relocationRebuildDone then
			newWarn(
				`RelocationComplete was not observed within {WAIT_CAP}s; the server has not finished (or started) its relocation pre-pass.\n`,
				`Proceeding to load; relocated require paths will be rebuilt in the background when the server catches up, but modules loading now may fail requires into ServerScriptService.`
			)
		end
		resume()
	end)
	coroutine.yield()
end

--[[
	Client-only: waits (bounded) for every manifest entry to exist under RELOCATED_MODULES so the
	discovery snapshot in getModules sees the full tree. A positive completeness check, unlike the
	old quiet-period gate that could pass on a stalled partial tree, and free once everything has
	replicated. Pointer resolution never depends on this, so on timeout the loader warns and
	proceeds.
]]
local function waitForRelocatedTree()
	if not RunService:IsClient() then
		return
	end
	local manifest = relocationManifest
	if not manifest or #manifest == 0 then
		return
	end
	local TREE_CAP = 15
	local deadline = os.clock() + TREE_CAP
	local root: Instance? = ReplicatedStorage:FindFirstChild("RELOCATED_MODULES")
	if not root then
		root = ReplicatedStorage:WaitForChild("RELOCATED_MODULES", TREE_CAP)
	end
	if not root then
		newWarn(
			`ReplicatedStorage.RELOCATED_MODULES did not replicate within {TREE_CAP}s despite a non-empty relocation manifest; relocated modules may fail to load.`
		)
		return
	end

	local missing: { string } = {}
	for _, entry in ipairs(manifest) do
		if typeof(entry) ~= "table" or typeof(entry.RelocatedPath) ~= "string" or entry.RelocatedPath == "" then
			continue
		end
		local current: Instance? = root
		for segment in string.gmatch(entry.RelocatedPath, "[^%.]+") do
			local budget = deadline - os.clock()
			if budget > 0 then
				current = (current :: Instance):WaitForChild(segment, budget)
			else
				current = (current :: Instance):FindFirstChild(segment)
			end
			if not current then
				break
			end
		end
		if not current then
			table.insert(missing, entry.RelocatedPath)
			continue
		end
		local expectedDescendants = entry.DescendantCount
		if typeof(expectedDescendants) ~= "number" or expectedDescendants <= 0 then
			continue
		end
		-- Children that moved with the module may replicate after the module itself.
		local leaf = current :: Instance
		while #leaf:GetDescendants() < expectedDescendants and os.clock() < deadline do
			task.wait(0.1)
		end
		local actualDescendants = #leaf:GetDescendants()
		if actualDescendants < expectedDescendants then
			table.insert(missing, `{entry.RelocatedPath} ({actualDescendants}/{expectedDescendants} descendants)`)
		end
	end
	if #missing > 0 then
		newWarn(
			`{#missing} relocated module(s) had not replicated within {TREE_CAP}s and may fail to load:\n`,
			table.concat(missing, "\n")
		)
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
		local manifest = relocateToReplicatedStoragePass(containers)
		-- Manifest before RelocationComplete: clients treat the flag as "manifest is readable".
		script:SetAttribute("_RelocationManifest", HttpService:JSONEncode(manifest))
		script:SetAttribute("RelocationComplete", true)
	else
		waitForRelocationRebuild()
		waitForRelocatedTree()
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
else
	-- Rebuild pointers as soon as the manifest replicates rather than when Start() happens to be
	-- called, shrinking the window where non-loader client code can hit a missing SSS path.
	task.spawn(clientRelocationBootstrap)
end

-- Unstable internal surface exposed for tests only; nil outside Studio so test hooks never run in
-- live servers. Reassigned locals (SETTINGS, keepModule, relocationManifest, TAG) go through
-- getters/setters so tests always see the live value.
local internalsForTest: { [string]: any }? = nil
if RunService:IsStudio() then
	internalsForTest = {
		-- discovery / filtering
		getModules = getModules,
		keepModule = function(container: Instance, module: ModuleScript): boolean
			return keepModule(container, module)
		end,
		findAllFromClass = findAllFromClass,
		getDepthInHierarchy = getDepthInHierarchy,
		-- relocation (server pre-pass)
		relocateToReplicatedStoragePass = relocateToReplicatedStoragePass,
		tryRelocateModule = tryRelocateModule,
		isMarkedForReplicatedRelocation = isMarkedForReplicatedRelocation,
		isOptingOutOfReplicatedRelocation = isOptingOutOfReplicatedRelocation,
		getOrCreateMirroredParent = getOrCreateMirroredParent,
		getDottedPathToContainer = getDottedPathToContainer,
		getDottedPathFromService = getDottedPathFromService,
		resolveRelocationTarget = resolveRelocationTarget,
		ensureReplicatedRelocatedFolder = ensureReplicatedRelocatedFolder,
		-- relocation (client rebuild)
		clientRelocationBootstrap = clientRelocationBootstrap,
		rebuildServerScriptServiceHierarchy = rebuildServerScriptServiceHierarchy,
		getOrCreateClientFolderPath = getOrCreateClientFolderPath,
		waitForRelocationRebuild = waitForRelocationRebuild,
		waitForRelocatedTree = waitForRelocatedTree,
		-- lifecycle
		loadModule = loadModule,
		initializeModule = initializeModule,
		startModule = startModule,
		-- utilities
		copy = copy,
		reconcile = reconcile,
		filter = filter,
		mergeArrays = mergeArrays,
		waitForEither = waitForEither,
		-- test control knobs; each returns the previous value so tests can restore it
		setLoaderTag = function(tag: string): string
			local previous = TAG
			TAG = tag
			return previous
		end,
		setUseCollectionService = function(enabled: boolean?): boolean?
			local previous = SETTINGS.USE_COLLECTION_SERVICE
			SETTINGS.USE_COLLECTION_SERVICE = enabled
			return previous
		end,
		-- live state
		getTracker = function()
			return tracker
		end,
		getSettings = function(): LoaderSettings
			return SETTINGS
		end,
		getRelocationManifest = function(): { any }?
			return relocationManifest
		end,
	}
end

return {
	Start = start,
	StartCustom = startCustom,
	ChangeSettings = changeSettings,
	IsServerLoaded = isServerLoaded,
	IsClientLoaded = isClientLoaded,
	IsPersistentLoaded = isPersistentLoaded,
	WaitForLoadedClient = waitForLoadedClient,
	GetServerLoadedTimestamp = getServerLoadedTimestamp,
	_internalsForTest = internalsForTest,
}