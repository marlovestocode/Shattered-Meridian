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

local DOMAIN_ONLY = { "Realm" }
local VOLUME_ONLY = { "Hitbox", "Impact" }
local SHARED = { "Timing", "Presentation", "Identity", "Tools" }
-- The Realm tab's own pages, under its sub-tab bar.
local REALM_PAGES = { "Realm", "Boundary", "Effects", "Law", "Clash" }
-- The ScrollArea each page is named (its module's Fields.Page call). The Realm tab's own frame is
-- RealmPages; "Realm" here is its first page, the clock and cost.
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
local TOP_TABS = { "Hitbox", "Realm", "Timing", "Impact", "Presentation", "Identity", "Tools" }

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

		it("gives a domain expansion its Realm tab instead of Hitbox and Impact, and keeps the rest", function()
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
				for _, tab in TOP_TABS do
					if offers(handle, tab) then
						if tab == "Realm" then
							for _, page in REALM_PAGES do
								handle.ShowPage(page)
								expect(pageOf(parent, page)).to.be.ok()
							end
						else
							expect(pageOf(parent, tab)).to.be.ok()
						end
					end
				end
			end
		end)

		it("folds a realm's five pages under the Realm tab, built on first visit", function()
			local handle, parent = mount()
			handle.Draft:set(move({ Domain = realm() }))
			handle.ShowPage("Law")
			expect(peek(handle.ShownTab)).to.equal("Realm")
			expect(peek(handle.RealmPage)).to.equal("Law")
			expect(pageOf(parent, "Law")).to.be.ok()
			expect(pageOf(parent, "Clash")).to.equal(nil)
		end)

		it("builds a realm's effect slot only once the slot exists", function()
			local handle, parent = mount()
			handle.Draft:set(move({ Domain = realm() }))
			handle.ShowPage("Effects")
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
	describe("changed fields", function()
		local function openSaved(handle: any, saved: MoveTypes.MoveDefinition)
			handle.Entries:set({
				{
					Move = saved,
					Source = "Custom",
					Group = "Custom",
					SavedFingerprint = MoveTypes.Fingerprint(saved),
					Overridden = false,
					Shipped = false,
					Notes = {},
				},
			})
			handle.SelectedId:set(saved.MoveId)
			handle.Draft:set(MoveTypes.Clone(saved))
		end

		local function dotOf(parent: Instance, title: string): Instance
			local holder = parent:FindFirstChild(`Field_{title}`, true) :: Instance
			return holder:FindFirstChild("Changed") :: Instance
		end

		it("marks a field that differs from the saved move, and its dot puts the saved value back", function()
			local handle, parent = mount()
			openSaved(handle, move())
			handle.CurrentTab:set("Impact")
			local dot = dotOf(parent, "Damage") :: any
			expect(dot.Visible).to.equal(false)

			handle.EditDraft(function(draft)
				draft.Damage = 25
			end)
			expect(dot.Visible).to.equal(true)

			dot.Activated:Fire()
			expect((peek(handle.Draft) :: any).Damage).to.equal(10)
			expect(dot.Visible).to.equal(false)
		end)

		it("shows no dots for a move that was never saved", function()
			local handle = mount()
			handle.Draft:set(move())
			expect(peek(handle.SavedMove)).to.equal(nil)
		end)
	end)

	describe("hints", function()
		it("leaves hints to the help strip until Show hints is on", function()
			local handle, parent = mount()
			handle.Draft:set(move())
			handle.CurrentTab:set("Timing")
			local holder = parent:FindFirstChild("Field_Windup", true) :: Instance
			local function hintShown(): boolean
				for _, child in holder:GetDescendants() do
					if child:IsA("TextLabel") and (child :: any).Text == Copy.Hints.Windup then
						return (child :: any).Visible
					end
				end
				return false
			end
			expect(hintShown()).to.equal(false)
			handle.HintsShown:set(true)
			expect(hintShown()).to.equal(true)
		end)
	end)

	describe("the move list", function()
		it("steps the open move through the rows on show", function()
			local handle = mount()
			local first, second =
				move({ MoveId = "spec-a", DisplayName = "A" }), move({ MoveId = "spec-b", DisplayName = "B" })
			local function entry(subject: MoveTypes.MoveDefinition)
				return {
					Move = subject,
					Source = "Custom",
					Group = "Custom",
					SavedFingerprint = nil,
					Overridden = false,
					Shipped = false,
					Notes = {},
				}
			end
			handle.Entries:set({ entry(first), entry(second) })
			local asked: { string } = {}
			handle.SelectRequested:Connect(function(id: string)
				table.insert(asked, id)
			end)
			handle.StepSelection(1)
			expect(asked[1]).to.equal("spec-a")
			handle.SelectedId:set("spec-a")
			handle.StepSelection(1)
			expect(asked[2]).to.equal("spec-b")
		end)
	end)
end
