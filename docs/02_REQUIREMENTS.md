# 02 — Requirements

What a project integrating this kit must do, stated so each item can be checked. IDs are stable,
so you can reference them in plans, PRs, and prompts ("satisfies FR-SPAWN-2").

**Status legend** (how much the source project proved, not what the kit claims):
✅ verified live across two Steam instances · 🟡 implemented, reasoned, not yet live-tested ·
⬜ specified only, no reference implementation.

---

## 1. Platform & dependencies

| ID | Requirement | Status |
|---|---|---|
| DEP-1 | Godot **4.4+** (typed `Dictionary[K, V]` used by the templates). Reference build: **4.7.1**. | ✅ |
| DEP-2 | **GodotSteam GDExtension** (not the pre-compiled engine fork) with `SteamMultiplayerPeer` included. Reference: **4.21**, Steamworks SDK **1.65**. | ✅ |
| DEP-3 | Steam client running and logged in on every test machine. | ✅ |
| DEP-4 | `steam_appid.txt` with the App ID at the project root on dev machines. **Gitignored, not shipped.** | ✅ |
| DEP-5 | Autoload order: `NetLog`, `SteamManager`, `SteamNetwork`, `SceneRouter`, then game autoloads. | ✅ |

## 2. Functional requirements

### Steam lifecycle

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-STEAM-1 | Steam initializes exactly once, from the boot scene, before the first screen loads. | Console shows `SteamManager: Steam initialized` before any screen log. | ✅ |
| FR-STEAM-2 | Init failure doesn't crash or block solo play. | Quit Steam, launch: warning logged, solo game fully playable. | ✅ |
| FR-STEAM-3 | Every `Steam.*` call is gated on `SteamManager.is_available`. | Grep: no `Steam.` call path reachable when unavailable. | ✅ |
| FR-STEAM-4 | Callbacks are pumped automatically (`steamInitEx(app_id, true)`); no manual `run_callbacks()`. | No `run_callbacks` in project. | ✅ |

### Lobby

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-LOBBY-1 | A player can host a friends-only lobby with a capacity limit. | Host button → lobby id shown → host is `unique_id 1`, `is_server true` in log. | ✅ |
| FR-LOBBY-2 | A player can join by numeric lobby id. | Join → client logs `unique_id != 1`, `is_server false`; host logs `Peer N connected`. | ✅ |
| FR-LOBBY-3 | The host ignores its own `lobby_joined` callback (owner == self). | Host-only run logs "Hosting lobby X" and is still `is_server true` afterwards. | ✅ |
| FR-LOBBY-4 | The lobby id is copyable (select + Ctrl+C, and a Copy button). | Manual. | ✅ |
| FR-LOBBY-5 | The member list updates live on join, leave, and disconnect. | Second player joins/leaves; both screens update without re-entering. | ✅ |
| FR-LOBBY-6 | Only the host sees Start. Start moves **every** peer. | Client has no Start button; host Start → both change screen. | ✅ |
| FR-LOBBY-7 | Leave Lobby fully resets to pre-lobby state with no restart. | Leave → host/join again in the same run works. | ✅ |
| FR-LOBBY-8 | Accepting a Steam overlay invite joins the lobby, whether the game is running (`join_requested`) or not (`+connect_lobby`). | Invite a friend from the overlay; they land in the lobby. | ⬜ |
| FR-LOBBY-9 | Losing the host returns clients to a usable state. | Kill the host; client gets `session_ended`, can host/join again. | 🟡 |

### Session & authority

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-AUTH-1 | "Am I host" is derived **only** from `multiplayer.is_server()` (via `SteamNetwork.is_authoritative()`), never a separate flag. | Grep: no `is_host` bool field. | ✅ |
| FR-AUTH-2 | All shared-state decisions run only where `is_authoritative()` is true. | Code review against [05_PITFALLS.md](05_PITFALLS.md). | ✅ |
| FR-AUTH-3 | Every client → host RPC is `"any_peer"` and re-checks `is_server()` and, where ownership applies, `get_remote_sender_id() == owner_peer_id`. | Grep `@rpc("any_peer"`; every handler starts with both guards. | ✅ |
| FR-AUTH-4 | The host re-validates every client request (turn, range, cooldown, possession) instead of trusting the claim. | Modified client spamming requests changes nothing illegal. | 🟡 |
| FR-AUTH-5 | Solo play runs the same code paths as hosting, with direct calls instead of `.rpc()`. | Solo smoke test exercises spawn, actions, round flow. | ✅ |

### Screen flow & match state

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-FLOW-1 | Host-driven screen changes go through an autoload `@rpc("authority","reliable","call_local")`. | Host advances; all peers follow. | ✅ |
| FR-FLOW-2 | Match state needed across screens (round, submissions, points) lives in an autoload and is synced by host broadcast. | Same round number shown on every peer after 3 rounds. | ✅ |
| FR-FLOW-3 | The `Screen` enum is append-only. | Review: new entries only at the end. | ✅ |
| FR-FLOW-4 | Before entering gameplay, every peer finishes loading and the host advances only when all connected peers are ready. Disconnects mid-load don't stall. | Throttle one machine; nobody enters early; kill a loading client and the rest proceed. | 🟡 |

