--!strict
--@author: crusherfire
--@date: 08/05/2025
--[[@description:
	crusherfire's Module Loader. Finds ModuleScripts, loads them in priority
	order, and runs an optional :Init() then :Start() on each. Runs on the
	server and the client. Configure it with attributes on modules, on folders
	(some cascade to their descendant modules), or on the loader script itself.

	-- LIFECYCLE --
	Every discovered module is required first, then :Init() runs on each, then
	:Start() runs on each, all in LoaderPriority order. Each call must return
	before the next one begins, so a yielding Init or Start holds up every
	module after it. A call still running after YieldThreshold seconds logs a
	warning every few seconds until it returns.
	A module that fails to require gets no Init or Start. A module whose
	:Init() errors gets no :Start(). A module found more than once (overlapping
	containers, a tag and a container, or a relocation pointer and its target)
	runs its lifecycle once.
	A method a module only inherits through its metatable is skipped when
	another loaded module defines it (e.g. a Client service inheriting its
	Shared service's Init). The defining module runs it once, with itself as
	self.

	-- MODULE ATTRIBUTES --
	Set on a ModuleScript. ClientOnly, ServerOnly, IgnoreLoader, and
	RelocateToReplicatedStorage may also be set on a Folder, which cascades
	them to every descendant ModuleScript.
	Every attribute except LoaderPriority is a boolean. A wrongly typed one
	logs a warning and counts as true, except RelocateToReplicatedStorage,
	which counts as false, so a typo never sends a module to clients.

	LoaderPriority (number, default 0)
		Higher numbers load first. Equal priorities have no fixed order. A
		value that is not a number logs a warning and counts as 0.

	ClientOnly / ServerOnly (boolean)
		Restrict a module to one run context. A value set on the module itself
		(even false) overrides a cascading folder value, and the closest folder
		wins.

	IgnoreLoader (boolean)
		Never require the module, so it gets no Init or Start. Relocation still
		applies, so the module can still reach clients for other code to
		require. Same cascade and override rules as ClientOnly.

	Parallel (boolean)
		Require the module inside its own Actor so its code can run in
		parallel.

	RelocateToServerScriptService (boolean)
		Move a server-only module into ServerScriptService after it is
		required and leave a pointer in its place. Hides server code from
		clients while keeping modules organized inside shared containers.
		Gotcha: the move happens after the require, so yielding in top-level
		code keeps the module visible to clients for longer. Avoid yielding at
		the top level.
		The pre-pass stamps ServerOnly onto marked modules so loader-driven
		clients filter them out before the move; direct path requires from
		client code can still race it.

	RelocateToReplicatedStorage (boolean)
		The inverse. Keep everything in ServerScriptService by default and
		expose only the modules clients need. A server pre-pass moves the
		module into ReplicatedStorage.RELOCATED_MODULES before any require
		runs, so the code is never briefly visible to clients.

		The folders between the container and the module are mirrored under
		that root, so relative requires like require(script.Parent.Sibling)
		and string requires like require("../Sibling") keep working when every
		endpoint is also relocated. A pointer stays at the original location
		so server-side requires still resolve. Each mirrored folder also
		receives a one-time snapshot of its original folder's attributes, so a
		relocated module's script.Parent:GetAttribute(...) keeps working (e.g.
		system config stored on a folder or package root).

		Client rebuild:
			The server writes a manifest of every relocated module to the
			_RelocationManifest attribute before setting RelocationComplete.
			When the loader is first required on a client (before Start), a
			bootstrap rebuilds each module's original ServerScriptService path
			locally, with a pointer at the leaf that resolves to the real
			module in ReplicatedStorage, so require(game.ServerScriptService.A)
			resolves the same on client and server. The real module exists
			once, in ReplicatedStorage. The bootstrap re-applies the manifest
			whenever it changes, so a server that calls Start() late is still
			recovered.

		Client repair:
			A relocated folder can fail to reach a joining client and never
			arrive on its own. Right before discovery, a client that is still
			missing relocated paths a few seconds into its check reports them
			through RelocationRepairEvent, and the server detaches and
			re-attaches each one so it replicates again. Clients that already
			have it keep the same instance. The server takes one request of a
			few paths per player, only before that player has loaded, acts
			only on paths its own manifest produced that are small enough, and
			resends one instance at a time, after its own load, at most once
			per cooldown and a capped number of times per minute across all
			players.
			Discovery runs straight after a final check that does not yield,
			so a resend for another player cannot drop modules from a loading
			client's discovery. During the short detach, though, a relative
			require that crosses the resent folder's boundary
			(script.Parent.Parent.X, "../X") fails on every realm; pointers
			wait it out. A client that does not wait for the server can finish
			its check before a resend arrives, because resends wait for the
			server's own load.

		Cascade: set on a Folder to relocate the whole subtree (folders
		discovered by a container OR by LoaderTag).
			A module's own value wins over an ancestor folder, closest folder
			wins among nested folders. RelocateToReplicatedStorage = false on
			a module opts it out of an ancestor's cascade while staying
			loadable on the server. RelocateToServerScriptService = true opts
			out and hides it on the server instead. Only modules whose
			ancestry up to the folder is made of Folders are relocated.

		Gotchas:
			Descendants of a relocated module (assets, child modules) move
			with it. Expose them through the module's return table instead of
			indexing for them directly.

			An opted-out, server-only sibling cannot be reached by a relative
			require on the client, since it stays in ServerScriptService.
			Cross realms through the loader, an absolute path, or a remote.

			Setting both Relocate attributes on one module warns and skips it.
			A module already in ReplicatedStorage also warns and is skipped.

	-- COLLECTION SERVICE --
	Enable UseCollectionService and tag ModuleScripts or Folders with
	LoaderTag to load modules that live outside the containers you pass in.
	Tagging a Folder loads every descendant ModuleScript, subject to the
	filtering attributes above. Tags on a relocated folder are mirrored into
	ReplicatedStorage so clients find the modules by the same tag.

	-- LOADER SETTINGS --
	Set as attributes on the ModuleLoader script. ChangeSettings() overrides
	them at runtime. A setting attribute of the wrong type logs a warning and
	is ignored.

	YieldThreshold (number, default 10)
		Seconds a module may run before a slow-load warning logs.
	VerboseLoading (boolean, default true)
		Log each step of the loading process, and how long each phase took.
	UseCollectionService (boolean)
		Discover modules to load by LoaderTag.
	LoaderTag (string, default LOAD_MODULE)
		The tag used for CollectionService discovery.
	ClientWaitForServer (boolean)
		Client waits for the server to finish loading before it starts.
	ClientWaitForPersistentLoaded (boolean)
		Client waits for persistent models to stream into workspace first.

	-- DEFAULT FILTERING --
	Start() loads every module whose path back to its container or tagged
	folder is all folders, at any depth, and it respects ClientOnly,
	ServerOnly, and IgnoreLoader. A module nested under another module belongs
	to that module and is never loaded or relocated on its own. Pass your own
	predicate to StartCustom() to replace this behavior.

	-- EDIT MODE --
	Outside a running game (the command bar, plugins, specs, UI Labs stories),
	requiring the loader creates nothing in the place, connects nothing, and
	never waits, so modules that require it can load there.

	-- LOADER STATE (attributes on this script) --
	RelocationComplete / _RelocationManifest
		Written by the server when the relocation pre-pass finishes (manifest
		first). Clients rebuild their local pointer tree from the manifest at
		require time and re-apply it on change. Both attributes are cleared at
		server require time to guard against stale values baked into a place
		file.
	ServerLoaded / ServerLoadedTimestamp
		Read them through IsServerLoaded() and GetServerLoadedTimestamp().
]]

-----------------------------
-- SERVICES --
-----------------------------
const CollectionService = game:GetService("CollectionService")
const HttpService = game:GetService("HttpService")
const Players = game:GetService("Players")
const ReplicatedFirst = game:GetService("ReplicatedFirst")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")

-----------------------------
-- TYPES --
-----------------------------
export type LoaderSettings = {
	WAIT_FOR_PERSISTENT: boolean?,
	YIELD_THRESHOLD: number?,
	VERBOSE_LOADING: boolean?,
	WAIT_FOR_SERVER: boolean?,
	USE_COLLECTION_SERVICE: boolean?,
}

export type KeepModulePredicate = (container: Instance, module: ModuleScript) -> boolean

-- One entry per relocated module, JSON-encoded into the _RelocationManifest
-- attribute.
type RelocationManifestEntry = {
	-- Dotted path under RELOCATED_MODULES, where the real module now lives.
	RelocatedPath: string,
	-- Original dotted path under ServerScriptService, nil when relocated from
	-- elsewhere.
	ServerScriptServicePath: string?,
	-- Loader-filter attributes mirrored onto rebuilt client pointers.
	Attributes: { [string]: any }?,
	-- Subtree size at relocation time (nil when zero), so clients can await
	-- the full subtree.
	DescendantCount: number?,
}

type PendingResend = {
	Player: Player,
	Path: string,
}

type LifecycleMethodName = "Init" | "Start"

