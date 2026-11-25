# Steam Multiplayer Kit for Godot 4

A documented, drop-in starting point for **Steam multiplayer in Godot 4** using the
[GodotSteam](https://godotsteam.com/) GDExtension: a host-authoritative listen server over Steam
P2P, with lobbies, spawning, replication, owner-side prediction and host-driven screen flow.

It ships three things:

- **GDScript templates** you copy into your project (autoloads, spawners, a networked player body,
  an NPC, a lobby screen and a loading gate).
- **Design docs**: the architecture, the requirements with acceptance checks, 19 reusable
  networking patterns, and 30 real bugs written up as symptom, cause and fix.
- **AI agent material**: a compact rules file and prompt templates, written so a coding agent
  (Claude Code or similar) can integrate and extend the kit without breaking its authority model.

The kit was extracted from a Godot game in development and generalized. See
[Verification status](#verification-status) before you rely on it.

---

## The model in five lines

1. **Host = peer 1** runs the only real simulation. Clients send input and requests; the host
   validates and broadcasts results with ordinary `@rpc`.
2. `SteamMultiplayerPeer` plugs Steam lobbies and networking into Godot's `MultiplayerAPI`.
   Gameplay code never sees Steam.
3. The **owning client predicts its own avatar's movement** and blends toward the host's
   snapshots. Everything else on clients is display-only.
4. **Solo is a session of one.** Same code; direct calls instead of `.rpc()`.
5. Anything a client needs on scene load is **client-requested with retry**, because an RPC to a
   node that doesn't exist yet is silently dropped.

## Requirements

| | Minimum | Tested with |
|---|---|---|
| Godot | 4.4 (the templates use typed `Dictionary[K, V]`) | 4.7.1 |
| GodotSteam | GDExtension build with `SteamMultiplayerPeer` (not the engine fork) | 4.21 |
| Steamworks SDK | bundled with GodotSteam | 1.65 |
| Steam | client running and logged in on every test machine | |

Testing real multiplayer needs **two machines with two Steam accounts**. Valve's public test App ID
`480` (Spacewar) works for development.

## What's in here

```
steam_multiplayer_kit/
├── README.md
├── LICENSE
├── .gdignore                      keeps Godot from importing the kit if you clone it into a project
├── docs/
│   ├── 01_ARCHITECTURE.md         model, layers, identity, authority matrix, message flows
│   ├── 02_REQUIREMENTS.md         FR-*/NFR-* with acceptance checks and verification status
│   ├── 03_IMPLEMENTATION_GUIDE.md empty project → two-player lobby, step by step with checks,
│   │                              plus an "adding any networked feature" recipe
│   ├── 04_PATTERNS.md             P1–P19: the reusable networking shapes and their rules
│   ├── 05_PITFALLS.md             30 real bugs: symptom → cause → fix, with a symptom index
│   ├── 06_TESTING_DEBUGGING.md    two-machine test matrix, logs, playbook, static checklist
│   └── 07_STEAM_API_REFERENCE.md  every GodotSteam call used, confidence, release checklist
├── ai/
│   ├── multiplayer_rules.md       compact Must/Never rules for a coding agent's rules folder
│   └── PROMPTS.md                 prompt templates: integrate, add feature, debug, review
└── templates/                     mirrors a project root; copy straight in
    ├── project.godot.snippet      autoloads (ordered) and file logging
    ├── gitignore.snippet
    └── scripts/
        ├── boot.gd                main scene: Steam init → first screen (+ invite launch)
        ├── autoload/
        │   ├── net_log.gd         leveled, categorized, peer-tagged logging
        │   ├── steam_manager.gd   Steam init + is_available
        │   ├── steam_network.gd   lobby host/join/leave, peer bridge, session/authority helpers
        │   └── scene_router.gd    screen flow for everyone, round/match state
        ├── net/
        │   ├── net_retry.gd           request-until-acknowledged helper
        │   ├── net_player_spawner.gd  one avatar per peer, client-requested, late-join catch-up
        │   ├── net_entity_spawner.gd  host-owned populations: live + catch-up + dedupe
        │   ├── net_player_body.gd     RigidBody3D: host sim, owner prediction, reconciliation,
        │   │                          input relay, request → validate → broadcast actions
        │   └── net_npc.gd             host AI, 15 Hz staggered broadcast, client interpolation
        └── screens/
            ├── lobby_screen.gd    code-built lobby UI (host/join/copy id/members/start/leave)
            └── loading_gate.gd    nobody enters gameplay until every peer has loaded
```

## Quick start

1. Install the **GodotSteam GDExtension** into `addons/godotsteam/` (AssetLib, or the release
   zip from GodotSteam).
2. Put a `steam_appid.txt` containing `480` at your project root, and gitignore it
   (`templates/gitignore.snippet` has the lines).
3. Copy `templates/scripts/` → `res://scripts/` and `docs/` → `res://docs/multiplayer/`.
   If you use a coding agent, copy `ai/multiplayer_rules.md` into its rules folder
   (for Claude Code: `.claude/rules/multiplayer.md`).
4. Merge `templates/project.godot.snippet` into your `project.godot`, keeping the four kit
   autoloads first and in order. Set `boot.tscn` (with `boot.gd`) as the main scene.
5. Point `SceneRouter.SCREEN_PATHS` at your scenes, and build the lobby, loading-gate and
   gameplay scenes as the guide describes.
6. Test solo, then host-only, then **two machines with two Steam accounts**.

Every step, with a check for each:
[docs/03_IMPLEMENTATION_GUIDE.md](docs/03_IMPLEMENTATION_GUIDE.md).

The template file headers carry `[Project Name]` and `[Author/Company]` placeholders. Replace them
with your own project's details when you copy the files in.

## Reading order

| You are… | Read |
|---|---|
| Setting up a new project | [`03_IMPLEMENTATION_GUIDE.md`](docs/03_IMPLEMENTATION_GUIDE.md) (it links out as needed) |
| Designing a new networked feature | [`01_ARCHITECTURE.md`](docs/01_ARCHITECTURE.md) §4–§5 → [`04_PATTERNS.md`](docs/04_PATTERNS.md) → the Recipe at the end of `03` |
| Debugging | [`05_PITFALLS.md`](docs/05_PITFALLS.md) symptom index → [`06_TESTING_DEBUGGING.md`](docs/06_TESTING_DEBUGGING.md) §4 |
| Reviewing a PR | `06_TESTING_DEBUGGING.md` §5 + [`ai/multiplayer_rules.md`](ai/multiplayer_rules.md) |
| An AI agent | `ai/multiplayer_rules.md` always; `04_PATTERNS.md` before writing; `05_PITFALLS.md` before debugging |

## Verification status

Read this before relying on any part of the kit.

| Layer | Status |
|---|---|
| **Architecture and patterns** | Proven in the source game across real two-machine Steam sessions (lobby, join, spawning, host-authoritative movement, a networked interaction flow, the round loop). Per-item status is in `02_REQUIREMENTS.md` and `05_PITFALLS.md`. |
| **Owner prediction/reconciliation, staggered NPC broadcast, loading gate** | Implemented in the source game, **not yet live-tested** there. Tuning values are reasoned, not measured. |
| **Templates** | Generalized rewrites of the source files. **Compiled and smoke-tested** (solo path, Steam unavailable) under Godot 4.7.1 + GodotSteam 4.21. **Never run as-is in a two-machine session.** Your first integration is their first live test. |
| **Overlay invites** (`join_requested`, `+connect_lobby`) | In the templates only (symbols confirmed to exist in GodotSteam 4.21). Not in the source game. Untested. |

Status markers used throughout the docs: ✅ verified live across two Steam instances ·
🟡 implemented, reasoned, not yet live-tested · ⬜ specified only.

## Known gaps

Not provided: host migration · reconnect after a drop · public matchmaking or a lobby browser ·
lag compensation · `MultiplayerSynchronizer` usage · voice or text chat · achievements,
leaderboards and cloud saves (pointers only, in `07` §6). See `02_REQUIREMENTS.md` §4.

## Differences from the source game

The templates improve on the game they came from where its own history showed a better shape:

| Change | Why |
|---|---|
| `SteamNetwork.has_active_session()` / `is_authoritative()` / `local_peer_id()` / `full_roster()` | The source repeated `current_lobby_id == 0 or multiplayer.is_server()`-style checks across 14 files, and a roster helper in three. One definition can't drift. |
| `NetRetry` node | The source hand-wrote the same retry Timer four times. |
| Loading-gate ready report uses retry + ack | The source sent it once. A fast client could beat the host's node into existence. |
| Entity dedupe set is never cleared | Prevents a catch-up reply that crosses a despawn from resurrecting the entity. |
| `NetPlayerBody.broadcast_every_n_frames` | The source broadcast avatar transforms every physics frame, unthrottled. Default 1 keeps that behavior; raise it for more players. |
| `lobby_created` compared to `Steam.RESULT_OK` | The source compared to a literal `1`. |
| Overlay invite + `+connect_lobby` handling | Listed as "not yet wired" in the source. |
| `session_ended` signal | The lobby UI can react when the host disappears. |
| Generic loadout `Dictionary` on spawn | The source sent four game-specific typed parameters. |
| Shared-seed recipe includes the round number | A lobby-id-only seed repeats the same layout every round. |

## Provenance

Extracted on October 8, 2026 from **Fishing For Funds**, a Godot 4.7.1 game using GodotSteam 4.21
and Steamworks SDK 1.65. That project is not part of this repository. The mapping below records
which source file each template came from, for anyone maintaining the kit alongside it.

| Kit file | Derived from (source project path) |
|---|---|
| `steam_manager.gd` | `scripts/autoload/steam_manager.gd` |
| `steam_network.gd` | `scripts/autoload/steam_network.gd` + the repeated session helpers |
| `net_log.gd` | `scripts/autoload/net_log.gd` |
| `scene_router.gd` | `scripts/autoload/scene_router.gd` |
| `boot.gd` | `scenes/main/boot.gd` |
| `lobby_screen.gd` | `scripts/screens/lobby_screen.gd` |
| `loading_gate.gd` | `scripts/screens/loading_screen.gd` (simplified; the warm swap is documented as P14) |
| `net_player_spawner.gd` | `scripts/fishing_scene/canoe_network_spawner.gd` |
| `net_entity_spawner.gd` | `scripts/fishing_scene/fish_network_spawner.gd` + `resources/databases/fish_database.gd` (wire format) |
| `net_player_body.gd` | `scenes/player/canoe_controller.gd` (authority, relay, prediction, reconciliation, action request) |
| `net_npc.gd` | `scenes/entities/fish/live_fish.gd` (authority gate, throttled broadcast, interpolation, state sync) |
| Patterns P2/P16 | `scripts/fishing_scene/deposit_zone.gd`, `scripts/screens/shop_screen.gd`, `scripts/fishing_scene/hook.gd` |
| P3/P13/P15 | `scripts/screens/fish_appraisal_screen.gd`, `shop_screen.gd`, `loading_screen.gd` |
| P7 | `scripts/fishing_scene/fishing_level_controller.gd` |
| Pitfalls | Class docs above + the source project's roadmap and roadmap history |

## Contributing and maintenance

Issues and pull requests are welcome, especially live two-machine results for the 🟡 items.

- When a pattern or bug class generalizes, update `04_PATTERNS.md` / `05_PITFALLS.md` and the
  matching template in the same change.
- Keep `ai/multiplayer_rules.md` short. Agents load it into every prompt; detail belongs in
  `docs/`.
- When a 🟡 or ⬜ item is confirmed live, update its status in `02_REQUIREMENTS.md` and
  `05_PITFALLS.md`.
- Template style: every declaration explicitly typed, `##` doc comments on public members,
  lines at most 100 columns, Godot 4 syntax only.
- Re-run a compile check after editing a template: copy `templates/scripts/` plus
  `addons/godotsteam/` into a scratch project with the snippet's autoloads, and `load()` each
  script headless.

## License

[MIT](LICENSE). GodotSteam and the Steamworks SDK are separate projects under their own licenses
and are not included here.
