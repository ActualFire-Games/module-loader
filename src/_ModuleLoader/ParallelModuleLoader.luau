--!strict
--@author: crusherfire
--@date: 5/8/24
--[[@description:
	General code for parallel scripts.
]]
-- Since this module will be required by scripts in separate actors, these variables won't be shared!
local require = require
local requiredModule
local function onRequireModule(script: BaseScript, module: ModuleScript)
	local success, result = pcall(function()
		return require(module)
	end)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Required", true)
		return
	end
	requiredModule = result
	script:SetAttribute("Required", true)
end

local function onInitModule(script: BaseScript)
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
	if not requiredModule.Init then
		script:SetAttribute("Initialized", true)
		return
	end

	local success, result = pcall(function()
		requiredModule:Init()
	end)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Initialized", true)
		return
	end
	script:SetAttribute("Initialized", true)
end

local function onStartModule(script: BaseScript)
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
	if not requiredModule.Start then
		script:SetAttribute("Started", true)
		return
	end

	local success, result = pcall(function()
		requiredModule:Start()
	end)

	if not success then
		warn("Parallel module errored!\n", result)
		script:SetAttribute("Errored", true)
		script:SetAttribute("Started", true)
		return
	end
	script:SetAttribute("Started", true)
end

return { onRequireModule = onRequireModule, onInitModule = onInitModule, onStartModule = onStartModule }