type LifecycleStep = {
	-- Names the call in the slow-call warning, e.g. "Loading Module 'Foo'".
	Description: string,
	MemoryCategory: string,
	Run: () -> (),
	-- Called once if Run yields instead of returning straight away.
	OnYield: (() -> ())?,
}

type LifecycleLogWords = {
	Running: string,
	Finished: string,
	Verb: string,
}

-----------------------------
-- VARIABLES --
-----------------------------
local Module = {}

const DEFAULT_LOADER_TAG = "LOAD_MODULE"
const DEFAULT_YIELD_THRESHOLD = 10
const DEFAULT_VERBOSE_LOADING = true
-- Keep in sync with RelocatedTemplate, which finds the folder by this name.
const RELOCATED_FOLDER_NAME = "RELOCATED_MODULES"
const SLOW_CALL_WARNING_INTERVAL = 5
const REPLICATION_POLL_INTERVAL = 0.1
-- A pointer can point at another pointer; resolution stops after this many
-- hops.
const MAX_POINTER_HOPS = 4
-- Seconds a client waits for the server's relocation manifest, then for the
-- relocated modules themselves, before it loads anyway.
const RELOCATION_MANIFEST_WAIT_CAP = 15
const RELOCATED_TREE_WAIT_CAP = 15
const PRINT_IDENTIFIER = if RunService:IsClient() then "[C]" else "[S]"
const LOADED_IDENTIFIER = if RunService:IsClient() then "Client" else "Server"
const LIFECYCLE_METHODS: { LifecycleMethodName } = { "Init", "Start" }
const LIFECYCLE_LOG_WORDS: { [LifecycleMethodName]: LifecycleLogWords } = {
	Init = {
		Running = "Initializing",
		Finished = "Initialized",
		Verb = "init",
	},
	Start = {
		Running = "Starting",
		Finished = "Started",
		Verb = "start",
	},
}
-- Copied from a relocated module onto its pointers. Without them, the load
-- pass would treat a pointer differently than its module (the server would
-- load a ClientOnly module through its unfiltered pointer).
const POINTER_ATTRIBUTES = {
	"ClientOnly",
	"ServerOnly",
	"IgnoreLoader",
	"LoaderPriority",
	"Parallel",
}
-- What a loader flag holding a non-boolean counts as. A stray "true" string
-- must keep a module on the server, never send it to clients.
const MISTYPED_FLAG_VALUES: { [string]: boolean } = {
	ClientOnly = true,
	IgnoreLoader = true,
	Parallel = true,
	RelocateToReplicatedStorage = false,
	RelocateToServerScriptService = true,
	ServerOnly = true,
}
-- Seconds a client waits for relocated modules before asking the server to
-- resend the missing ones. The rest of the client's wait cap is left for the
-- resend to arrive.
const RELOCATION_REPAIR_DELAY = 5
-- Limits on what one client can make the server resend. A resend briefly
-- detaches an instance for every player, so a client must not be able to
-- trigger it at will. The loader itself sends at most one request per
-- session.
const RELOCATION_REPAIR_MAX_REQUESTS = 1
const RELOCATION_REPAIR_MAX_PATHS = 10
const RELOCATION_REPAIR_MAX_DESCENDANTS = 1000
const RELOCATION_REPAIR_COOLDOWN = 10
const RELOCATION_REPAIR_MAX_RESENDS_PER_WINDOW = 20
const RELOCATION_REPAIR_RATE_WINDOW = 60
-- Long enough that the detach and the re-attach replicate as two changes
-- instead of canceling out within one network send.
const RELOCATION_REPAIR_DETACH_TIME = 0.25

local isClient = RunService:IsClient()
local isServer = RunService:IsServer()
local isRunning = RunService:IsRunning()
-- A local alias keeps the type checker from trying to resolve requires of
-- modules found at runtime.
local require = require

local parallelModuleLoader = script.ParallelModuleLoader
local relocatedTemplate: ModuleScript? = script:FindFirstChild("RelocatedTemplate") :: any
local actorForServer: Actor? = script:FindFirstChild("ActorForServer") :: any
local actorForClient: Actor? = script:FindFirstChild("ActorForClient") :: any
local loadedEvent: RemoteEvent
local relocationRepairEvent: RemoteEvent

local settings: LoaderSettings = {}
local loaderTag = DEFAULT_LOADER_TAG
local customKeepModule: KeepModulePredicate? = nil
local started = false

local tracker = {
	Load = {} :: { [ModuleScript]: any },
	Init = {} :: { [ModuleScript]: boolean },
	Start = {} :: { [ModuleScript]: boolean },
}
local actorsByModule: { [ModuleScript]: Actor } = {}

-- Indexed by the table that a successful require() returned. Lets the loader
-- skip duplicate Init/Start when two ModuleScripts resolve to the same value
-- (most notably a relocation pointer and its real target both being
-- discovered).
local seenResults: { [any]: true } = {}

-- Init/Start functions defined directly on a loaded table, not reached
-- through a metatable.
local ownedLifecycleMethods: { [any]: true } = {}

-- Actor VMs each have their own require() cache, so parallel modules dedup on
-- the canonical instance instead of the required value.
local seenParallelTargets: { [ModuleScript]: true } = {}

-- Keyed by "<instance path>.<attribute>", so each mistyped attribute warns
-- once.
local warnedMistypedAttributes: { [string]: true } = {}

-- Created on first use, so games that never relocate get no folders.
local replicatedRelocatedFolder: Folder? = nil
local serverRelocatedFolder: Folder? = nil

-- Client relocation state, owned by clientRelocationBootstrap (spawned at
-- require time in MAIN). Start only waits on these, so a late server Start()
-- recovers in the background.
local relocationManifest: { RelocationManifestEntry }? = nil
local relocationRebuildDone = false
local relocationRebuildSignal = Instance.new("BindableEvent")

-- Server relocation-repair state. resendablePaths holds every dotted path the
-- pre-pass produced (each relocated module and each mirrored folder above
-- it), true when the subtree is small enough to resend. Resends run one at a
-- time from pendingResends.
local resendablePaths: { [string]: boolean } = {}
local repairRequestsByPlayer: { [Player]: number } = {}
local lastResendTimes: { [Instance]: number } = {}
local pendingResends: { PendingResend } = {}
local recentResendTimes: { number } = {}
local isResendWorkerRunning = false

-----------------------------
-- PRIVATE FUNCTIONS --
-----------------------------

local function newPrint(...: any)
	print(PRINT_IDENTIFIER, ...)
end

local function newWarn(...: any)
	warn(PRINT_IDENTIFIER, ...)
end

local function formatSeconds(seconds: number): string
	return string.format("%.3f", seconds)
end

--[[
	Reads a boolean loader attribute. A value of any other type warns once and
	counts as its MISTYPED_FLAG_VALUES entry, so a typo can never ship server
	code to clients.
]]
local function readFlag(instance: Instance, attributeName: string): boolean?
	local value = instance:GetAttribute(attributeName)
	if value == nil or typeof(value) == "boolean" then
		return value :: boolean?
	end

	local fallback = MISTYPED_FLAG_VALUES[attributeName]
	local warningKey = `{instance:GetFullName()}.{attributeName}`
	if not warnedMistypedAttributes[warningKey] then
		warnedMistypedAttributes[warningKey] = true
		newWarn(
			`Loader attribute {attributeName} on '{instance:GetFullName()}' is a {typeof(value)},`,
			`not a boolean; treating it as {fallback}.`
		)
	end
	return fallback
end

--[[
	Reads one loader setting attribute. A value of the wrong type warns and
	counts as unset.
]]
local function readSettingAttribute(attributeName: string, expectedType: string): any
	local value = script:GetAttribute(attributeName)
	if value == nil or typeof(value) == expectedType then
		return value
	end

	newWarn(
		`ModuleLoader setting {attributeName} is a {typeof(value)}, not a {expectedType};`,
		"ignoring it."
	)
	return nil
end

--[[
	Reads a module's LoaderPriority. A value that is not a number would break
	the load-order sort and stop every module from loading, so it warns and
	counts as 0 instead.
]]
local function getLoaderPriority(module: ModuleScript): number
	local priority = module:GetAttribute("LoaderPriority")
	if priority == nil then
		return 0
	end
	-- NaN fails every comparison, which breaks the sort just the same.
	if typeof(priority) ~= "number" or priority ~= priority then
		newWarn(`LoaderPriority on '{module:GetFullName()}' is not a number; treating it as 0.`)
		return 0
	end
	return priority
end

--[[
	Returns one of the loader's remotes: made by the server, awaited by
	clients. Outside a running game it stays unparented, so requiring the
	loader there leaves nothing in the place and waits on nothing.
]]
local function getLoaderRemoteAsync(name: string): RemoteEvent
	if isRunning and isClient then
		return script:WaitForChild(name) :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	if isRunning then
		remote.Parent = script
	end
	return remote
end

local function waitForAttributeAsync(instance: Instance, attributeName: string)
	while not instance:GetAttribute(attributeName) do
		instance:GetAttributeChangedSignal(attributeName):Wait()
	end
end

