--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local DomainTypes = require(ReplicatedStorage.Shared.Domain.DomainTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local ProjectileTypes = require(ReplicatedStorage.Shared.HitboxEngine.ProjectileTypes)
local MoveRegistryManager = require(ServerScriptService.Server.Combat.MoveRegistryManager)

local Screens = StarterPlayer.StarterPlayerScripts.Client.UI.Screens
local MoveEditor = require(Screens.DevTools.MoveEditor)
local Copy = require(Screens.DevTools.MoveEditor.Copy)

local peek = Fusion.peek

-- The Move Editor's structure as a move's TYPE reshapes it (MoveEditor/init.lua's header): which tabs a
-- melee move, a projectile and a domain expansion are offered, that the type bar's edit is exactly the
-- blocks, that a page is built only once its tab is shown -- and, by visiting every tab of every type, that
-- every page and every section of it constructs. Structure only: a headless place resolves no geometry.

local function fakePlayerGui(): PlayerGui
	return Instance.new("Folder") :: any
end

local function move(overrides: { [string]: any }?): MoveTypes.MoveDefinition
	local candidate: { [string]: any } = {
		MoveId = "spec-screen-move",
		DisplayName = "Spec",
		Author = "Spec",
		CreatedAt = 1,
		UpdatedAt = 1,
		Shape = "Box",
		Dimensions = { Width = 4, Height = 5, Length = 5 },
		OffsetX = 0,
		OffsetY = 0,
		OffsetZ = -3,
		WindupSeconds = 0.3,
		ActiveSeconds = 0.2,
		RecoverySeconds = 0.3,
		Cooldown = 0.8,
		Damage = 10,
		PostureDamage = 8,
	}
	for key, value in pairs(overrides or {}) do
		candidate[key] = value
	end
	return MoveRegistryManager.Validate(candidate) :: MoveTypes.MoveDefinition
end

local function realm(): DomainTypes.DomainSpec
	local spec = DomainTypes.Defaults()
	table.insert(spec.Effects, DomainTypes.DefaultEffect())
	table.insert(spec.Rules, DomainTypes.DefaultRule())
	local override = DomainTypes.DefaultClashOverride()
	override.OpponentMoveId = "some-other-realm"
	table.insert(spec.ClashOverrides, override)
	return spec
end

local DOMAIN_ONLY = { "Realm", "Boundary", "Effects", "Law", "Clash" }
local VOLUME_ONLY = { "Hitbox", "Impact" }
local SHARED = { "Timing", "Presentation", "Identity", "Tools" }
-- The ScrollArea each tab's page is named (its module's Fields.Page call).
local PAGE_NAMES: { [string]: string } = {
	Hitbox = "HitboxTab",
	Realm = "RealmTab",
	Boundary = "BoundaryTab",
	Effects = "EffectsTab",
	Law = "LawTab",
	Clash = "ClashTab",
	Timing = "TimingTab",
	Impact = "ImpactTab",
	Presentation = "PresentationTab",
	Identity = "IdentityTab",
	Tools = "ToolsTab",
}

return function()
	local function mount(): (any, Folder)
		local parent = fakePlayerGui()
		local handle = MoveEditor.Mount(Fusion.scoped(Fusion), parent)
		return handle, parent :: any
	end

	local function pageOf(parent: Instance, tab: string): Instance?
		return parent:FindFirstChild(PAGE_NAMES[tab], true)
	end

	-- A tab is on offer when asking for it shows it, rather than the first tab that is on offer.
	local function offers(handle: any, tab: string): boolean
		handle.CurrentTab:set(tab)
		return peek(handle.ShownTab) == tab
	end

	describe("the move type", function()
		it("is read off the blocks the move carries", function()
			expect(MoveEditor.MoveTypeOf(move())).to.equal("Melee")
			local shot = move()
			MoveEditor.SetMoveType(shot, "Projectile")
			expect(MoveEditor.MoveTypeOf(shot)).to.equal("Projectile")
			local cast = move()
			MoveEditor.SetMoveType(cast, "Domain")
			expect(MoveEditor.MoveTypeOf(cast)).to.equal("Domain")
		end)

		it("drops the other type's block and any grab when it is set", function()
			local subject = move()
			subject.Grab = {} :: any
			MoveEditor.SetMoveType(subject, "Projectile")
			expect(subject.Projectile).to.be.ok()
			expect(subject.Grab).to.equal(nil)

			MoveEditor.SetMoveType(subject, "Domain")
			expect(subject.Domain).to.be.ok()
			expect(subject.Projectile).to.equal(nil)

			MoveEditor.SetMoveType(subject, "Melee")
			expect(subject.Domain).to.equal(nil)
			expect(subject.Projectile).to.equal(nil)
		end)

		it("keeps a block that is already there when its own type is chosen again", function()
			local subject = move()
			MoveEditor.SetMoveType(subject, "Domain")
			local block = subject.Domain;
			(block :: any).Radius = 50
			MoveEditor.SetMoveType(subject, "Domain")
			expect(subject.Domain).to.equal(block)
		end)

		it("leaves a realm move an engine definition that samples no volume", function()
			local subject = move()
			MoveEditor.SetMoveType(subject, "Domain")
			local definition = MoveTypes.ToEngineAttackDefinition(subject)
			expect(definition.Volumeless).to.equal(true)
		end)
	end)

	describe("the tabs on offer", function()
		it("gives a melee move Hitbox and Impact and none of a realm's", function()
			local handle = mount()
			handle.Draft:set(move())
			for _, tab in VOLUME_ONLY do
				expect(offers(handle, tab)).to.equal(true)
			end
			for _, tab in DOMAIN_ONLY do
				expect(offers(handle, tab)).to.equal(false)
			end
			for _, tab in SHARED do
				expect(offers(handle, tab)).to.equal(true)
			end
		end)

		it("gives a domain expansion its five tabs instead of Hitbox and Impact, and keeps the rest", function()
			local handle = mount()
			handle.Draft:set(move({ Domain = realm() }))
			expect(peek(handle.IsDomain)).to.equal(true)
			for _, tab in DOMAIN_ONLY do
				expect(offers(handle, tab)).to.equal(true)
			end
			for _, tab in VOLUME_ONLY do
				expect(offers(handle, tab)).to.equal(false)
			end
			for _, tab in SHARED do
				expect(offers(handle, tab)).to.equal(true)
			end
		end)

		it("moves off a tab the move stops having", function()
			local handle = mount()
			handle.Draft:set(move())
			handle.CurrentTab:set("Impact")
			handle.EditDraft(function(draft)
				MoveEditor.SetMoveType(draft, "Domain")
			end)
			expect(peek(handle.ShownTab)).to.equal("Realm")
			-- And back: the author's place returns with the tab.
			handle.EditDraft(function(draft)
				MoveEditor.SetMoveType(draft, "Melee")
			end)
			expect(peek(handle.ShownTab)).to.equal("Impact")
		end)
	end)

	describe("building", function()
		it("builds no page until its tab is first shown, and keeps it after", function()
			local handle, parent = mount()
			handle.Draft:set(move())
			expect(pageOf(parent, "Hitbox")).to.be.ok()
			expect(pageOf(parent, "Timing")).to.equal(nil)
			handle.CurrentTab:set("Timing")
			expect(pageOf(parent, "Timing")).to.be.ok()
			handle.CurrentTab:set("Hitbox")
			expect(pageOf(parent, "Timing")).to.be.ok()
		end)

		it("builds every page of a melee move, a projectile and a domain expansion", function()
			local subjects = {
				move(),
				move({ Projectile = ProjectileTypes.Defaults() }),
				move({ Domain = realm() }),
			}
			for _, subject in subjects do
				local handle, parent = mount()
				handle.Draft:set(subject)
				for tab in PAGE_NAMES do
					if offers(handle, tab) then
						expect(pageOf(parent, tab)).to.be.ok()
					end
				end
			end
		end)

		it("builds a realm's effect slot only once the slot exists", function()
			local handle, parent = mount()
			handle.Draft:set(move({ Domain = realm() }))
			handle.CurrentTab:set("Effects")
			local page = pageOf(parent, "Effects") :: Instance
			local function bodyOf(index: number): Instance
				local section = page:FindFirstChild(`Section_EFFECT {index}`, true) :: Instance
				return section:FindFirstChild("Body") :: Instance
			end
			-- Slot 1 exists and is built; slot 2 does not exist yet and holds only its layout.
			expect(#bodyOf(1):GetChildren() > 1).to.equal(true)
			expect(#bodyOf(2):GetChildren()).to.equal(1)

			handle.EditDraft(function(draft)
				table.insert((draft.Domain :: any).Effects, DomainTypes.DefaultEffect())
			end)
			expect(#bodyOf(2):GetChildren() > 1).to.equal(true)
		end)
	end)

	describe("refusals", function()
		it("point a realm at the tab its field is on", function()
			local damage = Copy.Failure("InvalidDamage")
			expect(Copy.FailureTab(damage, false)).to.equal("Impact")
			expect(Copy.FailureTab(damage, true)).to.equal("Effects")
			local rule = Copy.Failure("InvalidDomainRule")
			expect(Copy.FailureTab(rule, true)).to.equal("Law")
		end)

		it("never name the retired Domain tab", function()
			for _, reason in
				{
					"InvalidDomain",
					"InvalidDomainEffect",
					"InvalidDomainRule",
					"InvalidDomainClash",
					"DomainEffectNeedsMove",
					"DomainRuleNeedsMove",
					"DomainSelfReference",
					"DomainCannotGrab",
				}
			do
				local failure = Copy.Failure(reason)
				expect(failure.Tab).never.to.equal("Domain")
				expect(PAGE_NAMES[Copy.FailureTab(failure, true) :: string]).to.be.ok()
			end
		end)
	end)
end
