--!strict
--[[
	FurnacePromptClient.lua

	Owns: everything that decides when the furnace's custom prompt is on screen and where -- the
	ProximityPromptService wiring for the two furnace prompts, the hold clock behind the unload bar,
	and the world-to-screen projection that keeps the panel over the furnace it belongs to. Mirrors
	Client/Emotes/EmoteWheelClient.lua's role exactly: an input/orchestration module driving a Screen's
	handle from outside, where the Screen (UI/Screens/FurnacePrompt) is pure presentation and touches
	none of this.

	A SIBLING OF BlimpController, NOT PART OF IT. That module owns a MOUNT -- the helm axes, the pose,
	the camera, the three panels a pilot reads. This owns a prompt anyone standing on the ground can
	see on a hull they have never boarded, which is the opposite audience, and it shares no state with
	the mount path at all. Folding it in would have added a fourth concern to a module that is already
	the largest client file in the blimp feature.

	IT DOES NOT SEND ANYTHING. The prompts are real ProximityPrompts; the engine still delivers the
	press, and Server/Systems/BlimpSystem.lua still receives Triggered exactly as it did with the stock
	UI. Making them Style = Custom (done server-side, at the point the prompts are built) only stops
	Roblox drawing its own pill -- nothing about the interaction moves to the client. That matters: an
	input path that ran through this module would be a client deciding it had interacted with
	something, which is not how any other interaction in this codebase works.

	THE HOLD CLOCK IS LOCAL AND THAT IS THE ONLY HONEST OPTION. ProximityPromptService raises
	PromptButtonHoldBegan and PromptButtonHoldEnded and nothing in between -- there is no progress
	event -- so the bar is driven by wall-clock elapsed time against the prompt's own HoldDuration,
	which is the same number the engine is counting down. The two can only disagree if the frame rate
	collapses, and the engine's own Triggered is still what actually completes the hold, so a bar that
	reached 1.0 slightly early cannot trigger anything by itself.

	THE PROJECTION RUNS ONLY WHILE A PROMPT IS SHOWN. One RenderStepped connection, opened on
	PromptShown and closed on PromptHidden -- the same bounded-window discipline EmoteWheelClient keeps
	for its own mouse tracking, and for the same reason: a per-frame camera read that is live for a
	whole session to serve an interaction that happens twice a flight is exactly the always-on cost
	this project keeps refusing to pay.

	Does not own: the prompts themselves or what pressing them does (Server/Systems/BlimpSystem.lua),
	any pixel of the panel (UI/Screens/FurnacePrompt/init.lua), or what the press turned out to have
	done -- that answer arrives on the notification channel through Client/Blimp/BlimpController.lua's
	own onFuelTransfer, because an outcome is not a prompt.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Fusion = require(ReplicatedStorage.Packages.Fusion)

local BlimpConstants = require(ReplicatedStorage.Shared.Blimp.BlimpConstants)
local Logger = require(ReplicatedStorage.Shared.Logger)

local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local FurnacePromptModule = require(script.Parent.Parent.UI.Screens.FurnacePrompt)
local Surface = require(script.Parent.Parent.UI.Shell.Surface)

local peek = Fusion.peek

local logger = Logger.scope("FurnacePromptClient")

type FurnacePromptHandle = FurnacePromptModule.FurnacePromptHandle

local FurnacePromptClient = {}

local started = false
local handle: FurnacePromptHandle? = nil

-- The furnace part whose prompts are currently in range, or nil. Keyed by the PART rather than by a
-- prompt because the two prompts on it are one object to the player -- see UI/Screens/FurnacePrompt's
-- own header. Whichever of the pair is shown first opens the panel and the second is a no-op.
local shownPart: BasePart? = nil
-- How many of that part's prompts the engine currently has shown. Both go up and down independently
-- (they have different keys, so Exclusivity treats them separately), and the panel closes on the
-- second hide, not the first.
local shownCount = 0

local renderConnection: RBXScriptConnection? = nil

-- The ONE root viewport multiplier, handed in from UI.Mount rather than computed here -- see
-- Shell/Surface.lua's own header on why a second ViewportScale.Compute would be a second
-- ViewportSize connection. Peeked per frame while tracking, which is the cheap end of a Fusion value.
local viewportScale: Fusion.UsedAs<number>? = nil

-- os.clock() at PromptButtonHoldBegan, and the duration the engine is counting against. Both nil
-- while no hold is running.
local holdStartedAt: number? = nil
local holdDuration: number? = nil

local function isFurnacePrompt(prompt: ProximityPrompt): boolean
	local name = prompt.Name
	return name == BlimpConstants.Prompt.FuelPromptName or name == BlimpConstants.Prompt.UnloadPromptName
end

-- The load row names the LIVE Interact bind, because Client/Blimp/BlimpController.reKeyPrompt rewrites
-- that prompt's own KeyboardKeyCode to whatever the player rebound it to -- a legend naming E while
-- the prompt listens for something else is worse than no legend. The unload row is NOT rebindable
-- (see BlimpConstants.Prompt.UnloadKeyCode on why it is deliberately not an Interact-shaped action),
-- so it is read straight off the constant that the server built the prompt from.
local function refreshKeys(): ()
	local target = handle
	if not target then
		return
	end
	local bind = KeybindManager.Get("Interact")
	local loadKey = if bind.KeyCode then (bind.KeyCode :: Enum.KeyCode).Name else "Interact"
	target.SetKeys(loadKey, BlimpConstants.Prompt.UnloadKeyCode.Name)
end

-- Where the furnace is, in the panel's own coordinate space.
--
-- TWO CORRECTIONS, both of which are wrong to skip and invisible if you do. WorldToViewportPoint
-- reports below Roblox's top bar; every surface here sets IgnoreGuiInset = true, so its own (0, 0) is
-- the true top-left of the screen and the inset has to be ADDED back. (EmoteWheelClient makes the
-- same correction in the opposite direction, subtracting it from a viewport centre to reach a mouse
-- position -- same fact, other way round.) And the surface is scaled by the one root viewport scale,
-- so a raw pixel has to be divided by it to land on the right point.
--
-- Returns nil when the furnace is behind the camera or off screen, which is the panel's cue to hide
-- rather than to draw itself pinned to an edge.
local function projectToPanelSpace(part: BasePart, scale: number): Vector2?
	local camera = Workspace.CurrentCamera
	if not camera or scale <= 0 then
		return nil
	end
	local point, onScreen = camera:WorldToViewportPoint(part.Position)
	if not onScreen or point.Z <= 0 then
		return nil
	end
	local inset = Surface.TopBarInset()
	return Vector2.new(point.X / scale, (point.Y + inset) / scale)
end

local function stopTracking(): ()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

local function closePanel(): ()
	stopTracking()
	shownPart = nil
	shownCount = 0
	holdStartedAt = nil
	holdDuration = nil

	local target = handle
	if target then
		target.SetHoldProgress(0)
		target.SetVisible(false)
	end
end

-- Elapsed / duration, clamped -- see this file's header on why the clock is local. Returns 0 while no
-- hold is running, which is also what the panel reads as "fade the bar out".
local function holdProgress(now: number): number
	local startedAt = holdStartedAt
	local duration = holdDuration
	if not startedAt or not duration or duration <= 0 then
		return 0
	end
	return math.clamp((now - startedAt) / duration, 0, 1)
end

local function startTracking(part: BasePart): ()
	stopTracking()
	renderConnection = RunService.RenderStepped:Connect(function()
		local target = handle
		local scale = viewportScale
		if not target or not scale then
			return
		end
		local point = projectToPanelSpace(part, peek(scale))
		if not point then
			-- Hidden rather than closed: the prompts are still in range and the engine has not raised
			-- PromptHidden, the player has merely turned their back on the furnace. Closing here would
			-- drop the tracking connection that is about to be needed again the moment they turn round.
			target.SetVisible(false)
			return
		end
		target.SetPosition(point)
		target.SetHoldProgress(holdProgress(os.clock()))
		target.SetVisible(true)
	end)
end

local function onPromptShown(prompt: ProximityPrompt): ()
	if not isFurnacePrompt(prompt) then
		return
	end
	local part = prompt.Parent
	if not part or not part:IsA("BasePart") then
		return
	end

	if shownPart == part then
		shownCount += 1
		return
	end
	-- A different furnace while one is already up: the player walked from one hull to another without
	-- the first raising PromptHidden yet. The newer one wins outright rather than being queued -- it is
	-- the one they are standing at.
	shownPart = part
	shownCount = 1
	refreshKeys()
	return
end

local function onPromptHidden(prompt: ProximityPrompt): ()
	if not isFurnacePrompt(prompt) then
		return
	end
	if shownPart == nil or prompt.Parent ~= shownPart then
		return
	end
	shownCount -= 1
	if shownCount > 0 then
		return
	end
	closePanel()
end

local function onHoldBegan(prompt: ProximityPrompt): ()
	if prompt.Name ~= BlimpConstants.Prompt.UnloadPromptName then
		return
	end
	holdStartedAt = os.clock()
	-- Read off the prompt rather than off the constant it was built from: the prompt is the thing the
	-- engine is actually counting against, and a hull whose builder overrode it would otherwise get a
	-- bar that finished at a different moment than the trigger did.
	holdDuration = prompt.HoldDuration
end

local function onHoldEnded(prompt: ProximityPrompt): ()
	if prompt.Name ~= BlimpConstants.Prompt.UnloadPromptName then
		return
	end
	holdStartedAt = nil
	holdDuration = nil
	local target = handle
	if target then
		target.SetHoldProgress(0)
	end
end

function FurnacePromptClient.Start(promptHandle: FurnacePromptHandle, scale: Fusion.UsedAs<number>): ()
	if started then
		return
	end
	started = true
	handle = promptHandle
	viewportScale = scale
	refreshKeys()

	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		onPromptShown(prompt)
		if shownPart then
			startTracking(shownPart :: BasePart)
		end
	end)
	ProximityPromptService.PromptHidden:Connect(onPromptHidden)
	ProximityPromptService.PromptButtonHoldBegan:Connect(onHoldBegan)
	ProximityPromptService.PromptButtonHoldEnded:Connect(onHoldEnded)
	-- A completed hold ends the bar the same way an abandoned one does. Without this the fill would
	-- sit at 1.0 until the prompt hid, which reads as a hold still in progress after it has already
	-- paid out.
	ProximityPromptService.PromptTriggered:Connect(onHoldEnded)

	-- A rebind of Interact moves the LOAD prompt's own KeyboardKeyCode (BlimpController.reKeyPrompt),
	-- and this legend has to move with it -- KeybindManager.OnChanged's own header calls a legend
	-- built once at mount and never updated the exact gap it exists to close. The unsubscribe it
	-- returns is discarded deliberately: this module lives for the whole client session, the same
	-- posture every other consumer of that signal takes.
	KeybindManager.OnChanged(refreshKeys)

	-- A furnace whose hull is destroyed mid-prompt never raises PromptHidden -- the prompt goes with
	-- it. Without this the panel would hang wherever it last projected, tracking a part that no longer
	-- has a position. Rebuilt on the player's own body rather than on the hull because a destroyed
	-- hull is not the only way to end up here (falling off one, dying at the furnace) and a new
	-- character is proof every prompt that was up is over.
	Players.LocalPlayer.CharacterAdded:Connect(closePanel)

	logger:info("FurnacePromptClient.Start() complete")
end

return FurnacePromptClient