--[[
	Yields until either signal fires. Returns true when <code>eventYes</code>
	fired first, followed by that signal's arguments.
]]
local function waitForEither(eventYes: RBXScriptSignal, eventNo: RBXScriptSignal): boolean
	local thread = coroutine.running()
	local yesConnection: RBXScriptConnection? = nil
	local noConnection: RBXScriptConnection? = nil

	local function finish(result: boolean, ...: any)
		if not yesConnection or not noConnection then
			return
		end
		yesConnection:Disconnect()
		noConnection:Disconnect()
		yesConnection = nil
		noConnection = nil

		if coroutine.status(thread) == "suspended" then
			task.spawn(thread, result, ...)
		end
	end

	yesConnection = eventYes:Once(function(...)
		finish(true, ...)
	end)
	noConnection = eventNo:Once(function(...)
		finish(false, ...)
	end)
	return coroutine.yield()
end

--[[
	Returns the 'depth' of <code>descendant</code> in the child hierarchy of
	<code>root</code>, or 0 if the descendant is not found in <code>root</code>.
]]
local function getDepthInHierarchy(descendant: Instance, root: Instance): number
	local depth = 0
	local current: Instance? = descendant
	while current and current ~= root do
		current = current.Parent
		depth += 1
	end
	if not current then
		return 0
	end
	return depth
end

local function findAllFromClass(className: string, searchIn: Instance): { any }
	local foundObjects = {}
	for _, descendant in searchIn:GetDescendants() do
		if descendant:IsA(className) then
			table.insert(foundObjects, descendant)
		end
	end
	return foundObjects
end

--[[
	The default filter. Keeps a module whose path back to
	<code>container</code> is all Folders, unless ClientOnly, ServerOnly, or
	IgnoreLoader rule it out on this realm. A value set on the module itself
	(even false) wins over the cascade, and the closest Folder wins within it.
]]
local function keepModule(container: Instance, module: ModuleScript): boolean
	local clientOnly = readFlag(module, "ClientOnly")
	local serverOnly = readFlag(module, "ServerOnly")
	local ignore = readFlag(module, "IgnoreLoader")

	local ancestor: Instance? = module.Parent
	local foundContainer = false
	while ancestor do
		if ancestor:IsA("Folder") then
			if clientOnly == nil then
				clientOnly = readFlag(ancestor, "ClientOnly")
			end
			if serverOnly == nil then
				serverOnly = readFlag(ancestor, "ServerOnly")
			end
			if ignore == nil then
				ignore = readFlag(ancestor, "IgnoreLoader")
			end
		end
		if ancestor == container then
			foundContainer = true
			break
		end
		if not ancestor:IsA("Folder") then
			return false
		end
		ancestor = ancestor.Parent
	end
	if not foundContainer then
		return false
	end

	if clientOnly and isServer then
		return false
	end
	if serverOnly and isClient then
		return false
	end
	return not ignore
end

--[[
	Returns the dot-separated path from <code>module</code> up to (but
	excluding) <code>container</code>.
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
	Returns the dot-separated path from <code>service</code> (exclusive) down
	to <code>instance</code> (inclusive), e.g. "Gameplay.Combat.DamageMath", or
	<code>nil</code> if <code>instance</code> is not a descendant of
	<code>service</code>. Unlike getDottedPathToContainer this anchors to a
	service, so the client can rebuild the full original hierarchy under its
	own local ServerScriptService.
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
	Client only: finds or creates a plain Folder for each segment under
	<code>root</code>, mirroring an original ServerScriptService folder chain.
	Returns the deepest folder (or <code>root</code> itself if
	<code>segments</code> is empty). These folders only hold relocated-module
	pointers, so no tags or attributes are mirrored onto them.
]]
local function getOrCreateClientFolderPath(root: Instance, segments: { string }): Instance
	local current: Instance = root
	for _, name in segments do
		local existing = current:FindFirstChild(name)
		if existing and existing:IsA("Folder") then
			current = existing
			continue
		end
		if existing then
			-- Requires resolve by name alone, so paths through this segment are
			-- ambiguous.
			newWarn(
				`Rebuilt ServerScriptService path segment '{name}' collides with existing`,
				`non-Folder '{existing:GetFullName()}'; creating a duplicate-named sibling Folder.`
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
	Given the ordered list of original ancestor folders (outermost to
	innermost, excluding both the container and the module itself), creates or
	reuses Folder instances under <code>rootFolder</code> to mirror the chain.
	Returns the deepest mirrored folder (or <code>rootFolder</code> itself if
	<code>ancestors</code> is empty).
]]
local function getOrCreateMirroredParent(rootFolder: Folder, ancestors: { Instance }): Folder
	local current: Folder = rootFolder
	for _, original in ancestors do
		local existing = current:FindFirstChild(original.Name)
		if existing and existing:IsA("Folder") then
			current = existing :: Folder
		else
			if existing then
				-- Pointer paths resolve by name, so requires through this
				-- segment are ambiguous.
				newWarn(
					`Mirror folder '{original.Name}' collides with existing non-Folder`,
					`'{existing:GetFullName()}' under RELOCATED_MODULES;`,
					"creating a duplicate-named sibling."
				)
			end
			local folder = Instance.new("Folder")
			folder.Name = original.Name
			folder.Parent = current
			current = folder
		end
		-- Clients cannot see the ServerScriptService original, so they discover
		-- relocated modules through the mirrored tag instead.
		if
			settings.USE_COLLECTION_SERVICE
			and loaderTag ~= ""
			and CollectionService:HasTag(original, loaderTag)
			and not CollectionService:HasTag(current, loaderTag)
		then
			CollectionService:AddTag(current, loaderTag)
		end
		-- Snapshot the original folder's attributes so
		-- script.Parent:GetAttribute(...) and the cascade attributes keep
		-- working after relocation. The loader's own flags are skipped, and
		-- values already set are kept so a mirror shared by siblings is not
		-- re-stomped.
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
	Follows relocation-pointer attributes (without yielding) to the real
	module. Returns the module itself when it isn't a pointer or when the
	target hasn't replicated or resolved yet.
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

	local current: Instance? = service:FindFirstChild(RELOCATED_FOLDER_NAME)
	for segment in string.gmatch(path, "[^%.]+") do
		if not current then
			return module
		end
		current = current:FindFirstChild(segment)
	end
	if not current or not current:IsA("ModuleScript") or current == module then
		return module
	end
	local hops = depth or 0
	if hops >= MAX_POINTER_HOPS then
		return current :: ModuleScript
	end
	return resolveRelocationTarget(current :: ModuleScript, hops + 1)
end

--[[
	Returns true if <code>module</code> should be relocated to
	ReplicatedStorage. Mirrors keepModule's cascade precedence: the module's
	own RelocateToReplicatedStorage value (including an explicit
	<code>false</code>) wins, then the closest Folder ancestor up to and
	including <code>container</code>. The ancestry up to
	<code>container</code> must be made of Folders only: a module nested under
	a non-folder (e.g. a child of another module) is not an independent
	relocation target; it moves with its parent. Returns false if
	<code>container</code> is never reached.
]]
local function isMarkedForReplicatedRelocation(module: ModuleScript, container: Instance): boolean
	local effective = readFlag(module, "RelocateToReplicatedStorage")
	local ancestor: Instance? = module.Parent
	local foundContainer = false
	while ancestor do
		if ancestor:IsA("Folder") and effective == nil then
			effective = readFlag(ancestor, "RelocateToReplicatedStorage")
		end
		if ancestor == container then
			-- Read the container's own value (above) before stopping; never
			-- walk past it.
			foundContainer = true
			break
		end
		if not ancestor:IsA("Folder") then
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
	Returns true if <code>module</code> sits under a Folder marked
	RelocateToReplicatedStorage, in which case a RelocateToServerScriptService
	attribute on it is a cascade opt-out (keeping the module on the server on
	purpose) rather than a redundant request to move a module that is already
	on the server. The closest Folder ancestor with the attribute set wins,
	matching the cascade precedence used elsewhere.
]]
local function isOptingOutOfReplicatedRelocation(module: Instance): boolean
	local ancestor: Instance? = module.Parent
	while ancestor do
		if ancestor:IsA("Folder") then
			local value = readFlag(ancestor, "RelocateToReplicatedStorage")
			if value ~= nil then
				return value
			end
		end
		ancestor = ancestor.Parent
	end
	return false
end

