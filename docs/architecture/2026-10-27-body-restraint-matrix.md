# Body restraint matrix (W9, 2026-10-27)

`Shared/Combat/BodyRestraint.lua` owns "may this body *verb* now" for every restraint that lives on a Humanoid Attribute.
This is its policy table as a matrix, read from source before the conversion and proven equal after it
(`Tests/Combat/BodyRestraint.spec.lua` runs each removed predicate against its verb over all 512 flag combinations, plus the
air-hold, realm and death cases). **No answer changed.** Every blank below is either *deliberate* (with the reason) or an
**escalation**: a gap nobody wrote down a reason for, left as it was, for the user to decide.

Order matters: a verb's first matching restraint is its refusal reason, as each consumer returned it.

| Verb (consumer) | Frozen | Grabbed | Grabbing | GrabThrowing | Mounted | Flying | RootLocked | SwingRooted | EmoteLocked | AirHeld / AirParticipant | Realm | Dead |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Swing** (`AttackRequestSystem.bodyGate` tail) | 2 | via GrabSystem.CanAttack | via GrabSystem.CanAttack | via GrabSystem | 1 | **E1** | — d1 | — d1 | **E2** | via AirComboSystem.CanAttack | seals via `DomainRules.IsSealed` | `isAlive` before |
| **Guard** (DefenseSystem press) | 1 | E3 | E3 | | via GuardRequest | E1 | | | E2 | held-in-stun rule | NoBlock/NoParry in resolve | |
| **GuardRequest** (SetBlocking remote) | | | | | 1 | | | | | | | |
| **Evade** (`evadeBodyRefusal`) | 4 | 1 "Restrained" | 2 "Restrained" | **E3** | 3 "Restrained" | E1 | — d1 | — d1 | E2 | 5 AirHeld | 6 NoEvade "DomainSealed" | |
| **Move** (RunSystem WalkSpeed pin) | 1 | 4 | | 5 | 6 | 2 | — d2 | 7 | 3 | — d3 | Rooted, per tick in RunSystem | |
| **Parkour** (`ParkourOwnership.HeldElsewhere`) | 3 | — d4 | — d4 | — d4 | **E4** | 2 | 1 | — d5 | 4 | 5 AirParticipant | 6 Rooted | 7 |
| **LocalSwing** (AttackInputClient) | **E5** | 2 | 3 | | 1 | | | | | | | client checks Health first |
| **Emote** (EmoteSystem, EmoteWheelClient) | E6 | E6 | E6 | | 1 | E6 | | | | | | |
| **LockOn** (LockOnController) | | | | | 2 | 3 | | | | | | 1 |
| **Judge** (MovementGuard "ServerHeld") | | 2 | | | 3 | 4 | 1 | | | | | "Dead" before |
| **Launch** (AirComboSystem) | | 1 | 2 | | 3 | | | | | | | |
| **CameraMotion** (`Client/Camera/CameraMotion`, added 2026-10-27, new rather than converted) | 5 | 4 | | | 1 | 2 | 3 | | | — d6 | | `Health` check in the reader |

**Deliberate blanks**
- d1. A root lock or a swing root is the attacker's *own* swing or a stun the record gates already answer.
- d2. RootControl holds the root physically; WalkSpeed has nothing to add.
- d3. The air combo pins the body through its own hold, not WalkSpeed.
- d4. A grab sets RootControlLocked on the victim (row 1), and the holder's throw clip is RootLocked too.
- d5. A swing root ends before a traversal could start; `CombatHeld` parks parkour while combat owns the body.
- d6. An air-combo hold is a lease, which a change-driven mirror cannot watch; the held body is stationary, so the camera has
  nothing to react to. A swing root, an emote lock and a stun are the body's own motion, not another system moving it.

**Escalations (left as they are; the user decides)**
- **E1. A flying body may swing, guard and evade.** Flight is an admin grant (`AdminActionSystem.SetFlying`). Option A: add
  Flying to Swing/Guard/Evade (a flier cannot fight). Option B: keep it (an admin flier can spar). Effort S either way.
- **E2. An emote-locked body may swing, guard and evade.** The server cancels the emote on a combat press elsewhere? Not
  verified. Option A: add EmoteLocked to Swing/Evade so a locked emote must end first. Option B: keep it. Effort S.
- **E3. Guard and Evade read different grab flags.** Evade refuses Grabbed/Grabbing as "Restrained"; the guard press does not,
  and neither refuses GrabThrowing. Option A: add Grabbed/Grabbing/GrabThrowing to Guard and GrabThrowing to Evade. Effort S.
- **E4. Parkour does not refuse Mounted.** VesselMount's weld plus its own movement lock hold the body today, so the blank has no
  known symptom. Option A: add Mounted to the Parkour row so the rule does not depend on the weld. Effort S.
- **E5. The client sends a swing press from a frozen body** (the server refuses it as "Frozen"). Option A: add Frozen to
  LocalSwing to save the round trip. Effort S, no gameplay change.
- **E6. Emote refuses only Mounted on the server.** A frozen, grabbed or flying player can start an emote (CombatAllowed covers
  engagement, not restraints). Option A: add Frozen/Grabbed/Grabbing/Flying to Emote. Effort S.

**Readers outside the policy, by design** (`scripts/cohesion-report.py` `restraint_reads` lists each with its reason): the
Attribute writers themselves (GrabSystem, VesselMount, RootControl, FlightController), presentation that reads a flag to choose a
look (ShiftLockCamera, FlightCamera, the animators, MovementVFX -- these move with the camera/animation owners in W11), a bot's
perception (TrainingBotSystem), a debug label, KnockbackAudit's skip rule, ParkourMotor yielding to a root lock mid-drive, and
ParkourInput's mounted key routing (W12's Vehicle layer).

`Shared/Combat/FrozenBody.lua` is deleted: its two callers read the Frozen row now.

## Ragdolled (added 2026-10-27, design decision)

A twelfth flag restraint, `Ragdolled` (written only by `Server/Combat/Ragdoll/RagdollSystem`), appended LAST to the
Swing, Guard, Evade, Parkour, LocalSwing, Emote, Judge (as `ServerHeld`) and Launch rows, so no existing answer
changes. Not in Move or CameraMotion: the ragdoll also claims RootControl, whose RootLocked stands those down.
Pinned by the Ragdolled case in `Tests/Combat/BodyRestraint.spec.lua`. See
`docs/architecture/2026-10-27-ragdoll-and-hitstop.md`.
