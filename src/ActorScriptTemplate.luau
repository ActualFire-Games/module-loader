--!strict
--@author: crusherfire
--@date: 5/8/24
--[[@description:
	Should be placed as a child script of the actor.
]]
-----------------------------
-- DEPENDENCIES --
-----------------------------
-- Navigate up: script.Parent (Actor) -> Parent (ModuleLoader) -> Parent (src) -> ParallelModuleLoader
local ParallelModuleLoader = require(script.Parent.Parent.Parent.ParallelModuleLoader)

-----------------------------
-- VARIABLES --
-----------------------------
local actor: Actor = script.Parent

-----------------------------
-- HANDLERS --
-----------------------------
actor:BindToMessage("RequireModule", function(module: ModuleScript)
	ParallelModuleLoader.onRequireModule(script, module)
end)

actor:BindToMessage("InitModule", function()
	ParallelModuleLoader.onInitModule(script)
end)

actor:BindToMessage("StartModule", function()
	ParallelModuleLoader.onStartModule(script)
end)

-----------------------------
-- MAIN --
-----------------------------
script:SetAttribute("Loaded", true)