local function findOrCreateRelocatedFolder(service: Instance): Folder
	local existing = service:FindFirstChild(RELOCATED_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing :: Folder
	end
	if existing then
		-- Pointers resolve RELOCATED_MODULES by name, so a same-named squatter
		-- makes every pointer walk ambiguous.
		newWarn(
			`'{existing:GetFullName()}' occupies the name RELOCATED_MODULES in {service.Name};`,
			"relocated paths may resolve against the wrong instance. Rename or remove it."
		)
	end

	local folder = Instance.new("Folder")
	folder.Name = RELOCATED_FOLDER_NAME
	folder.Parent = service
	return folder
end

--[[
	Returns ReplicatedStorage.RELOCATED_MODULES, creating it when the first
	module relocates there, so clients of a game that never relocates see an
	empty manifest instead of an empty folder.
]]
local function ensureReplicatedRelocatedFolder(): Folder
	local folder = replicatedRelocatedFolder or findOrCreateRelocatedFolder(ReplicatedStorage)
	replicatedRelocatedFolder = folder
	return folder
end

local function ensureServerRelocatedFolder(): Folder
	local folder = serverRelocatedFolder or findOrCreateRelocatedFolder(ServerScriptService)
	serverRelocatedFolder = folder
	return folder
end

local function getRelocatedTemplate(): ModuleScript
	assert(relocatedTemplate, "ModuleLoader missing RelocatedTemplate child")
	return relocatedTemplate
end

local function createPointer(
	template: Instance,
	name: string,
	serviceName: string,
	relocatedPath: string
): Instance
	local pointer = template:Clone()
	pointer.Name = name
	pointer:SetAttribute("_RelocatedService", serviceName)
	pointer:SetAttribute("_RelocatedPath", relocatedPath)
	return pointer
end

--[[
	Reads an attribute to copy from a module onto its pointers, already
	interpreted the way the loader reads it, so a mistyped value warns once
	for the module instead of again for every pointer.
]]
local function readPointerAttribute(module: ModuleScript, attributeName: string): any
	if attributeName ~= "LoaderPriority" then
		return readFlag(module, attributeName)
	end
	local priority = module:GetAttribute(attributeName)
	return if typeof(priority) == "number" then priority else nil
end

--[[
	Relocates a single module to ReplicatedStorage.RELOCATED_MODULES if
	eligible, leaving a hierarchy-aware pointer behind. <code>container</code>
	is the discovery boundary the mirror is built relative to.
	<code>seen</code> guards modules reachable through multiple discovery
	routes; only container-independent outcomes mark it, so a route that fails
	eligibility can be retried by a later valid one. Successful relocations
	append a <code>manifest</code> entry for the client rebuild. Returns the
	(possibly newly created) <code>destination</code> folder so lazy creation
	threads across calls.
]]
local function tryRelocateModule(
	module: ModuleScript,
	container: Instance,
	seen: { [ModuleScript]: true },
	template: Instance,
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

	local wantsReplicatedStorage = readFlag(module, "RelocateToReplicatedStorage") == true
	local wantsServerScriptService = readFlag(module, "RelocateToServerScriptService") == true
	-- Both attributes on one module is contradictory config; no discovery route
	-- can change that, so mark seen to avoid re-warning.
	if wantsReplicatedStorage and wantsServerScriptService then
		seen[module] = true
		newWarn(
			"RelocateToReplicatedStorage conflicts with RelocateToServerScriptService on module",
			`'{module:GetFullName()}'; skipping relocation.`
		)
		return destination
	end
	-- RelocateToServerScriptService opts out of any ancestor folder's cascade;
	-- the move itself happens after the require, in
	-- relocateToServerScriptService. Stamp ServerOnly now so a client loading
	-- at the same time cannot require the module before it is hidden. Values
	-- the user set win over the stamp.
	if wantsServerScriptService then
		seen[module] = true
		if readFlag(module, "ClientOnly") == true then
			newWarn(
				"ClientOnly conflicts with RelocateToServerScriptService on module",
				`'{module:GetFullName()}'; not stamping ServerOnly.`
			)
		elseif module:GetAttribute("ServerOnly") == nil then
			module:SetAttribute("ServerOnly", true)
		end
		return destination
	end
	if not isMarkedForReplicatedRelocation(module, container) then
		return destination
	end
	-- A module already inside the destination moved there with a parent module
	-- relocated earlier in this pass; relocating it again would tear that
	-- subtree apart.
	if replicatedRelocatedFolder and module:IsDescendantOf(replicatedRelocatedFolder) then
		seen[module] = true
		return destination
	end
	if module:IsDescendantOf(ReplicatedStorage) then
		seen[module] = true
		newWarn(
			`RelocateToReplicatedStorage is enabled on module '{module:GetFullName()}'`,
			"that's already in ReplicatedStorage; skipping."
		)
		return destination
	end

	-- Ancestor folders between the container (exclusive) and the module's
	-- parent (inclusive).
	local ancestors: { Instance } = {}
	local cursor: Instance? = module.Parent
	while cursor and cursor ~= container do
		table.insert(ancestors, 1, cursor)
		cursor = cursor.Parent
	end
	if cursor ~= container then
		-- Container-dependent failure: left unseen so a later route with a
		-- valid container can still relocate the module.
		newWarn(
			`Module '{module:GetFullName()}' is not a descendant of any provided container;`,
			"skipping RelocateToReplicatedStorage."
		)
		return destination
	end
	seen[module] = true

	local relocationRoot = destination or ensureReplicatedRelocatedFolder()
	local originalParent = module.Parent
	local relocatedPath = getDottedPathToContainer(module, container)
	-- The manifest is the authoritative copy of this path; the attribute stays
	-- for debugging.
	local originalServerPath = getDottedPathFromService(module, ServerScriptService)
	if originalServerPath then
		module:SetAttribute("_OriginalSSSPath", originalServerPath)
	end
	local mirroredParent = getOrCreateMirroredParent(relocationRoot, ancestors)

	if mirroredParent:FindFirstChild(module.Name) then
		-- Pointer paths resolve by name, so one of the colliding modules'
		-- pointers will return the wrong instance.
		newWarn(
			`Relocated module '{module:GetFullName()}' collides with an existing same-named child`,
			`of mirror folder '{mirroredParent:GetFullName()}'; require paths may resolve to the`,
			"wrong module. Rename one of the colliding instances."
		)
	end

	local pointer = createPointer(template, module.Name, "ReplicatedStorage", relocatedPath)
	local mirroredAttributes: { [string]: any } = {}
	for _, attributeName in POINTER_ATTRIBUTES do
		local value = readPointerAttribute(module, attributeName)
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
		ServerScriptServicePath = originalServerPath,
		Attributes = if next(mirroredAttributes) ~= nil then mirroredAttributes else nil,
		DescendantCount = if descendantCount > 0 then descendantCount else nil,
	})
	return relocationRoot
end

--[[
	Server-only pre-pass: discovers modules the same way getModules does (each
	passed container, plus CollectionService-tagged ModuleScripts and Folders
	when UseCollectionService is enabled) and relocates the ones marked with
	RelocateToReplicatedStorage (directly or via folder cascade) to a mirrored
	hierarchy under ReplicatedStorage.RELOCATED_MODULES, leaving a
	hierarchy-aware pointer behind so relative requires from neighboring server
	modules still resolve. Returns the manifest of everything it relocated,
	which Start publishes to clients.
]]
local function relocateToReplicatedStoragePass(
	containers: { Instance }
): { RelocationManifestEntry }
	local manifest: { RelocationManifestEntry } = {}
	if not isServer then
		return manifest
	end

	local template = getRelocatedTemplate()
	local destination: Folder? = nil
	local seen: { [ModuleScript]: true } = {}

	for _, container in containers do
		-- A tagged Folder passed as a container anchors at its parent, same as
		-- tag discovery below, so the folder and its LoaderTag land in the
		-- mirror where clients can find them.
		local anchor: Instance = container
		if
			settings.USE_COLLECTION_SERVICE
			and loaderTag ~= ""
			and container:IsA("Folder")
			and container.Parent
			and CollectionService:HasTag(container, loaderTag)
		then
			anchor = container.Parent :: Instance
		end
		for _, module in findAllFromClass("ModuleScript", container) do
			destination = tryRelocateModule(module, anchor, seen, template, destination, manifest)
		end
	end

	if not settings.USE_COLLECTION_SERVICE or loaderTag == "" then
		return manifest
	end
	-- Mirror getModules' tag discovery so tag-only setups relocate too.
	-- GetTagged order is unspecified and varies per session, so anchoring must
	-- not depend on it: folders are processed first (outermost first),
	-- directly tagged modules last. A module covered by both routes then
	-- always keeps its folder chain in the mirror instead of rolling the dice
	-- on mirror depth every session.
	local taggedFolders: { Folder } = {}
	local taggedModules: { ModuleScript } = {}
	for _, tagged in CollectionService:GetTagged(loaderTag) do
		if tagged:IsA("Folder") and tagged.Parent then
			table.insert(taggedFolders, tagged)
		elseif tagged:IsA("ModuleScript") and tagged.Parent then
			table.insert(taggedModules, tagged)
		end
	end
	table.sort(taggedFolders, function(a, b)
		return getDepthInHierarchy(a, game) < getDepthInHierarchy(b, game)
	end)

	for _, folder in taggedFolders do
		local anchor = folder.Parent :: Instance
		for _, descendant in folder:GetDescendants() do
			if not descendant:IsA("ModuleScript") then
				continue
			end
			local module = descendant :: ModuleScript
			destination = tryRelocateModule(module, anchor, seen, template, destination, manifest)
		end
	end
	for _, module in taggedModules do
		local anchor = module.Parent :: Instance
		destination = tryRelocateModule(module, anchor, seen, template, destination, manifest)
	end
	return manifest
end

