# 03 — Implementation Guide

Step by step, from an empty Godot project to two Steam instances playing together. Each step ends
with a **check**. Don't move on until it passes; later failures are much harder to localize.

Estimated time with the templates: **1–2 hours** to a working two-player lobby with spawned,
moving avatars.

---

## Step 0 — Prerequisites

- Godot 4.4+ (reference: 4.7.1).
- Steam installed and logged in.
- A second machine with a **different** Steam account for live testing. A single account can't
  reliably be two members of its own lobby. See [06_TESTING_DEBUGGING.md](06_TESTING_DEBUGGING.md)
  §1.

## Step 1 — Install GodotSteam (GDExtension)

1. AssetLib → search **"GodotSteam GDExtension"** → install. Or download the GDExtension release
   from the GodotSteam GitHub/Codeberg and unzip into `addons/godotsteam/`.
2. Make sure it's the **GDExtension** build (an `addons/godotsteam/godotsteam.gdextension` file
   exists), not the precompiled custom-engine build.
3. Restart the editor.

**Check:** In any script, `Steam.` autocompletes, and `SteamMultiplayerPeer.new()` resolves.

> Reference project: GodotSteam **4.21**, Steamworks SDK **1.65**. Its `.gdextension` lists
> `steam_api64.dll` / `libsteam_api.so` / `libsteam_api.dylib` as dependencies, so exports copy
> them automatically.

## Step 2 — App ID file

Create `steam_appid.txt` at the project root containing only:

```
480
```

Add it to `.gitignore` (see `templates/gitignore.snippet`). 480 is Valve's public "Spacewar" test
app. Every dev machine needs its own copy. **Don't ship it**: Steam provides the App ID when the
game launches through Steam.

## Step 3 — Copy the templates

Copy `templates/scripts/` into your project's `res://scripts/`:

```
res://scripts/
├── boot.gd
├── autoload/
│   ├── net_log.gd
│   ├── steam_manager.gd
│   ├── steam_network.gd
│   └── scene_router.gd
├── net/
│   ├── net_retry.gd
│   ├── net_player_spawner.gd
│   ├── net_entity_spawner.gd
│   ├── net_player_body.gd
│   └── net_npc.gd
└── screens/
    ├── lobby_screen.gd
    └── loading_gate.gd
```

Copy `docs/` to `res://docs/multiplayer/` (the template `@tutorial` links point there). Copy
`ai/multiplayer_rules.md` to `.claude/rules/multiplayer.md` if you use Claude Code.

## Step 4 — project.godot

Merge `templates/project.godot.snippet`:

```ini
[autoload]
NetLog="*res://scripts/autoload/net_log.gd"
SteamManager="*res://scripts/autoload/steam_manager.gd"
SteamNetwork="*res://scripts/autoload/steam_network.gd"
SceneRouter="*res://scripts/autoload/scene_router.gd"

[logging]
file_logging/enable_file_logging=true
file_logging/enable_file_logging.pc=true
file_logging/log_path="user://logs/godot.log"
file_logging/max_log_files=5
```

**Order matters.** Put your own autoloads after these.

## Step 5 — Boot scene

1. New scene, root `Node`, attach `scripts/boot.gd`, save as `res://scenes/boot.tscn`.
2. Project Settings → Application → Run → **Main Scene** = `boot.tscn`.
3. Edit `SceneRouter.SCREEN_PATHS` so every `Screen` points at a real scene. Stub screens are fine
   for now: a `Control` with a label.

**Check (Steam running):** Run. Output shows
`SteamManager: Steam initialized (app id 480).` and the start screen loads.
**Check (Steam closed):** Warning instead, and the start screen still loads.

## Step 6 — Lobby screen

1. New scene, root `Control`, attach `scripts/screens/lobby_screen.gd`. Save at the path
   registered for `Screen.LOBBY`.
2. From your start screen, add a Multiplayer button:
   `SceneRouter.goto_screen(SceneRouter.Screen.LOBBY)`. Add a Solo button:
   `SceneRouter.goto_screen(SceneRouter.Screen.LOADING)`.

**Check (one machine):** Host Lobby → lobby id appears, log shows
`[INFO][Lobby][peer 1] Hosting lobby … unique_id=1 is_server=true`. There should be **no**
"Joined lobby" line for your own lobby.

**Check (two machines):** B pastes A's id → Join. B logs `unique_id=<big number> is_server=false`.
A logs `Peer <B's id> connected`. Both member lists show both names. Only A sees Start.

## Step 7 — Loading gate

