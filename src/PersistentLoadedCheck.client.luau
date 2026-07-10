--!strict
-- Copied into ReplicatedFirst to ensure capturing PersistentLoaded event on client-side.
-- workspace is not properly replicated until after game.Loaded (cannot set attributes on workspace pre-Loaded)
local persistentFired = false
workspace.PersistentLoaded:Once(function()
	persistentFired = true
	-- Post-Loaded fire (including the same-drain-as-Loaded ordering): write the attribute here.
	-- Pre-Loaded fires skip the write (workspace attributes can't be set yet) and are handled by
	-- the flag check on the main thread below.
	if game:IsLoaded() and workspace.StreamingEnabled then
		workspace:SetAttribute("IsPersistentLoaded", true)
	end
end)

if not game:IsLoaded() then
	game.Loaded:Wait()
end

if workspace.StreamingEnabled then
	if persistentFired then
		workspace:SetAttribute("IsPersistentLoaded", true)
	else
		task.delay(20, function()
			if not workspace:GetAttribute("IsPersistentLoaded") then
				-- fail-safe
				warn(`Took longer than 20 seconds for PersistentLoaded to fire; assuming persistent is loaded!`)
				workspace:SetAttribute("IsPersistentLoaded", true)
			end
		end)
	end
else
	workspace:SetAttribute("IsPersistentLoaded", true)
end
