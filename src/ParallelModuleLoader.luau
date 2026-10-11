--!strict
--@author: crusherfire
--@date: 5/8/24
--[[@description:
	General code for parallel scripts.
]]
-----------------------------
-- VARIABLES --
-----------------------------
local Module = {}

-- Each Actor gets its own copy of this module, so these variables are never
-- shared between Actors.
-- A local alias keeps the type checker from trying to resolve requires of
-- modules found at runtime.
local require = require
local requiredModule: any = nil

-----------------------------
-- PUBLIC FUNCTIONS --
-----------------------------

function Module.onRequireModule(script: BaseScript, module: ModuleScript)
	local success, result = xpcall(function()
		return require(module)
	end, debug.traceback)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Required", true)
		return
	end
	requiredModule = result
	script:SetAttribute("Required", true)
end

function Module.onInitModule(script: BaseScript)
	if script:GetAttribute("Errored") then
		warn("Unable to init errored module!")
		script:SetAttribute("Initialized", true)
		return
	end
	if not requiredModule then
		warn("Told to load module that does not exist!")
		script:SetAttribute("Initialized", true)
		return
	end
	-- Non-table results have no lifecycle; indexing .Init on them would error
	-- and leave the loader's Initialized wait hanging forever.
	if type(requiredModule) ~= "table" or not requiredModule.Init then
		script:SetAttribute("Initialized", true)
		return
	end

	local success, result = xpcall(function()
		requiredModule:Init()
	end, debug.traceback)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Initialized", true)
		return
	end
	script:SetAttribute("Initialized", true)
end

function Module.onStartModule(script: BaseScript)
	if script:GetAttribute("Errored") then
		warn("Unable to start errored module!")
		script:SetAttribute("Started", true)
		return
	end
	if not requiredModule then
		warn("Told to start module that does not exist!")
		script:SetAttribute("Started", true)
		return
	end
	-- See onInitModule: non-table results have no lifecycle.
	if type(requiredModule) ~= "table" or not requiredModule.Start then
		script:SetAttribute("Started", true)
		return
	end

	local success, result = xpcall(function()
		requiredModule:Start()
	end, debug.traceback)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Started", true)
		return
	end
	script:SetAttribute("Started", true)
end

return Module
