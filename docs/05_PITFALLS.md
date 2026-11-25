# 05 — Pitfalls & Lessons Learned

Each entry is a real bug from building the source project, found mostly through live two-instance
testing. Format: **Symptom → Root cause → Fix → Rule.** When you see a symptom, search this file
for its exact wording.

Confidence: ✅ root cause confirmed from logs · 🟡 strongest theory, fix applied, not re-confirmed.

---

## Lobby & session

### 1. Host loses authority right after creating a lobby ✅
- **Symptom:** Host-only test logs "Hosting lobby X" then "Joined lobby X" for the same id. After
  that, `multiplayer.is_server()` is false on the host and host-only RPCs are rejected.
- **Cause:** Steam fires `lobby_joined` (LobbyEnter_t) for the creator's own automatic entry too.
  The join handler created a client peer pointed at the lobby owner, which is itself, and
  replaced the host peer.
- **Fix:** In `_on_lobby_joined`, `if Steam.getLobbyOwner(lobby_id) == Steam.getSteamID(): return`.
- **Rule:** FR-LOBBY-3.

### 2. Hosting throws immediately ✅
- **Symptom:** Error on `create_host(...)`.
- **Cause:** Wrong signature from outdated docs (trailing options array).
- **Fix:** `create_host(virtual_port)` and `create_client(host_steam_id, virtual_port)`, with the
  same port on both sides.
- **Rule:** When a GodotSteam call misbehaves, check the argument order/count against the
  installed version first. See [07_STEAM_API_REFERENCE.md](07_STEAM_API_REFERENCE.md).

### 3. "Am I host" disagrees with RPC permissions ✅
- **Symptom:** A host-only button works but its `"authority"` RPC is rejected, or vice versa.
- **Cause:** A separately tracked `is_host` flag diverged from Godot's
  `multiplayer.is_server()`, which is what `@rpc("authority")` actually checks.
- **Fix:** Delete the flag. Use `SteamNetwork.is_authoritative()`.

---

## Spawning & node paths

### 4. Client has no avatar, or a "half" avatar, when it loads faster than the host ✅
- **Symptom:** "Non-host loads in faster than the host and then has no canoe, or a canoe missing
  functionality."
- **Cause:** The client sent one `_request_spawn.rpc_id(1)` before the host's spawner existed.
  An RPC to a missing NodePath is **silently dropped**. The original design (host pushes spawns
  from its own `_ready()`) had the mirror-image race.
- **Fix:** Client-requested spawn **with retry until confirmed** (P3). The host spawns only in
  response to a request, which proves the client's node exists.
- **Rule:** FR-SPAWN-1. Never push initial state from the host's `_ready()`.

### 5. "Node not found" floods, most entities don't move on the client ✅
- **Symptom:** Client log is full of `get_node: Node not found: "…/@Node3D@46"` and
  `_process_get_node: Failed to get path from RPC`.
- **Cause:** Entities were named after their species, so the second fish of a species collided
  and Godot auto-named it `@Node3D@46`. Auto-names are per-process, so the host and client paths
  differed.
- **Fix:** `name = "Entity_%d" % entity_id` before `add_child()` (P5).
- **Rule:** FR-SPAWN-4. Grep for `add_child(` on networked nodes and confirm a name is set first.

### 6. "Node not found" / "Failed to get cached node" for reused names 🟡
- **Symptom:** Errors when a new hook/projectile spawns right after the previous one despawned.
- **Cause:** Same name reused per owner (`Hook_<peer>`). The remote peer's node-path cache still
  pointed at the just-freed node.
- **Fix:** `<Kind>_<owner>_<sequence>`, with the sequence incremented in the `call_local` spawn
  function.

### 7. Everything breaks from round 2 onward ✅
- **Symptom:** Round 1 fine. From round 2, RPCs between gameplay nodes fail with "Node not found"
  on one peer only.
- **Cause:** A pre-instantiated gameplay scene was added under `/root` with its authored name
  "Node3D". The previous round's root (same name) was only `queue_free()`d, and on one peer it
  hadn't been freed yet, so Godot renamed the new one `Node3D2`. The paths diverged.