--[[
	Moves a RelocateToServerScriptService module into
	ServerScriptService.RELOCATED_MODULES and leaves a server-only pointer in
	its place. Runs after the module's require, so relative requires inside it
	resolve from its original spot.
]]
local function relocateToServerScriptService(module: ModuleScript)
	if isClient then
		return
	end
	if not readFlag(module, "RelocateToServerScriptService") then
		return
	end
	if module:IsDescendantOf(ServerScriptService) then
		-- Already moved by this loader (found through overlapping routes).
		if serverRelocatedFolder and module.Parent == serverRelocatedFolder then
			return
		end
		-- Under a RelocateToReplicatedStorage folder the attribute is a cascade
		-- opt-out, so already being in ServerScriptService is correct. Only an
		-- attribute with no relocating folder above it is redundant.
		if not isOptingOutOfReplicatedRelocation(module) then
			newWarn(
				"RelocateToServerScriptService attribute is enabled on module",
				`'{module:GetFullName()}' that's already in ServerScriptService`
			)
		end
		return
	end

	local template = getRelocatedTemplate()
	local destination = ensureServerRelocatedFolder()
	if destination:FindFirstChild(module.Name) then
		-- The destination is flat and pointers resolve by name, so one of the
		-- colliding modules' pointers will return the wrong module.
		newWarn(
			`Relocating module '{module.Name}' into ServerScriptService.RELOCATED_MODULES`,
			"beside an existing same-named child; pointers may resolve to the wrong module.",
			"Rename one of the colliding modules."
		)
	end
	local pointer = createPointer(template, module.Name, "ServerScriptService", module.Name)
	pointer:SetAttribute("ServerOnly", true)
	pointer.Parent = module.Parent
	module.Parent = destination
end

--[[
	Runs one load, Init, or Start call in its own thread and waits for it to
	finish, warning while it runs past the yield threshold. Returns whether it
	succeeded, its error with a traceback, and the seconds it took.
]]
local function runLifecycleStepAsync(step: LifecycleStep): (boolean, string, number)
	local callerThread = coroutine.running()
	local startTime = os.clock()
	local succeeded = false
	local failure = ""
	local isFinished = false

	task.spawn(function()
		debug.setmemorycategory(step.MemoryCategory)
		local ok, result = xpcall(function()
			step.Run()
		end, debug.traceback)
		debug.resetmemorycategory()
		succeeded = ok
		if not ok then
			failure = tostring(result)
		end
		isFinished = true
		if coroutine.status(callerThread) == "suspended" then
			task.spawn(callerThread)
		end
	end)

	if not isFinished then
		if step.OnYield then
			step.OnYield()
		end
		local threshold = settings.YIELD_THRESHOLD or DEFAULT_YIELD_THRESHOLD
		local warningThread = task.delay(threshold, function()
			while true do
				newWarn(
					`>> {step.Description} is taking a while!`,
					`({formatSeconds(os.clock() - startTime)} seconds elapsed)`
				)
				task.wait(SLOW_CALL_WARNING_INTERVAL)
			end
		end)
		while not isFinished do
			coroutine.yield()
		end
		task.cancel(warningThread)
	end

	return succeeded, failure, os.clock() - startTime
end

