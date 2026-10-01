--!strict
--[[
	GrabInputClient.lua

	Owns: the LOCAL player's grab-throw input -- the GrabThrow key edge, sent only while this client
	can already see a hold is in progress -- and a small on-screen cue for both roles a hold can put a
	player in ("HOLDING -- [G] to throw" for the attacker, "GRABBED" for the victim).

	Same shape as Client/Combat/AttackInputClient.lua: DECIDES NOTHING about whether a throw is legal.
	Server/Combat/Grab/GrabSystem.lua is the sole authority on holds, throws and impacts; this module
	sends the press and presents whatever GrabSystem.Grab_HoldChanged says happened.

	THE ONE CLIENT-SIDE FILTER THIS MODULE APPLIES IS HONEST, not a guess. It declines to send
	Grab_Throw unless the local player's own Constants.Attributes.Grabbing Attribute is true -- the
	same "the client declines to send what it can already see is illegal" convention Shared/Parkour/
	ParkourOwnership.OwnsBody's own consumers already use. That Attribute is server-written and
	replicated, so this is not a prediction of server state, it is a read of it: a press sent while
	Grabbing is false would always be refused ("NotHolding") server-side regardless, so filtering it
	here costs nothing and saves a wasted round trip.

	NOT BUILT THROUGH UI/Shell/Surface.lua, WHICH IS THE ONE EXEMPTION IN THE CLIENT. Every other
	ScreenGui in the tree comes from that factory as of Phase 2 of
	docs/architecture/2026-08-25-hud-shell-plan.md; Surface.New takes a Fusion scope, and this module
	has none -- see the paragraph below on why the cue is hand-built Instances. Creating a Fusion scope
	here purely to satisfy a factory would mean a session-long root scope in a combat input module, for
	one TextLabel. What it DOES take from Shell is the band: DisplayOrder is Layers.Overlay, not the
	bare 5 it used to carry, so this cue is on the same ladder as everything else and the "no raw
	DisplayOrder literals outside Layers.lua" assertion in Tests/UI/ShellLayers.spec.lua holds across
	the whole client rather than across most of it.

	It keeps IgnoreGuiInset = true by hand for the same reason Surface sets it everywhere -- one
	coordinate space -- and it is unscaled, which is correct rather than an omission: it is one line of
	centred text at 0.28 of the screen height, positioned by scale rather than by offset.

	This surface was NOT in the hud-shell plan's count of seventeen. It is the eighteenth, missed
	because it is the only one built with Instance.new rather than scope:New and so does not match the
	grep the audit was built from.

	THE CUE IS DELIBERATELY A PLAIN Instance-built ScreenGui, not a Screens/ Fusion component. Every
	other panel in this codebase's UI lives behind Client/UI/init.lua's session-long Fusion mount and
	its own uiHandles plumbing -- machinery sized for a real panel (a settings screen, a move editor, a
	whole HUD). A hold's cue is one line of text that toggles on and off with a boolean; wiring it
	through that system would be adding a Screen to grow a caption. If this cue ever needs to become
	richer (a countdown ring for the hold's own timer, an icon), THAT is the point to promote it into
	Screens/ -- not before.

	Does not own: whether a hold/throw is legal (GrabSystem), the hold/flight state machine itself, or
	the ordinary attack input this module sits next to (AttackInputClient.lua).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local GrabConstants = require(ReplicatedStorage.Shared.Grab.GrabConstants)
local GrabTypes = require(ReplicatedStorage.Shared.Grab.GrabTypes)
local Logger = require(ReplicatedStorage.Shared.Logger)
local PlayerLifecycle = require(ReplicatedStorage.Shared.PlayerLifecycle)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)

local Glyph = require(script.Parent.Parent.Input.Glyph)
local InputDevice = require(script.Parent.Parent.Input.InputDevice)
local KeybindManager = require(script.Parent.Parent.Input.KeybindManager)
local Layers = require(script.Parent.Parent.UI.Shell.Layers)

local logger = Logger.scope("GrabInputClient")

local GrabInputClient = {}

local started = false
local throwRemote: RemoteEvent? = nil
local boundHumanoid: Humanoid? = nil

-- Cue --------------------------------------------------------------------------------------------

local cueLabel: TextLabel? = nil

-- Built once, lazily, the first time a cue actually needs to show -- most players never grab or get
-- grabbed in a given life, and paying for a ScreenGui/TextLabel pair nobody ever sees would be waste
-- on every single client.
local function ensureCue(): TextLabel
	local label = cueLabel
	if label then
		return label
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GrabCue"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = Layers.Overlay

	local newLabel = Instance.new("TextLabel")
	newLabel.Name = "Cue"
	newLabel.AnchorPoint = Vector2.new(0.5, 0)
	newLabel.Position = UDim2.fromScale(0.5, 0.28)
	newLabel.Size = UDim2.fromOffset(320, 32)
	newLabel.BackgroundTransparency = 1
	newLabel.Font = Enum.Font.GothamBold
	newLabel.TextSize = 20
	newLabel.TextColor3 = Color3.fromRGB(255, 235, 200)
	newLabel.TextStrokeTransparency = 0.4
	newLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	newLabel.Text = ""
	newLabel.Visible = false
	newLabel.Parent = gui

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	cueLabel = newLabel
	return newLabel
end

local function setCue(text: string?): ()
	local label = ensureCue()
	if text then
		label.Text = text
		label.Visible = true
	else
		label.Visible = false
	end
end

-- What to call the throw key in the attacker's cue, resolved when the cue shows rather than written
-- into it: the cue used to say "[G]" unconditionally, which was wrong for anyone who had rebound
-- GrabThrow and for every gamepad player (theirs is a chord -- see Glyph.Resolve). Glyph answers with
-- an image id for a plain gamepad button, which a one-line TextLabel cannot draw, so that case falls
-- back to the binding's text name.
local function throwKeyLabel(): string
	local glyph = Glyph.Resolve("GrabThrow", InputDevice.Current())
	if glyph.Kind == "Text" then
		return glyph.Value
	end
	return KeybindManager.Describe(KeybindManager.GetGamepad("GrabThrow"))
end

-- Sending -------------------------------------------------------------------------------------------

local function requestThrow(): ()
	local humanoid = boundHumanoid
	if not humanoid or humanoid:GetAttribute(Constants.Attributes.Grabbing) ~= true then
		-- Not currently holding anyone, as far as this client can already see -- see file header on
		-- why this is a read of replicated server state rather than a guess.
		return
	end
	local remote = throwRemote
	if not remote then
		logger:warn("Grab throw pressed before the throw remote was ready")
		return
	end
	remote:FireServer()
end

-- True while any modal UI panel is up (Components/ModalScreen.lua publishes the count as
-- Constants.Attributes.UiModalOpen -- see that constant's own comment). Roblox's own
-- gameProcessedEvent only covers clicks that LAND on the GUI, and a centred 760x620 panel leaves
-- most of the viewport uncovered, so a player reading their character sheet was still throwing a
-- punch every time they clicked anywhere else on screen.
local function isModalUiOpen(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute(Constants.Attributes.UiModalOpen) == true
end

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	if gameProcessed then
		return
	end
	-- Same gate AttackInputClient holds, for the same reason -- see isModalUiOpen above. A throw is
	-- an attack as far as a player clicking inside their own menu is concerned.
	if isModalUiOpen() then
		return
	end
	if KeybindManager.Matches("GrabThrow", input) then
		requestThrow()
	end
end

-- Presentation ---------------------------------------------------------------------------------------

local function onHoldChanged(raw: unknown): ()
	if typeof(raw) ~= "table" then
		return
	end
	local payload = raw :: GrabTypes.GrabHoldChangedPayload
	if payload.Role ~= "Attacker" and payload.Role ~= "Victim" then
		return
	end

	if not payload.Active then
		setCue(nil)
		return
	end

	if payload.Role == "Attacker" then
		setCue(`HOLDING -- [{string.upper(throwKeyLabel())}] TO THROW`)
	else
		setCue("GRABBED")
	end
end

-- Throw rooting --------------------------------------------------------------------------------------

-- The client half of rooting a thrower for their throw clip (Constants.Attributes.GrabThrowing, written
-- by GrabSystem). The server pins WalkSpeed and parks parkour and shift lock's yaw; what only the client
-- that simulates this body can stop is the engine's own jump and its turn-to-face-movement. Jump goes
-- through the Humanoid's Jumping state, the switch AttackInputClient already uses for the launcher
-- window; AutoRotate is captured and put back only if nothing else changed it meanwhile, SwingTracking's
-- rule.
local restoreAutoRotate: boolean? = nil

local function setThrowRooted(humanoid: Humanoid, rooted: boolean): ()
	if rooted then
		if restoreAutoRotate == nil then
			restoreAutoRotate = humanoid.AutoRotate
		end
		humanoid.AutoRotate = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		return
	end
	if restoreAutoRotate == true and humanoid.AutoRotate == false then
		humanoid.AutoRotate = true
	end
	restoreAutoRotate = nil
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
end

-- Lifecycle ------------------------------------------------------------------------------------------

function GrabInputClient.Start(): ()
	if started then
		return
	end
	started = true

	throwRemote = NetworkBridge.GetRemoteEvent(GrabConstants.Network.RemoteNames.Throw)

	local holdChangedRemote = NetworkBridge.GetRemoteEvent(GrabConstants.Network.RemoteNames.HoldChanged)
	holdChangedRemote.OnClientEvent:Connect(onHoldChanged)

	UserInputService.InputBegan:Connect(onInputBegan)

	-- The Humanoid wait, the boot-thread task.spawn and the no-Humanoid warning all live in
	-- Shared/PlayerLifecycle.lua now -- this module's own comment about all three used to be one of
	-- the fifteen byte-identical copies of it. See that module's header.
	PlayerLifecycle.BindLocalCharacter({
		Scope = "GrabInputClient",
		OnCharacter = function(_character: Model, humanoid: Humanoid, life)
			boundHumanoid = humanoid
			-- A new life is never mid-hold -- GrabSystem's own Players.PlayerRemoving/Step sweeps
			-- already cleared any hold this player was part of when the previous character ended.
			setCue(nil)
			-- A fresh Humanoid starts with its own defaults, so nothing from the last life is restored.
			restoreAutoRotate = nil
			local throwing = Constants.Attributes.GrabThrowing
			life:Connect(humanoid:GetAttributeChangedSignal(throwing), function()
				setThrowRooted(humanoid, humanoid:GetAttribute(throwing) == true)
			end)
			if humanoid:GetAttribute(throwing) == true then
				setThrowRooted(humanoid, true)
			end
		end,
		OnCharacterRemoving = function()
			boundHumanoid = nil
			setCue(nil)
		end,
	})

	logger:info("GrabInputClient started")
end

return GrabInputClient