1. New scene, root `Control`, attach `scripts/screens/loading_gate.gd`. Save at `Screen.LOADING`'s
   path. Leave `target_screen` = `GAMEPLAY`.

**Check:** Host presses Start. Both machines show the loading gate, then "Players ready 2 / 2",
then the gameplay scene loads on both.

## Step 8 — Player avatar

1. New scene, root **`RigidBody3D`**, attach `scripts/net/net_player_body.gd`. Add a
   `CollisionShape3D` and a mesh.
2. Add Input Map actions `move_left`, `move_right`, `move_forward`, `move_back`. Or replace
   `_read_input()` with your own actions and update the input-map block at the top of the file.
3. Replace `_simulate()` with your movement model. Keep it a pure function of `move_input` + state.
   It runs on both the host and the owning client.

## Step 9 — Gameplay scene + player spawner

```
Gameplay (Node3D)
├── World / level geometry …
├── SpawnPoints (Node3D)
│   ├── P1 (Marker3D)  P2 …  P4
├── Players (Node3D)                 ← spawn_parent
└── PlayerSpawner (Node)             ← net_player_spawner.gd
      player_scene = your avatar .tscn
      spawn_parent = ../Players
      spawn_points = [P1, P2, P3, P4]
```

Camera/HUD: find **your** avatar with `spawner.get_player(SteamNetwork.local_peer_id())`, or
connect to `player_spawned` and filter by peer id. **Never** fall back to "any avatar" (see
[05_PITFALLS.md](05_PITFALLS.md) #19).

**Check (solo):** One avatar spawns and moves.
**Check (two machines):** Each machine has two avatars. Each player moves only their own. Both see
both moving. The client's own movement feels instant. Logs show `Spawned player <id>` on both, and
the client logs `player spawn request acknowledged after N attempt(s)`.

## Step 10 — Entities / NPCs (optional)

1. Entity scene, root `Node3D`, attach `scripts/net/net_npc.gd` (or your subclass). Replace
   `_think()`.
2. Add a `NetEntitySpawner` node with `entity_scene` + `spawn_parent`. If spawn data matters,
   subclass it and override `_serialize_entity()` / `_apply_spawn_data()`.
3. From host-only code (`if SteamNetwork.is_authoritative():`), call
   `spawner.spawn_entity({...}, position)`.

**Check:** A late joiner sees every entity, once each. Entities move smoothly on the client.

## Step 11 — Your first discrete action

Use `NetPlayerBody.request_action(action_id, target)` from input handling, put the legality checks
in `_validate_action()`, and react to `action_performed` (or override `_perform_action`).
Anything spawned by an action needs a deterministic name: `"%s_%d_%d" % [kind, owner_peer_id,
per_owner_sequence]`, with the sequence incremented **inside** the `call_local` function so it
advances identically on every peer.

**Check:** Client triggers the action; the effect appears on all peers and the host log shows the
request. A forged request (wrong owner) is rejected with a warning.

## Step 12 — Round flow

- Host-only "round over" logic calls `SceneRouter.goto_screen_for_everyone(Screen.RESULTS)`.
- Results screen: host computes, broadcasts rows as Packed arrays. Clients request with retry if
  they may load after the host (see [04_PATTERNS.md](04_PATTERNS.md) P3).
- Host's Continue → `SceneRouter.finish_round()`.

**Check:** Play 3 full rounds on two machines. Same round number everywhere, and zero
`!is_inside_tree()` / "Node not found" errors in either log.

---

## Recipe: adding any new networked feature

Answer these in order. Each answer picks a pattern from [04_PATTERNS.md](04_PATTERNS.md).

1. **Is it cosmetic only?** React locally to already-replicated state. No RPC. (P17)
2. **Who decides it?** Almost always the host. Gate with `SteamNetwork.is_authoritative()`. (P1)
3. **Triggered by a client?** Request → host validates → broadcast `call_local`. (P2)
4. **Continuous or discrete?** Continuous: unreliable + interpolate, throttle if many (P8).
   Discrete: reliable (P9).
5. **Does it create nodes?** Deterministic name before `add_child()` (P5). Identity by id (P6).
6. **Does a client need state that exists before it arrived?** Client requests with retry; host
   replies `rpc_id` (P3/P4).
7. **Does it involve randomness?** Roll on the host and send the result, or derive from the shared
   seed (P7).
8. **Must it survive a scene change?** Store it in an autoload.
9. **Solo path?** Same function, direct call instead of `.rpc()`.
10. **Logging:** `NetLog` with a category, `would_log()`-gated if per-frame.
11. **Test:** solo, host-only, two machines, late join, and 3 scene transitions.
