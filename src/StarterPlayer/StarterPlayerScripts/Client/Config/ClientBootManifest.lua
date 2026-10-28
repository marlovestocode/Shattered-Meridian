--!strict
--[[
	ClientBootManifest.lua

	Owns: the declared answer to "what is this client supposed to have started", and the check that catches it drifting -- the
	client's counterpart of Server/Config/BootManifest.lua (coworking plan F10, W18).

	THE ORDER STAYS IN Main.client.lua, for the reason the server manifest gives: the boot order there is documented line by line
	(each comment states the dependency it satisfies), and turning it into a data table would delete the part that matters. What
	that file could not do is notice a module dropped from it, or a new module with a Start nobody calls. So:

	  * BOOTED lists every module Main.client.lua starts through its `boot(name, ...)` helper, which calls MarkBooted. The end of
	    boot calls Missing() and logs each one that never reported -- a module renamed or dropped from Main, found at once rather
	    than as a feature that silently never runs.
	  * STARTED_BY lists every module whose Start is called by ANOTHER module (an owner starts its parts), with that owner.
	  * scripts/check-client-boot.py holds the three files to account: every client module with a `function X.Start(` is in exactly
	    one of the two lists, every BOOTED name is booted by Main.client.lua, and every STARTED_BY owner really calls `X.Start`.

	OPTIONAL entries are absent from some builds by design (DevTools: live.project.json omits it, and Main.client.lua's DevTools
	seam is a FindFirstChild). Missing() never reports them.
]]

local ClientBootManifest = {}

ClientBootManifest.Booted = table.freeze({
	"MovePresentationCatalog",
	"EmoteController",
	"EmoteWheelClient",
	"FOVOffset",
	"CameraOffsetComposer",
	"CameraFollow",
	"CombatCamera",
	"FlightCamera",
	"CameraShake",
	"CameraRotationComposer",
	"CameraMotion",
	"ParkourController",
	"RunController",
	"DefenseClient",
	"AttackInputClient",
	"WeaponInventoryClient",
	"GrabInputClient",
	"SwingRootClient",
	"AirComboClient",
	"AirComboFX",
	"BlimpController",
	"FurnacePromptClient",
	"BoatController",
	"SwingLunge",
	"LockOnController",
	"SwingTracking",
	"SwingTellFX",
	"SwingTrail",
	"ProjectileFX",
	"DomainFX",
	"CombatAudio",
	"SwingPresentation",
	"RollAfterimage",
	"RemoteMovementFX",
	"GuardStrainPose",
	"EnvironmentFX",
	"HitFlinchPose",
	"GrabHoldPose",
	"CombatFeedbackClient",
	"HitPrediction",
	"DeathNoticeClient",
	"FpsCounter",
	"DevTools",
	"CharacterMenuClient",
	"InventoryClient",
	"BugReportClient",
	"AnnouncementClient",
	"SettingsClient",
	"FlightController",
})

ClientBootManifest.Optional = table.freeze({
	DevTools = "omitted from live.project.json; Main.client.lua resolves it with FindFirstChild",
})

-- Module -> the module whose own Start starts it.
ClientBootManifest.StartedBy = table.freeze({
	ParkourInput = "ParkourController",
	ParkourDebug = "ParkourController",
	ParkourNetwork = "ParkourController",
	BlimpAudio = "BlimpController",
	BlimpWindVFX = "BlimpController",
	DevMenuClient = "DevTools",
	KitEditorClient = "DevTools",
	WorldArchitectClient = "DevTools",
	EditorViewport = "WorldArchitectClient",
	LiveConsoleClient = "DevTools",
	MoveEditorClient = "DevTools",
	PingProbe = "DevTools",
	StorybookClient = "DevTools",
	SpectateController = "DevMenuClient",
	ClipScrubber = "MoveEditorClient",
	HitboxWorldPreview = "MoveEditorClient",
	PlacementCamera = "HitboxWorldPreview",
})

local booted: { [string]: boolean } = {}

-- Called by Main.client.lua's boot helper after a module's Start returns (or throws: a module that failed to start was still
-- reached, and its error is already logged).
function ClientBootManifest.MarkBooted(name: string): ()
	booted[name] = true
end

-- Every BOOTED name that never reported, minus the optional ones that are absent from this build.
function ClientBootManifest.Missing(): { string }
	local missing: { string } = {}
	for _, name in ClientBootManifest.Booted do
		if not booted[name] and ClientBootManifest.Optional[name] == nil then
			table.insert(missing, name)
		end
	end
	return missing
end

return ClientBootManifest
