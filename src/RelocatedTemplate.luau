--!strict
--[[
	Unified hierarchy-aware pointer left behind when a module is relocated.

	The ModuleLoader writes two attributes on every pointer at relocation time:
		_RelocatedService	"ServerScriptService" or "ReplicatedStorage"
		_RelocatedPath		dot-separated path under that service's RELOCATED_MODULES
							folder (e.g. "Gameplay.Combat.Shared.DamageMath")

	The pointer resolves by walking the path with WaitForChild so first-join
	clients tolerate slow replication. When pointing to ServerScriptService,
	any client require() is treated as a security violation and errors.
]]
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SERVICE_BY_NAME: { [string]: Instance } = {
	ServerScriptService = ServerScriptService,
	ReplicatedStorage = ReplicatedStorage,
}

local WAIT_PER_SEGMENT = 10 -- seconds; generous enough for replication, finite so misconfigured pointers surface as errors

local relocatedService = script:GetAttribute("_RelocatedService")
local relocatedPath = script:GetAttribute("_RelocatedPath")

assert(
	typeof(relocatedService) == "string" and SERVICE_BY_NAME[relocatedService],
	`Relocated pointer '{script:GetFullName()}' missing or invalid _RelocatedService attribute`
)
assert(
	typeof(relocatedPath) == "string" and relocatedPath ~= "",
	`Relocated pointer '{script:GetFullName()}' missing or empty _RelocatedPath attribute`
)

if relocatedService == "ServerScriptService" and RunService:IsClient() then
	error(`Client attempted to require() server-side relocated module '{script:GetFullName()}'`)
end

local service = SERVICE_BY_NAME[relocatedService]
local current: Instance? = service:WaitForChild("RELOCATED_MODULES", WAIT_PER_SEGMENT)
assert(current, `{relocatedService} missing 'RELOCATED_MODULES' folder for pointer '{script:GetFullName()}'`)

for segment in string.gmatch(relocatedPath, "[^%.]+") do
	current = (current :: Instance):WaitForChild(segment, WAIT_PER_SEGMENT)
	assert(current, `Relocated pointer '{script:GetFullName()}' could not resolve segment '{segment}' of path '{relocatedPath}'`)
end

local target = current :: Instance
-- Guard against name collisions in the mirror (WaitForChild resolves by name alone): failing
-- loudly here beats require() throwing a vaguer error on a Folder.
assert(
	target:IsA("ModuleScript"),
	`Relocated pointer '{script:GetFullName()}' resolved path '{relocatedPath}' to '{target:GetFullName()}', which is not a ModuleScript`
)

return require(target) :: any