local function getActorParentAsync(): Instance
	if isClient then
		return (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts")
	end
	return ServerScriptService
end

--[[
	Requires a Parallel module inside a fresh Actor. Actor VMs keep their own
	require cache, so when a pointer and its real module are both discovered,
	they are deduplicated by the instance they resolve to, not by the value
	they return.
]]
local function loadParallelModuleAsync(module: ModuleScript, actorTemplate: Actor)
	local canonicalModule = resolveRelocationTarget(module)
	if seenParallelTargets[canonicalModule] then
		if settings.VERBOSE_LOADING then
			newPrint(
				`Skipping PARALLEL module '{module.Name}' - already loaded`,
				"via its relocated counterpart"
			)
		end
		return
	end
	seenParallelTargets[canonicalModule] = true

	local actor = actorTemplate:Clone()
	local loaderCopy = parallelModuleLoader:Clone()
	loaderCopy.Parent = actor
	local actorScript: BaseScript = actor:FindFirstChildWhichIsA("BaseScript") :: any
	actorScript.Enabled = true
	actorScript.Name = `Required{module.Name}`
	actor.Parent = getActorParentAsync()

	if settings.VERBOSE_LOADING then
		newPrint(`Loading PARALLEL module '{module.Name}'`)
	end
	local _, _, elapsed = runLifecycleStepAsync({
		Description = `Loading PARALLEL Module '{module.Name}'`,
		MemoryCategory = `Module::{module.Name}`,
		Run = function()
			waitForAttributeAsync(actorScript, "Loaded")
			actor:SendMessage("RequireModule", module)
			waitForAttributeAsync(actorScript, "Required")
		end,
	})
	local didRequireFail = actorScript:GetAttribute("Errored") == true
	if didRequireFail then
		newWarn(
			`>> Failed to load PARALLEL module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)`
		)
	elseif settings.VERBOSE_LOADING then
		newPrint(
			`>> Loaded PARALLEL module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)`
		)
	end

	-- Relocating after the require keeps relative paths inside the module
	-- valid.
	relocateToServerScriptService(module)

	if didRequireFail then
		return
	end
	actorsByModule[module] = actor
	tracker.Load[module] = true
end

local function loadModule(module: ModuleScript)
	if readFlag(module, "Parallel") then
		local actorTemplate = if isClient then actorForClient else actorForServer
		if actorTemplate then
			loadParallelModuleAsync(module, actorTemplate)
			return
		end
		newWarn(
			`Parallel module {module.Name} requested but no Actor template is configured -`,
			"loading normally"
		)
	end

	if settings.VERBOSE_LOADING then
		newPrint(`Loading module '{module.Name}'`)
	end
	local result: any = nil
	local succeeded, failure, elapsed = runLifecycleStepAsync({
		Description = `Loading Module '{module.Name}'`,
		MemoryCategory = `Module::{module.Name}`,
		Run = function()
			result = require(module)
		end,
		OnYield = function()
			-- Only a module moved after its require stays visible to clients
			-- while the require yields.
			if isServer and readFlag(module, "RelocateToServerScriptService") then
				newWarn(
					`[SECURITY] Module '{module.Name}' yielded during require()!\n`,
					"Modules with RelocateToServerScriptService may still be accessible to"
						.. " clients.\n",
					"Avoid yielding in module top-level code to ensure timely relocation."
				)
			end
		end,
	})
	if not succeeded then
		newWarn(
			`>> Failed to load module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)\n{failure}`
		)
		return
	end

	-- Duplicate loaded values (a pointer and its real target both discovered)
	-- register once so Init/Start run once per result. Only tables dedup,
	-- since primitives would collide across unrelated modules.
	local isTable = type(result) == "table"
	local isDuplicate = isTable and seenResults[result] ~= nil
	if not isDuplicate then
		if isTable then
			seenResults[result] = true
		end
		tracker.Load[module] = result
	end
	-- Relocation runs after the require to keep relative paths valid, and for
	-- duplicates too, so a module is hidden no matter which copy loaded first.
	relocateToServerScriptService(module)

	if settings.VERBOSE_LOADING then
		newPrint(`>> Loaded module {module.Name}`, `(took {formatSeconds(elapsed)} seconds)`)
	end
end

--[[
	Records every Init/Start function a loaded table defines itself. Runs once
	after the load phase, so which module owns a shared function never depends
	on load order.
]]
local function recordOwnedLifecycleMethods()
	for result in seenResults do
		for _, methodName in LIFECYCLE_METHODS do
			local method = rawget(result, methodName)
			if method ~= nil then
				ownedLifecycleMethods[method] = true
			end
		end
	end
end

--[[
	Returns the Init/Start method to call on a loaded module, or nil. A method
	the module only inherits through its metatable (e.g. a Client service
	inheriting its Shared service's Init) is skipped when another loaded
	module defines it, so that module runs it once with itself as self instead
	of once more per inheritor.
]]
local function getLifecycleMethod(loadedModule: any, methodName: string): ((any) -> ())?
	-- Non-table results (function or constant modules) are valid loads with no
	-- lifecycle.
	if type(loadedModule) ~= "table" then
		return nil
	end
	local method = loadedModule[methodName]
	if not method then
		return nil
	end
	if rawget(loadedModule, methodName) == nil and ownedLifecycleMethods[method] then
		return nil
	end
	return method
end

local function getLifecycleResults(methodName: LifecycleMethodName): { [ModuleScript]: boolean }
	return if methodName == "Init" then tracker.Init else tracker.Start
end

local function runParallelLifecycleMethodAsync(
	actor: Actor,
	module: ModuleScript,
	methodName: LifecycleMethodName
)
	local words = LIFECYCLE_LOG_WORDS[methodName]
	local results = getLifecycleResults(methodName)
	local doneAttribute = if methodName == "Init" then "Initialized" else "Started"
	local actorScript: BaseScript = actor:FindFirstChildWhichIsA("BaseScript") :: any
	results[module] = false

	if settings.VERBOSE_LOADING then
		newPrint(`{words.Running} PARALLEL module '{module.Name}'`)
	end
	local _, _, elapsed = runLifecycleStepAsync({
		Description = `:{methodName}() for PARALLEL Module '{module.Name}'`,
		MemoryCategory = `Module::{module.Name}::{methodName}`,
		Run = function()
			actor:SendMessage(`{methodName}Module`)
			waitForAttributeAsync(actorScript, doneAttribute)
		end,
	})
	if actorScript:GetAttribute("Errored") then
		newWarn(
			`>> Failed to {words.Verb} PARALLEL module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)`
		)
		return
	end

	results[module] = true
	if settings.VERBOSE_LOADING then
		newPrint(
			`>> {words.Finished} PARALLEL module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)`
		)
	end
end

--[[
	Runs a loaded module's Init or Start, recording the outcome in the tracker:
	false while it runs or after it fails, true once it succeeds.
]]
local function runLifecycleMethodAsync(
	loadedModule: any,
	module: ModuleScript,
	methodName: LifecycleMethodName
)
	local actor = actorsByModule[module]
	if actor then
		runParallelLifecycleMethodAsync(actor, module, methodName)
		return
	end

	local method = getLifecycleMethod(loadedModule, methodName)
	if not method then
		return
	end
	local words = LIFECYCLE_LOG_WORDS[methodName]
	local results = getLifecycleResults(methodName)
	results[module] = false

	if settings.VERBOSE_LOADING then
		newPrint(`{words.Running} module '{module.Name}'`)
	end
	local succeeded, failure, elapsed = runLifecycleStepAsync({
		Description = `:{methodName}() for Module '{module.Name}'`,
		MemoryCategory = `Module::{module.Name}::{methodName}`,
		Run = function()
			method(loadedModule)
		end,
	})
	if not succeeded then
		newWarn(
			`>> Failed to {words.Verb} module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)\n{failure}`
		)
		return
	end

	results[module] = true
	if settings.VERBOSE_LOADING then
		newPrint(
			`>> {words.Finished} module {module.Name}`,
			`(took {formatSeconds(elapsed)} seconds)`
		)
	end
end

--[[
	Gets every module to load, each listed once, in load order.
]]
local function getModules(containers: { Instance }): { ModuleScript }
	local shouldKeep: KeepModulePredicate = customKeepModule or keepModule
	local modules: { ModuleScript } = {}
	local isListed: { [ModuleScript]: true } = {}

	-- A module can be found through several routes (overlapping containers, a
	-- container and a tag); it is listed by the first route that keeps it.
	local function addModule(container: Instance, module: ModuleScript)
		if isListed[module] then
			return
		end
		if not shouldKeep(container, module) then
			return
		end
		isListed[module] = true
		table.insert(modules, module)
	end

	for _, container in containers do
		for _, module in findAllFromClass("ModuleScript", container) do
			addModule(container, module)
		end
	end
	if settings.USE_COLLECTION_SERVICE and loaderTag ~= "" then
		for _, tagged in CollectionService:GetTagged(loaderTag) do
			if tagged:IsA("ModuleScript") then
				local parent = tagged.Parent
				if parent then
					addModule(parent, tagged)
				end
			elseif tagged:IsA("Folder") then
				for _, descendant in tagged:GetDescendants() do
					if descendant:IsA("ModuleScript") then
						addModule(tagged, descendant)
					end
				end
			else
				newWarn(`item: {tagged} with tag: {loaderTag} is not a ModuleScript or Folder!`)
			end
		end
	end

	local priorities: { [ModuleScript]: number } = {}
	for _, module in modules do
		priorities[module] = getLoaderPriority(module)
	end
	table.sort(modules, function(a, b)
		return priorities[a] > priorities[b]
	end)
	return modules
end

--[[
	Client only: builds the local ServerScriptService pointer tree from the
	server-authored relocation manifest so ServerScriptService require paths
	resolve identically on both realms. The manifest is the source of truth,
	so no replicated instances need to exist yet: each pointer resolves with
	its own WaitForChild walk at require time. Safe to re-run whenever the
	manifest changes.

	Modules relocated from containers outside ServerScriptService need no
	rebuilt path and carry no ServerScriptServicePath. Child modules that moved
	with a relocated parent have no manifest entry at all (accessed through
	the parent's return table by convention).
]]
local function rebuildServerScriptServiceHierarchy(manifest: { any })
	if not isClient or #manifest == 0 then
		return
	end
	local template = getRelocatedTemplate()

	local builtThisPass: { [string]: true } = {}
	for _, entry in manifest do
		if
			typeof(entry) ~= "table"
			or typeof(entry.RelocatedPath) ~= "string"
			or entry.RelocatedPath == ""
		then
			continue
		end
		local originalPath = entry.ServerScriptServicePath
		if typeof(originalPath) ~= "string" or originalPath == "" then
			continue
		end
		if builtThisPass[originalPath] then
			-- Two entries with one original path means two same-named siblings
			-- were relocated; the first entry wins, matching the server-side
			-- collision warning.
			newWarn(
				`Duplicate relocated path 'ServerScriptService.{originalPath}' in the relocation`,
				"manifest; requires of this path may resolve to the wrong module."
			)
			continue
		end

		local segments: { string } = string.split(originalPath, ".")
		local leafName = table.remove(segments) :: string

		local parent = getOrCreateClientFolderPath(ServerScriptService, segments)
		local existing = parent:FindFirstChild(leafName)
		if existing then
			local isOwnPointer = existing:IsA("ModuleScript")
				and existing:GetAttribute("_RelocatedService") ~= nil
			if not isOwnPointer then
				newWarn(
					`Cannot rebuild relocated path 'ServerScriptService.{originalPath}':`,
					`'{existing:GetFullName()}' already occupies that name; requires of this path`,
					"may resolve to the wrong instance."
				)
				continue
			end
			if existing:GetAttribute("_RelocatedPath") == entry.RelocatedPath then
				builtThisPass[originalPath] = true
				continue
			end
			-- Stale pointer from an outdated baked manifest. Re-clone instead
			-- of re-stamping because require() caches per instance.
			existing:Destroy()
		end

		local pointer = createPointer(template, leafName, "ReplicatedStorage", entry.RelocatedPath)
		-- Attribute parity with server-side pointers, so a client passing a
		-- rebuilt subtree as a Start() container still filters ServerOnly
		-- modules.
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
	Client only, spawned at require time (not Start) so the pointer tree
	exists as early as possible. Listens for the whole session and re-applies
	manifest changes, which recovers a server that calls Start() after the
	client's wait cap and heals stale attributes baked into the place file.
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
		local didDecode, manifest = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not didDecode or typeof(manifest) ~= "table" then
			newWarn(
				"Failed to decode relocation manifest; relocated ServerScriptService require paths",
				"cannot be rebuilt!\n",
				manifest
			)
			relocationManifest = {}
			return true
		end
		relocationManifest = manifest
		rebuildServerScriptServiceHierarchy(manifest)
		return true
	end

	local function tryComplete()
		if relocationRebuildDone then
			return
		end
		if not script:GetAttribute("RelocationComplete") then
			return
		end
		-- The server writes the manifest before RelocationComplete and
		-- attributes replicate atomically per instance, so a missing manifest
		-- here can only be stale baked state. Keep waiting for the real values
		-- instead of latching a wrong result; the wait cap in
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
	Client only: yields until the bootstrap has applied the manifest, capped
	so a missing server cannot hang the client. On timeout the loader warns
	and proceeds; the bootstrap still rebuilds in the background once the
	server catches up.
]]
local function waitForRelocationRebuild()
	if not isClient or relocationRebuildDone then
		return
	end
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
	task.delay(RELOCATION_MANIFEST_WAIT_CAP, function()
		if not relocationRebuildDone then
			newWarn(
				`RelocationComplete was not observed within {RELOCATION_MANIFEST_WAIT_CAP}s;`,
				"the server has not finished (or started) its relocation pre-pass.\n",
				"Proceeding to load; relocated require paths will be rebuilt in the background",
				"when the server catches up, but modules loading now may fail requires into",
				"ServerScriptService."
			)
		end
		resume()
	end)
	coroutine.yield()
end

--[[
	Walks a dotted <code>relocatedPath</code> under <code>root</code>, waiting
	for each segment until <code>deadline</code> (an os.clock() time). Returns
	the instance at the path, or nil and the dotted path of the first segment
	that never arrived.
]]
local function waitForRelocatedPath(
	root: Instance,
	relocatedPath: string,
	deadline: number
): (Instance?, string?)
	local current = root
	local walked: { string } = {}
	for segment in string.gmatch(relocatedPath, "[^%.]+") do
		table.insert(walked, segment)
		local budget = deadline - os.clock()
		local child = if budget > 0
			then current:WaitForChild(segment, budget)
			else current:FindFirstChild(segment)
		if not child then
			return nil, table.concat(walked, ".")
		end
		current = child
	end
	return current, nil
end

--[[
	Server only: records every path a client may ask to have resent, from the
	manifest the relocation pre-pass produced, and whether each subtree is
	small enough to resend. Done once here so a request never makes the server
	walk a subtree.
]]
local function recordResendablePaths(manifest: { RelocationManifestEntry })
	local root = replicatedRelocatedFolder
	if not root then
		return
	end
	for _, entry in manifest do
		local prefix: string? = nil
		local instance: Instance? = root
		for segment in string.gmatch(entry.RelocatedPath, "[^%.]+") do
			prefix = if prefix then `{prefix}.{segment}` else segment
			instance = if instance then instance:FindFirstChild(segment) else nil
			local path = prefix :: string
			if instance and resendablePaths[path] == nil then
				local descendantCount = #instance:GetDescendants()
				resendablePaths[path] = descendantCount <= RELOCATION_REPAIR_MAX_DESCENDANTS
			end
		end
	end
end

--[[
	Server only: detaches a relocated instance and re-attaches it, which makes
	every client that lacks it receive it again. Clients that already have it
	keep the same instance; they only see its ancestry change twice.
]]
local function resendRelocatedInstanceAsync(player: Player, path: string)
	local root = replicatedRelocatedFolder
	if not root then
		return
	end
	local instance: Instance? = root
	for segment in string.gmatch(path, "[^%.]+") do
		instance = (instance :: Instance):FindFirstChild(segment)
		if not instance then
			return
		end
	end
	local target = instance :: Instance
	local parent = target.Parent
	if target == root or not parent then
		return
	end
	local lastResend = lastResendTimes[target]
	if lastResend and os.clock() - lastResend < RELOCATION_REPAIR_COOLDOWN then
		if settings.VERBOSE_LOADING then
			newPrint(
				`Skipping resend of relocated '{path}' for {player.Name}:`,
				"it was resent moments ago."
			)
		end
		return
	end
	-- Counted across all players, so rejoining cannot keep the relocated tree
	-- churning.
	local now = os.clock()
	while recentResendTimes[1] and now - recentResendTimes[1] > RELOCATION_REPAIR_RATE_WINDOW do
		table.remove(recentResendTimes, 1)
	end
	if #recentResendTimes >= RELOCATION_REPAIR_MAX_RESENDS_PER_WINDOW then
		newWarn(`Not resending relocated '{path}' for {player.Name}: too many resends recently.`)
		return
	end
	table.insert(recentResendTimes, now)
	lastResendTimes[target] = now

	newWarn(`Resending relocated '{path}' because it never reached {player.Name}.`)
	target.Parent = nil
	task.wait(RELOCATION_REPAIR_DETACH_TIME)
	target.Parent = parent
end

--[[
	Server only: works through queued resends one at a time, once the server
	has finished loading. A resend detaches a subtree for every realm, so none
	may land in the middle of the server's own load, and one at a time means a
	folder's resend never overlaps a resend of something inside it.
]]
local function processPendingResendsAsync()
	waitForAttributeAsync(script, "ServerLoaded")
	while #pendingResends > 0 do
		local resend = table.remove(pendingResends, 1) :: PendingResend
		local resent, failure = pcall(function()
			resendRelocatedInstanceAsync(resend.Player, resend.Path)
		end)
		if not resent then
			newWarn(`Resending relocated '{resend.Path}' failed: {failure}`)
		end
	end
	isResendWorkerRunning = false
end

local function hasRequestedAncestor(path: string, requested: { [string]: true }): boolean
	local prefix: string? = nil
	for segment in string.gmatch(path, "[^%.]+") do
		if prefix and requested[prefix] then
			return true
		end
		prefix = if prefix then `{prefix}.{segment}` else segment
	end
	return false
end

--[[
	Server only: handles a client's list of relocated paths that never
	replicated to it. The paths come from the client, so only a client that
	has not finished loading may ask, once, and only paths this server's
	manifest produced are acted on.
]]
local function onRelocationRepairRequested(player: Player, paths: unknown)
	local requestCount = (repairRequestsByPlayer[player] or 0) + 1
	repairRequestsByPlayer[player] = requestCount
	if
		requestCount > RELOCATION_REPAIR_MAX_REQUESTS
		or player:GetAttribute("_ModulesLoaded")
		or typeof(paths) ~= "table"
	then
		return
	end

	local requested: { [string]: true } = {}
	local examined = 0
	for _, path in paths :: { [any]: unknown } do
		examined += 1
		if examined > RELOCATION_REPAIR_MAX_PATHS then
			break
		end
		if typeof(path) ~= "string" then
			continue
		end
		if resendablePaths[path] == true then
			requested[path] = true
		elseif resendablePaths[path] == false then
			newWarn(`Relocated '{path}' never reached {player.Name} but is too large to resend.`)
		end
	end
	-- Resending a folder delivers everything inside it, so only the top-most
	-- paths are queued.
	for path in requested do
		if not hasRequestedAncestor(path, requested) then
			table.insert(pendingResends, { Player = player, Path = path })
		end
	end

	if #pendingResends > 0 and not isResendWorkerRunning then
		isResendWorkerRunning = true
		task.spawn(processPendingResendsAsync)
	end
end

--[[
	Client only: waits (bounded) for every manifest entry to exist under
	RELOCATED_MODULES so the discovery snapshot in getModules sees the full
	tree. The wait ends as soon as everything has replicated, and it checks
	for every entry rather than waiting for replication to go quiet, so a
	stalled partial tree cannot pass. Paths still missing after
	RELOCATION_REPAIR_DELAY are reported to the server to be resent. Pointer
	resolution never depends on this, so on timeout the loader warns and
	proceeds.
]]
local function waitForRelocatedTree()
	if not isClient then
		return
	end
	local manifest = relocationManifest
	if not manifest or #manifest == 0 then
		return
	end
	local deadline = os.clock() + RELOCATED_TREE_WAIT_CAP
	local root: Instance? = ReplicatedStorage:FindFirstChild(RELOCATED_FOLDER_NAME)
		or ReplicatedStorage:WaitForChild(RELOCATED_FOLDER_NAME, RELOCATED_TREE_WAIT_CAP)
	if not root then
		newWarn(
			"ReplicatedStorage.RELOCATED_MODULES did not replicate within",
			`{RELOCATED_TREE_WAIT_CAP}s despite a non-empty relocation manifest; relocated`,
			"modules may fail to load."
		)
		return
	end

	local entries: { RelocationManifestEntry } = {}
	for _, entry in manifest do
		if
			typeof(entry) == "table"
			and typeof(entry.RelocatedPath) == "string"
			and entry.RelocatedPath ~= ""
		then
			table.insert(entries, entry)
		end
	end

	-- First pass: ask the server to resend whatever is still missing after a
	-- few seconds.
	local repairDeadline = math.min(os.clock() + RELOCATION_REPAIR_DELAY, deadline)
	local missingPrefixes: { [string]: true } = {}
	for _, entry in entries do
		local _, missingPrefix = waitForRelocatedPath(root, entry.RelocatedPath, repairDeadline)
		if missingPrefix then
			missingPrefixes[missingPrefix] = true
		end
	end
	if next(missingPrefixes) ~= nil then
		local requested: { string } = {}
		for prefix in missingPrefixes do
			table.insert(requested, prefix)
		end
		newWarn(
			`{#requested} relocated path(s) had not replicated after {RELOCATION_REPAIR_DELAY}s;`,
			"asking the server to resend:\n",
			table.concat(requested, "\n")
		)
		relocationRepairEvent:FireServer(requested)
	end

	local shortfalls: { string } = {}
	for _, entry in entries do
		local current = waitForRelocatedPath(root, entry.RelocatedPath, deadline)
		if not current then
			continue
		end
		local expectedDescendants = entry.DescendantCount
		if typeof(expectedDescendants) ~= "number" or expectedDescendants <= 0 then
			continue
		end
		-- Children that moved with the module may replicate after the module
		-- itself.
		local leaf = current :: Instance
		while #leaf:GetDescendants() < expectedDescendants and os.clock() < deadline do
			task.wait(REPLICATION_POLL_INTERVAL)
		end
		local actualDescendants = #leaf:GetDescendants()
		if actualDescendants < expectedDescendants then
			table.insert(
				shortfalls,
				`{entry.RelocatedPath} ({actualDescendants}/{expectedDescendants} descendants)`
			)
		end
	end

	-- Discovery runs right after this returns, without yielding, so the last
	-- step here is always a check that does not yield: another player's resend
	-- can briefly detach a subtree an earlier step already saw. The check runs
	-- at least once even when the cap is spent.
	local tree = root :: Instance
	local function findAbsentPaths(): { string }
		local absent: { string } = {}
		for _, entry in entries do
			if not waitForRelocatedPath(tree, entry.RelocatedPath, 0) then
				table.insert(absent, entry.RelocatedPath)
			end
		end
		return absent
	end
	local missing = findAbsentPaths()
	while #missing > 0 and os.clock() < deadline do
		task.wait(REPLICATION_POLL_INTERVAL)
		missing = findAbsentPaths()
	end
	for _, shortfall in shortfalls do
		table.insert(missing, shortfall)
	end
	if #missing > 0 then
		newWarn(
			`{#missing} relocated module(s) had not replicated within {RELOCATED_TREE_WAIT_CAP}s`,
			"and may fail to load:\n",
			table.concat(missing, "\n")
		)
	end
end

-----------------------------
-- PUBLIC FUNCTIONS --
-----------------------------

--[[
	Starts the loader with the default module filtering. Searches every
	folder passed in, as well as tagged modules and folders. Call once per
	realm.
]]
function Module.Start(...: Instance)
	assert(not started, "attempt to start module loader more than once")
	started = true
	local containers = { ... }
	if isServer then
		local manifest = relocateToReplicatedStoragePass(containers)
		recordResendablePaths(manifest)
		-- Manifest before RelocationComplete: clients treat the flag as
		-- "manifest is readable".
		script:SetAttribute("_RelocationManifest", HttpService:JSONEncode(manifest))
		script:SetAttribute("RelocationComplete", true)
	else
		waitForRelocationRebuild()
	end
	if isClient and settings.WAIT_FOR_SERVER then
		waitForAttributeAsync(script, "ServerLoaded")
	end
	if isClient and settings.WAIT_FOR_PERSISTENT then
		waitForAttributeAsync(workspace, "IsPersistentLoaded")
	end
	-- Right before discovery, with no yield in between, so getModules sees the
	-- tree this verified.
	waitForRelocatedTree()

	if settings.VERBOSE_LOADING then
		newWarn("=== LOADING MODULES ===")
	end
	local phaseStartTime = os.clock()
	local modules = getModules(containers)
	for _, module in modules do
		loadModule(module)
	end
	recordOwnedLifecycleMethods()
	local loadDuration = os.clock() - phaseStartTime

	if settings.VERBOSE_LOADING then
		newWarn("=== INITIALIZING MODULES ===")
	end
	phaseStartTime = os.clock()
	for _, module in modules do
		local loadedModule = tracker.Load[module]
		if not loadedModule then
			continue
		end
		runLifecycleMethodAsync(loadedModule, module, "Init")
	end
	local initDuration = os.clock() - phaseStartTime

	if settings.VERBOSE_LOADING then
		newWarn("=== STARTING MODULES ===")
	end
	phaseStartTime = os.clock()
	for _, module in modules do
		local loadedModule = tracker.Load[module]
		if not loadedModule then
			continue
		end
		if tracker.Init[module] == false then
			newWarn(`>> Skipping :Start() for module {module.Name} because its :Init() failed`)
			continue
		end
		runLifecycleMethodAsync(loadedModule, module, "Start")
	end
	local startDuration = os.clock() - phaseStartTime

	if settings.VERBOSE_LOADING then
		newWarn("=== LOADING FINISHED ===")
		newWarn(
			`Took {formatSeconds(loadDuration + initDuration + startDuration)} seconds total`,
			`(require {formatSeconds(loadDuration)}, init {formatSeconds(initDuration)},`,
			`start {formatSeconds(startDuration)})`
		)
	end

	script:SetAttribute(`{LOADED_IDENTIFIER}LoadedTimestamp`, workspace:GetServerTimeNow())
	script:SetAttribute(`{LOADED_IDENTIFIER}Loaded`, true)
	if isClient then
		loadedEvent:FireServer()
	end
end

--[[
	Starts the loader with your own filter deciding which discovered modules
	load. Relocation still follows the default rules.
]]
function Module.StartCustom(shouldKeep: KeepModulePredicate, ...: Instance)
	customKeepModule = shouldKeep
	Module.Start(...)
end

--[[
	Overrides the settings read from the attributes on the module loader. Keys
	left out of <code>newSettings</code> keep their current value.
]]
function Module.ChangeSettings(newSettings: LoaderSettings)
	local overrides: { [string]: any } = newSettings :: any
	local current: { [string]: any } = settings :: any
	for key, value in overrides do
		current[key] = value
	end
end

--[[
	Returns if the server finished loading, initializing, and starting all
	modules.
]]
function Module.IsServerLoaded(): boolean
	return script:GetAttribute("ServerLoaded") == true
end

--[[
	Returns if the client finished loading, initializing, and starting all
	modules.
]]
function Module.IsClientLoaded(player: Player): boolean
	return player:GetAttribute("_ModulesLoaded") == true
end

--[[
	Client only. Returns if persistent models have streamed into workspace.
]]
function Module.IsPersistentLoaded(): boolean
	assert(isClient, "isPersistentLoaded is client-only!")
	return workspace:GetAttribute("IsPersistentLoaded") == true
end

--[[
	<strong><code>!YIELDS!</code></strong>
	Yields until the client has loaded all their modules.
	Returns true if loaded or returns false if player left.
]]
function Module.WaitForLoadedClient(player: Player): boolean
	if player:GetAttribute("_ModulesLoaded") then
		return true
	end
	-- A player who already left will never fire either signal.
	if not player.Parent then
		return false
	end
	return waitForEither(
		player:GetAttributeChangedSignal("_ModulesLoaded"),
		player:GetPropertyChangedSignal("Parent")
	)
end

--[[
	Returns the server time (workspace:GetServerTimeNow()) when the server
	finished loading. Errors if the server is not loaded yet.
]]
function Module.GetServerLoadedTimestamp(): number
	assert(Module.IsServerLoaded(), "server is not loaded yet!")
	return script:GetAttribute("ServerLoadedTimestamp") :: number
end

-----------------------------
-- MAIN --
-----------------------------
local verboseLoading = readSettingAttribute("VerboseLoading", "boolean")
settings = {
	WAIT_FOR_PERSISTENT = readSettingAttribute("ClientWaitForPersistentLoaded", "boolean") == true,
	YIELD_THRESHOLD = readSettingAttribute("YieldThreshold", "number") or DEFAULT_YIELD_THRESHOLD,
	VERBOSE_LOADING = if verboseLoading == nil then DEFAULT_VERBOSE_LOADING else verboseLoading,
	WAIT_FOR_SERVER = readSettingAttribute("ClientWaitForServer", "boolean") == true,
	USE_COLLECTION_SERVICE = readSettingAttribute("UseCollectionService", "boolean") == true,
}
loaderTag = readSettingAttribute("LoaderTag", "string") or DEFAULT_LOADER_TAG
loadedEvent = getLoaderRemoteAsync("LoadedEvent")
relocationRepairEvent = getLoaderRemoteAsync("RelocationRepairEvent")

if isRunning and isServer then
	-- Attributes copied out of a running play session survive in the place
	-- file; stale relocation state would make clients skip the gate before the
	-- real pre-pass runs.
	script:SetAttribute("RelocationComplete", nil)
	script:SetAttribute("_RelocationManifest", nil)

	local persistentLoadedCheck = script.PersistentLoadedCheck:Clone()
	persistentLoadedCheck.Enabled = true
	persistentLoadedCheck.Parent = ReplicatedFirst
	loadedEvent.OnServerEvent:Connect(function(player)
		player:SetAttribute("_ModulesLoaded", true)
	end)
	relocationRepairEvent.OnServerEvent:Connect(onRelocationRepairRequested)
	Players.PlayerRemoving:Connect(function(player)
		repairRequestsByPlayer[player] = nil
	end)
elseif isRunning then
	-- Rebuild pointers as soon as the manifest replicates rather than when
	-- Start() happens to be called, shrinking the window where non-loader
	-- client code can hit a missing ServerScriptService path.
	task.spawn(clientRelocationBootstrap)
end

-- Unstable internal surface exposed for tests only; nil outside Studio so test
-- hooks never run in live servers. Values that get reassigned (settings,
-- the keep filter, the relocation manifest, the loader tag) go through
-- functions so tests always see the live value.
local internalsForTest: { [string]: any }? = nil
if RunService:IsStudio() then
	internalsForTest = {
		-- discovery / filtering
		getModules = getModules,
		keepModule = function(container: Instance, module: ModuleScript): boolean
			local shouldKeep: KeepModulePredicate = customKeepModule or keepModule
			return shouldKeep(container, module)
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
		waitForRelocatedPath = waitForRelocatedPath,
		-- relocation (server repair)
		recordResendablePaths = recordResendablePaths,
		resendRelocatedInstanceAsync = resendRelocatedInstanceAsync,
		onRelocationRepairRequested = onRelocationRepairRequested,
		-- lifecycle
		loadModule = loadModule,
		initializeModule = function(loadedModule: any, module: ModuleScript)
			runLifecycleMethodAsync(loadedModule, module, "Init")
		end,
		startModule = function(loadedModule: any, module: ModuleScript)
			runLifecycleMethodAsync(loadedModule, module, "Start")
		end,
		recordOwnedLifecycleMethods = recordOwnedLifecycleMethods,
		getLifecycleMethod = getLifecycleMethod,
		-- utilities
		waitForEither = waitForEither,
		-- test control knobs; each returns the previous value so tests can
		-- restore it
		setLoaderTag = function(tag: string): string
			local previous = loaderTag
			loaderTag = tag
			return previous
		end,
		setUseCollectionService = function(enabled: boolean?): boolean?
			local previous = settings.USE_COLLECTION_SERVICE
			settings.USE_COLLECTION_SERVICE = enabled
			return previous
		end,
		-- live state
		getTracker = function()
			return tracker
		end,
		getSettings = function(): LoaderSettings
			return settings
		end,
		getRelocationManifest = function(): { any }?
			return relocationManifest
		end,
	}
end
Module._internalsForTest = internalsForTest

return Module