- **Fix:** Force a fixed unique name before `add_child()`; synchronously `remove_child()` any
  stale node with that name first (P14).

### 8. "Method expected 1 argument(s), but called with 4" 🟡
- **Symptom:** One RPC's payload arrives at a different RPC on the receiver.
- **Cause:** RPCs are sent as method **indices**. Both peers ran identical code, so the best theory
  is that the stream desynced after repeated path-resolution failures (#5). It disappeared once
  #5 was fixed.
- **Fix:** Fix every "Node not found" first. Always run byte-identical builds on both machines.
- **Rule:** Treat any path-resolution error as able to corrupt unrelated RPCs.

### 9. Spawned avatars all appear at the world origin ✅
- **Cause:** `add_child()` with no position assignment. The spawn-point source wasn't wired.
- **Fix:** The host picks the position once and sends it in the spawn RPC. If the spawn-point
  provider initializes in its own `_ready()`, call the host's spawn deferred.

### 10. Spawned avatar renders as a placeholder, missing visuals or child systems ✅
- **Cause:** Two avatar scenes existed (a hand-placed solo one and a networked one) and drifted
  apart.
- **Fix:** One avatar scene for solo, host, and client, spawned through one path.

---

## Replication

### 11. Joined client "can't switch stance" (or any control) ✅
- **Cause:** The value changed on the client's own copy but was never in the input relay. The
  host's authoritative copy kept the default.
- **Fix:** Add it to the relay (P11).
- **Rule:** FR-REP-3. Audit: list every field `_simulate()` reads and make sure each is local
  input or relayed.

### 12. Client HUD speed stuck at 0 ✅
- **Cause:** `current_speed` was only computed inside the host's `_integrate_forces`.
- **Fix:** Derive it on receivers from replicated velocity. Don't widen the RPC.

### 13. Same entity, different size on each peer ✅
- **Cause:** The receiver's `_ready()` re-rolled `randf_range` for size/weight.
- **Fix:** The host sends the rolled values; the receiver applies them as overrides (P6).
- **Rule:** FR-SPAWN-6. Any `randf`/`randi` in a networked entity's `_ready()` is a bug unless
  it's purely cosmetic.

### 14. Modified/custom item shows as the plain template on other peers ✅
- **Cause:** Only the species name was sent; receivers resolved the default template.
- **Fix:** Serialize the full identity: base id, every part's resource path, instance values (P6).

### 15. Each peer applies its own stale copy of another player's data ✅
- **Symptom:** "Modified fish never spawn in a Steam lobby" (worked solo).
- **Cause:** After a local-only editing screen, every peer released its own copy of every
  player's item. Only the owner's copy was current, and only the host's pool mattered.
- **Fix:** Only the owner submits its own data to the host (`rpc_id(1, serialized)`). The host
  alone applies (P16).

### 16. Two peers see different play areas ✅
- **Cause:** `rng.randomize()` ran independently on each peer.
- **Fix:** Seed from the lobby id (P7). **Follow-up gap:** the same layout repeats every round
  unless the round number is in the seed.

### 17. Client-side events (catches) never happen for joiners ✅
- **Symptom:** The host sees both players' catches; joiners see none, ever. The log line for the
  "returned" event is absent on the joiner.
- **Cause:** `returned.emit()` ran **before** `_broadcast_returned.rpc()`. A local handler freed
  the hook and sent a despawn RPC. The despawn reached the joiner first, so the event RPC had no
  node to land on.
- **Fix:** Broadcast first, emit second (P19).

### 18. 100+ NPCs: bandwidth and frame time blow up 🟡
- **Cause:** Unthrottled per-frame unreliable broadcast per entity, plus string formatting for
  debug logs that were off anyway.
- **Fix:** 15 Hz staggered broadcast with interpolation (P8); `NetLog.would_log()` guards.
  Hoist physics query objects and replace outward physics queries with a small registry.
- **Rule:** Assume N instances × 60 Hz × peers for anything in `_physics_process`.

### 19. HUD/camera follows the wrong player ✅
- **Cause:** "Find my avatar" fell back to *any* avatar when the local one hadn't spawned yet
  (the first frames after load), and never re-resolved.
- **Fix:** Resolve strictly by `owner_peer_id == local_peer_id()`. Wait for `player_spawned`
  instead of falling back.

### 20. Stagger buckets collapse into one 🟡
- **Cause:** Bucket = `get_instance_id() % N`. Instance ids share a stride that can be a
  multiple of N.
- **Fix:** Assign buckets from a static incrementing counter.

---

## Lifecycle & teardown

### 21. Thousands of `Condition "!is_inside_tree()" is true` errors at round end 🟡
- **Cause:** After owner prediction was added, the client's own body simulated. Physics-server
  callbacks and in-flight unreliable RPCs kept arriving during the scene teardown.
- **Fix:** `if not is_inside_tree(): return` at the top of `_integrate_forces` and every
  networked receiver (P18).

### 22. "Invalid access to property or key 'multiplayer_peer' on a base object of type 'null instance'" ✅
- **Symptom:** Even in **solo** play, from a scene node.
- **Cause:** That node's `multiplayer` reference resolved to a freed object. `!= null` doesn't
  catch freed objects.
- **Fix:** Check `SteamNetwork.has_active_session()` first so `and` short-circuits; use
  `is_instance_valid(multiplayer)` where a node must touch its own API; centralize in the
  autoload helpers.

### 23. Dangling references to other networked nodes 🟡
- **Cause:** `if boat:` / `boat != null` on a reference to a node freed in teardown.
- **Fix:** A `_target_valid()` helper (`!= null and is_instance_valid`) used at every dereference.

---

## Flow & state

### 24. Start Match only moved the host ✅
- **Cause:** A plain local `goto_screen()`.
- **Fix:** `goto_screen_for_everyone()` via an autoload `call_local` RPC (P12).

### 25. Round results and submissions vanish ✅
- **Cause:** Stored on a node inside the gameplay scene, which is freed by
  `change_scene_to_file()`.
- **Fix:** Store in an autoload.

### 26. Re-hosting after an aborted match starts mid-match ✅
- **Cause:** The round counter was never reset.
- **Fix:** Explicit `reset_match()` at the "new match begins" moment (lobby Start), as its own
  RPC, separate from "advance round".

### 27. Saved scenes point at the wrong screen after an enum edit ✅
- **Cause:** An exported enum serializes as an int in `.tscn`, and inserting mid-enum renumbered
  every later value.
- **Fix:** Append-only enums.

### 28. Ready count or turn order wrong on clients ✅
- **Cause:** The roster was built from `multiplayer.get_peers()` on a client, which only lists the
  host.
- **Fix:** Build rosters on the host and send them (P15).

### 29. Menu preview avatar moves when you click UI ✅
- **Cause:** A preview instance of the real avatar scene was `is_local_player() == true` offline
  (peer 1) and polled raw `Input`.
- **Fix:** An `accept_input` export, false on previews.

### 30. Host-only test passes, two-instance test fails ✅ (meta)
- **Cause:** Solo/host-only paths short-circuit the network entirely. Most bugs above were
  invisible until a second machine joined.
- **Rule:** No networked feature is done until it passes the two-machine matrix in
  [06_TESTING_DEBUGGING.md](06_TESTING_DEBUGGING.md).

---

## Quick symptom index

| You see | Go to |
|---|---|
| `Node not found` / `Failed to get path from RPC` / `@Node3D@N` | #5, #6, #7 |
| `Method expected N argument(s), but called with M` | #8 |
| `!is_inside_tree()` spam | #21 |
| `null instance` on `multiplayer…` | #22 |
| Client avatar missing or broken | #4, #9, #10 |
| Client control doesn't affect its avatar | #11 |
| Values differ between peers | #13, #14, #15, #16 |
| Client never sees an event | #17, #4 |
| Host stops being host | #1, #3 |
| UI shows the wrong player's data | #19 |
| Works solo, broken with 2 | #30, then everything above |