### Spawning

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-SPAWN-1 | Each peer gets exactly one avatar, spawned by the host **on that client's request**, retried until confirmed. | Client loads faster than host: client still gets its avatar. | ✅ |
| FR-SPAWN-2 | A late joiner sees every existing avatar at its **current** position, with its applied loadout. | Join mid-round; positions and cosmetics match the host. | ✅ |
| FR-SPAWN-3 | Avatars despawn on every peer when their owner disconnects. | Client quits; avatar disappears on host and other clients. | 🟡 |
| FR-SPAWN-4 | Networked nodes are named deterministically **before** `add_child()`. | No `@Node3D@N` names in remote scene tree; no "Node not found" in logs. | ✅ |
| FR-SPAWN-5 | Host-owned entities replicate via live broadcast + client catch-up with explicit ack, deduped by `entity_id`. | Late joiner gets the full population; no duplicates. | ✅ |
| FR-SPAWN-6 | Random per-instance values are rolled once on the host and sent; receivers never re-roll. | Same entity shows same size/variant on all peers. | ✅ |
| FR-SPAWN-7 | Wire payloads are plain data (ids, resource **paths**, numbers, Colors, Packed arrays), never `Resource` objects. | Grep RPC signatures: no Resource-typed params. | ✅ |

### Replication

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-REP-1 | The host simulates every avatar. Non-owners' copies are frozen and display host snapshots. | Remote avatars move smoothly and only from broadcasts. | ✅ |
| FR-REP-2 | The owning client predicts its own avatar and softly reconciles (blend; snap past a threshold). | Joiner's own steering feels instant; no visible micro-teleports. | 🟡 |
| FR-REP-3 | Every input the authoritative simulation reads is in the input relay. | Joiner changes every control (stance, mode, etc.); the host's copy reacts. | ✅ |
| FR-REP-4 | Display values derived from simulation (speed, etc.) are derived on receivers from replicated state. | Joiner's HUD speed is non-zero while moving. | ✅ |
| FR-REP-5 | NPC transforms are throttled (~15 Hz) and evenly staggered; receivers interpolate. | 100 NPCs: steady per-frame send count, smooth remote motion. | 🟡 |
| FR-REP-6 | Discrete state changes are reliable and the setter can't echo them back. | State flips appear on clients; no RPC loops. | ✅ |
| FR-REP-7 | Shared procedural layout uses a deterministic seed every peer derives locally (lobby id, plus round number if layouts should vary per round). | Host and client see the identical play area. | ✅ |
| FR-REP-8 | Cosmetic feedback (audio/VFX) is triggered locally from replicated state, not via dedicated RPCs. | No "play_sound" RPCs. | ✅ |

### Robustness

| ID | Requirement | Acceptance check | Status |
|---|---|---|---|
| FR-ROB-1 | RPC receivers and `_integrate_forces` on networked bodies guard `is_inside_tree()`. | 3+ round transitions with zero `!is_inside_tree()` errors. | 🟡 |
| FR-ROB-2 | References to other networked nodes are checked with `is_instance_valid()`, not `!= null`. | Teardown mid-action: no "null instance" errors. | ✅ |
| FR-ROB-3 | When a local signal handler can free the node, broadcast first and emit second. | Clients receive every "completed" event. | ✅ |
| FR-ROB-4 | Every networking log line identifies the peer that wrote it; file logging is on. | `user://logs/godot.log` exists on both machines after a run. | ✅ |

## 3. Non-functional requirements

| ID | Requirement | Target |
|---|---|---|
| NFR-1 Feel | The local player's own movement responds the same frame input is pressed. | Owner prediction (FR-REP-2). |
| NFR-2 Scale | Many replicated NPCs without flooding. | Designed for 100+ NPCs at 15 Hz each, staggered. Measure before claiming. |
| NFR-3 Bandwidth | No per-frame string formatting or unconditional logging on hot paths. | `NetLog.would_log()` gates. |
| NFR-4 Players | Small friends-only lobbies. | Designed and tested at 2. The default cap in templates is 4. Lobby max is a parameter. |
| NFR-5 Testability | Every networked feature is diagnosable from two log files without a debugger. | Peer-tagged, categorized `NetLog`. |
| NFR-6 Determinism | No logic depends on bit-identical physics across machines. | Architecture constraint. |
| NFR-7 Anti-cheat posture | Clients can't create, score, or win anything the host didn't validate. | FR-AUTH-3/4. |

## 4. Explicitly out of scope (not provided by this kit)

- Public matchmaking / lobby browser (`requestLobbyList`, lobby data filters).
- Host migration. The session ends when the host leaves.
- Reconnect to an in-progress match after a drop.
- Dedicated servers.
- Lag compensation / server-side rewind for hit detection.
- Voice chat, text chat.
- Achievements, leaderboards, stats, Steam Cloud. See [07_STEAM_API_REFERENCE.md](07_STEAM_API_REFERENCE.md) §6 for pointers.
- `MultiplayerSynchronizer`-based replication. Compatible with the authority model, just not used.
