-- Diagnostic: reports exactly what Shared/Defense/ParryWindows.lua sees when it tries to read a parry
-- window off an animation asset -- for the case where the boot log says a clip has no window but the
-- markers are visibly there in the Animation Editor.
--
-- Run this from Roblox Studio's Command Bar (View > Command Bar) with the place open. Paste the whole
-- file in and hit Enter. It only reads; it changes nothing.
--
-- IT SWEEPS Workspace.Weapons ITSELF, so it checks the same ids DefenseSystem.Init actually warms --
-- every weapon's Animations/PARRY clip plus the shared baseline. Add ids to EXTRA_IDS to check one
-- that is not on a weapon yet.
--
-- WHAT IT IS CHECKING FOR, in the order the real code checks:
--   1. Does the asset DOWNLOAD at all (GetKeyframeSequenceAsync)? A failure here is an ownership or
--      rate-limit problem, NOT a marker problem -- and it is the case that looks identical to
--      "no markers" from the boot log alone.
--   2. Does it carry KeyframeMarker instances (Animation Editor markers) -- not merely NAMED
--      KEYFRAMES, which are a different thing the reader ignores entirely.
--   3. Are they named exactly ParryStart / ParryClose (case-sensitive), with the optional
--      ParryRecoveryEnd?
--   4. Is Close strictly AFTER Open? Two markers on the SAME keyframe is a refused window, not a
--      short one.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Workspace = game:GetService("Workspace")

-- Extra ids to check beyond what Workspace.Weapons carries. The shared baseline pair from
-- DefenseConstants goes here so this script needs no require of game code.
local EXTRA_IDS = {
	"rbxassetid://94883396723007", -- DefenseConstants.ParryAnimationId (the shared baseline)
}

local MARKER_OPEN = "ParryStart"
local MARKER_CLOSE = "ParryClose"
local MARKER_RECOVERY_END = "ParryRecoveryEnd"

local function normalize(assetId)
	if assetId == "" then
		return ""
	end
	if string.match(assetId, "^rbxassetid://") then
		return assetId
	end
	if string.match(assetId, "^%d+$") then
		return "rbxassetid://" .. assetId
	end
	return assetId
end

-- id -> a readable label, so a failure names a weapon rather than a number.
local function collectIds()
	local labels = {}
	local order = {}

	local function add(id, label)
		id = normalize(id)
		if id == "" then
			return
		end
		if labels[id] then
			labels[id] = labels[id] .. " + " .. label
			return
		end
		labels[id] = label
		table.insert(order, id)
	end

	local weapons = Workspace:FindFirstChild("Weapons")
	if weapons then
		for _, model in weapons:GetChildren() do
			local animations = model:FindFirstChild("Animations")
			local parryFolder = animations and animations:FindFirstChild("PARRY")
			local animation = parryFolder and parryFolder:FindFirstChildOfClass("Animation")
			if animation and animation.AnimationId ~= "" then
				add(animation.AnimationId, model.Name .. ":PARRY")
			elseif parryFolder then
				print(("  [SKIP] %s has an Animations/PARRY folder but no clip in it"):format(model.Name))
			end
		end
	else
		print("  [SKIP] No Workspace.Weapons folder in this place")
	end

	for _, id in EXTRA_IDS do
		add(id, "baseline (DefenseConstants.ParryAnimationId)")
	end

	return order, labels
end

local function report(animationId, label)
	print(("\n=== %s  (%s)"):format(label, animationId))

	local ok, sequence = pcall(function()
		return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)
	end)

	if not ok then
		print("  [FAIL] The asset did not download. This is NOT a marker problem.")
		print("         " .. tostring(sequence))
		print("         Usual causes: the animation is owned by a different account/group than this")
		print("         place, or the id is wrong. Re-upload it under the place owner.")
		return
	end
	if typeof(sequence) ~= "Instance" or not sequence:IsA("KeyframeSequence") then
		print("  [FAIL] Downloaded, but it is not a KeyframeSequence. Wrong asset id?")
		return
	end

	local times = {}
	local markerCount = 0
	local namedKeyframes = {}
	for _, child in sequence:GetChildren() do
		if not child:IsA("Keyframe") then
			continue
		end
		-- A NAMED KEYFRAME is not a marker. Collected separately because naming the keyframe instead
		-- of adding a marker is the single easiest way to have markers that "are there" and are not.
		if child.Name ~= "Keyframe" and child.Name ~= "" then
			table.insert(namedKeyframes, ("%s @ %.4f"):format(child.Name, child.Time))
		end
		for _, marker in child:GetChildren() do
			if not marker:IsA("KeyframeMarker") then
				continue
			end
			markerCount += 1
			local existing = times[marker.Name]
			if existing == nil or child.Time < existing then
				times[marker.Name] = child.Time
			end
		end
	end

	print(("  Downloaded OK. %d keyframe(s), %d KeyframeMarker(s)."):format(#sequence:GetChildren(), markerCount))
	if markerCount == 0 then
		print("  [FAIL] No KeyframeMarker instances at all.")
		if #namedKeyframes > 0 then
			print("         But these keyframes are NAMED: " .. table.concat(namedKeyframes, ", "))
			print("         Naming a keyframe is NOT the same as adding a marker. In the Animation")
			print("         Editor, right-click the keyframe and use the animation-EVENT/marker option.")
		end
		print("         If the markers are visible in the editor, the PUBLISHED asset is stale --")
		print("         re-publish/overwrite the animation, then restart the server.")
		return
	end

	local found = {}
	for name, time in times do
		table.insert(found, ("%s @ %.4f"):format(name, time))
	end
	table.sort(found)
	print("  Markers found: " .. table.concat(found, ", "))

	local open, close = times[MARKER_OPEN], times[MARKER_CLOSE]
	if open == nil and close == nil then
		print(("  [FAIL] None of them are named %s / %s. Names are CASE-SENSITIVE."):format(MARKER_OPEN, MARKER_CLOSE))
		return
	end
	if open == nil then
		print(("  [FAIL] Missing %s (found %s). Both are required as a pair."):format(MARKER_OPEN, MARKER_CLOSE))
		return
	end
	if close == nil then
		print(("  [FAIL] Missing %s (found %s). Both are required as a pair."):format(MARKER_CLOSE, MARKER_OPEN))
		return
	end
	if close <= open then
		print(("  [FAIL] %s (%.4f) is not strictly after %s (%.4f)."):format(MARKER_CLOSE, close, MARKER_OPEN, open))
		print("         Two markers on the SAME keyframe is refused, not treated as a short window.")
		return
	end

	local recoveryEnd = times[MARKER_RECOVERY_END]
	if recoveryEnd and recoveryEnd < close then
		print(("  [FAIL] %s (%.4f) is before %s (%.4f)."):format(MARKER_RECOVERY_END, recoveryEnd, MARKER_CLOSE, close))
		return
	end

	print(("  [OK] Window is %.4fs -> %.4fs (%.0f ms live)."):format(open, close, (close - open) * 1000))
	if recoveryEnd then
		print(("       ParryRecoveryEnd @ %.4f"):format(recoveryEnd))
	else
		print("       No ParryRecoveryEnd -- falls back to DefenseConstants.Parry.RecoverySeconds. Fine.")
	end
end

task.spawn(function()
	print("--- Parry marker check ---")
	local order, labels = collectIds()
	if #order == 0 then
		print("No parry animation ids found to check.")
		return
	end
	for _, id in order do
		report(id, labels[id])
	end
	print("\n--- done ---")
end)
