local source = script:FindFirstChild("src")

if source == nil then
    error("ModuleLoader: Missing 'src' folder")
end

local implementation = source:FindFirstChild("ModuleLoader")
if implementation == nil then
    error("ModuleLoader: Missing 'src/ModuleLoader.luau'")
end

return require(implementation)