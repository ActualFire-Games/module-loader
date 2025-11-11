--!strict
local ServerScriptService = game:GetService("ServerScriptService")

local RELOCATED_FOLDER = ServerScriptService:FindFirstChild("RELOCATED_MODULES")
assert(RELOCATED_FOLDER, "ServerScriptService missing 'RELOCATED_MODULES' folder")

local module = RELOCATED_FOLDER:FindFirstChild(script.Name)
assert(module, `RELOCATED_MODULES folder missing module '{script.Name}'`)

return require(module) :: any