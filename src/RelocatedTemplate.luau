--!strict
--[[
	Unified hierarchy-aware pointer left behind when a module is relocated.

	The ModuleLoader writes two attributes on every pointer at relocation time:
		_RelocatedService	"ServerScriptService" or "ReplicatedStorage"
		_RelocatedPath		slash-separated path under that service's RELOCATED_MODULES
							folder (e.g. "Gameplay/Combat/Shared/DamageMath")

	The pointer resolves by walking the path with WaitForChild so first-join
	clients tolerate slow replication. When pointing to ServerScriptService,
	any client require() is treated as a security violation and errors.
]]
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const ServerScriptService = game:GetService("ServerScriptService")

const SERVICE_BY_NAME: { [string]: Instance } = {
	ServerScriptService = ServerScriptService,
	ReplicatedStorage = ReplicatedStorage,
}

-- Seconds; generous enough for replication, finite so misconfigured pointers
-- surface as errors.
const WAIT_PER_SEGMENT = 10
-- Keep in sync with the ModuleLoader, which creates the folder.
const RELOCATED_FOLDER_NAME = "RELOCATED_MODULES"

local relocatedService = script:GetAttribute("_RelocatedService")
local relocatedPath = script:GetAttribute("_RelocatedPath")

if typeof(relocatedService) ~= "string" or not SERVICE_BY_NAME[relocatedService] then
	error(
		`Relocated pointer '{script:GetFullName()}' missing or invalid _RelocatedService`
			.. " attribute"
	)
end
if typeof(relocatedPath) ~= "string" or relocatedPath == "" then
	error(`Relocated pointer '{script:GetFullName()}' missing or empty _RelocatedPath attribute`)
end

if relocatedService == "ServerScriptService" and RunService:IsClient() then
	error(`Client attempted to require() server-side relocated module '{script:GetFullName()}'`)
end

local service = SERVICE_BY_NAME[relocatedService]
local current: Instance? = service:WaitForChild(RELOCATED_FOLDER_NAME, WAIT_PER_SEGMENT)
if not current then
	error(
		`{relocatedService} missing 'RELOCATED_MODULES' folder for pointer '{script:GetFullName()}'`
	)
end

-- Keep in sync with the ModuleLoader's PATH_SEPARATOR.
for segment in string.gmatch(relocatedPath, "[^/]+") do
	current = (current :: Instance):WaitForChild(segment, WAIT_PER_SEGMENT)
	if not current then
		error(
			`Relocated pointer '{script:GetFullName()}' could not resolve segment '{segment}'`
				.. ` of path '{relocatedPath}'`
		)
	end
end

local target = current :: Instance
-- Guard against name collisions in the mirror (WaitForChild resolves by name
-- alone): failing loudly here beats require() throwing a vaguer error on a
-- Folder.
if not target:IsA("ModuleScript") then
	error(
		`Relocated pointer '{script:GetFullName()}' resolved path '{relocatedPath}' to`
			.. ` '{target:GetFullName()}', which is not a ModuleScript`
	)
end

return require(target) :: any
