# Prompt Templates

Copy, fill in the `<…>` parts, and paste. They assume the kit's docs live at
`docs/multiplayer/` and the rules file at `.claude/rules/multiplayer.md` (see
[../README.md](../README.md)). If your agent doesn't auto-load rules, attach
`ai/multiplayer_rules.md` to the prompt.

---

## 1. Integrate the kit into a new project

```text
Integrate the Steam multiplayer kit into this Godot project.

Kit location: <path to steam_multiplayer_kit/>
Follow docs/03_IMPLEMENTATION_GUIDE.md steps 1–9 exactly. My project specifics:
- Screens I have / want: <list>  → map them into SceneRouter.Screen (append-only) and SCREEN_PATHS
- Player avatar: <RigidBody3D | CharacterBody3D | 2D>, movement model: <describe>
- Max players: <n>; lobby type: <friends-only | public>
- Existing autoloads that must stay: <list> (kit autoloads go first)

Constraints: follow .claude/rules/multiplayer.md. Don't change the authority model. Give an effort
estimate first. List every file you'll add or modify, then wait for my go-ahead before writing.
```

> For a `CharacterBody3D` / 2D avatar, ask the agent to port `net_player_body.gd`'s roles
> (host simulates, owner predicts and reconciles, others display) onto the new body type. The
> RPC shapes stay the same; only `_simulate` and reconciliation target the body's own API.

## 2. Add a networked feature

```text
Add <feature> as a networked feature.

Behavior: <what players see/do>
Triggered by: <which player input / host event>
Affects: <whose state: shared, one player's, per-machine local>

Before coding, answer the "Recipe: adding any new networked feature" questions in
docs/multiplayer/03_IMPLEMENTATION_GUIDE.md. Name the patterns (P#) and requirements (FR-*) you're
applying. List every new @rpc with (permission, transfer mode, call_local/remote) and a one-line
reason each. State the solo path. Then implement. Finish with the two-machine tests from
06_TESTING_DEBUGGING.md §2 that cover this, and mark the feature untested live.
```

## 3. Add a host-owned entity type (NPC, pickup, projectile)

```text
Add a networked <entity> using the kit's NetEntitySpawner + NetNpc templates.

Spawn rules: <when/where; host decides>
Per-instance data that must match on every peer: <size, variant, hp…>
Behavior: <AI states>
Expected max concurrent count: <n>

Subclass NetEntitySpawner (override _serialize_entity/_apply_spawn_data) and NetNpc (replace
_think, extend State append-only). Per-instance random values are rolled on the host only (P6).
Broadcast rate and stagger per P8. Show the wire format (spawn_data keys and types).
```

## 4. Add a client-triggered action

```text
Add <action> (e.g. attack / use / pick up) for players.

Legality rules the host must enforce: <cooldown, range, state, resource>
Effect on success: <…>
Any nodes it spawns: <…>

Use request → validate → broadcast (P2) through NetPlayerBody.request_action or an equivalent
RPC trio. Client-side immediate feedback allowed: <yes/no, what>. Spawned nodes named
<Kind>_<owner>_<seq> with the sequence incremented inside the call_local function. Include the
forged-request rejection path and a NetLog line for it.
```

## 5. Debug a multiplayer bug

```text
Multiplayer bug: <one-sentence symptom>.
Repro: <steps, who hosts, who joins, when it happens>
Works in solo? <y/n>   Host-only? <y/n>   Same commit on both machines? <y/n>

Host log:
<paste user://logs/godot.log from host>

Client log:
<paste user://logs/godot.log from client>

Follow docs/multiplayer/06_TESTING_DEBUGGING.md §4. Match against the 05_PITFALLS.md symptom
index first. Find the FIRST error in each log, not the loudest. If the cause isn't certain from
the logs, propose a targeted NetLog line to confirm it instead of guessing a fix. State your
confidence.
```

## 6. Review a networking change

```text
Review the current diff for multiplayer correctness against .claude/rules/multiplayer.md and
docs/multiplayer/06_TESTING_DEBUGGING.md §5 (static review checklist). For each finding: the
rule or pattern it violates, the concrete failure scenario (which peer, what order of events),
and the fix. Also list which two-machine tests (§2) this diff needs before merge.
```

## 7. Quick context primer (when the agent has no repo access)

```text
Context: Godot 4 game, Steam multiplayer via GodotSteam's SteamMultiplayerPeer. Host-authoritative
listen server; host = peer 1 simulates all shared state; clients send input/requests; host
validates and broadcasts with @rpc. Owner client predicts its own avatar movement with soft
reconciliation (no rollback). Solo = no lobby, same code, direct calls. Autoloads: NetLog,
SteamManager (init/is_available), SteamNetwork (lobby, has_active_session(), is_authoritative(),
local_peer_id(), full_roster()), SceneRouter (goto_screen_for_everyone, cross-scene state).
Spawning is client-requested with retry (NetRetry); networked nodes are named deterministically
before add_child; payloads are plain data (ids, resource paths), never Resources.
Question: <…>
```
