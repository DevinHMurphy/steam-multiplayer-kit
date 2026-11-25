# 04 — Pattern Catalog

Every recurring networking shape in the source project, distilled. Each pattern lists **when** to
use it, the **shape** in code, the **rules** that make it correct, and **where** it lives in the
templates. The rules are the important part: each one exists because breaking it caused a real
bug ([05_PITFALLS.md](05_PITFALLS.md)).

| # | Pattern | Use for |
|---|---|---|
| P1 | Session gates + solo fallback | Every networked call site |
| P2 | Request → validate → broadcast | Any client-triggered discrete action |
| P3 | Client-requested state with retry + ack | Anything a client needs once its scene loads |
| P4 | Live broadcast + catch-up + dedupe | Host-owned populations |
| P5 | Deterministic naming | Every node an RPC targets |
| P6 | Identity by id / path, never Resource | Every RPC payload that refers to "a thing" |
| P7 | Shared seed | Procedural layout every peer can derive |
| P8 | Throttled, staggered, interpolated transforms | Many moving entities |
| P9 | Reliable state with echo guard | Discrete state machines |
| P10 | Owner prediction + soft reconciliation | The local player's own avatar |
| P11 | Input relay | Owner → host continuous input |
| P12 | Autoload-routed flow control | Screen changes, match state |
| P13 | Ready gate | "Nobody starts until everyone's loaded" |
| P14 | Warm scene swap | Pre-building the next scene off-screen |
| P15 | Host-only roster | Counting players, turn order |
| P16 | Broadcast the fact, apply local slices | Shared outcome affecting per-machine state |
| P17 | Local cosmetic reaction | SFX/VFX/UI |
| P18 | Teardown guards | Every RPC receiver, physics callback, cross-node ref |
| P19 | Broadcast before emit | Events whose local handlers free the node |

---

## P1 — Session gates + solo fallback

**When:** every call site that touches `.rpc()`, `multiplayer.multiplayer_peer`, or decides shared
state.

```gdscript
if SteamNetwork.is_authoritative():          # host, or solo
    _decide_thing()

if SteamNetwork.has_active_session():        # broadcast when there's someone to tell
    _apply_thing.rpc(args)
else:
    _apply_thing(args)                       # solo: same function, direct call
```

**Rules**
- Use the helpers on the `SteamNetwork` autoload, not ad-hoc `current_lobby_id == 0 or
  multiplayer.is_server()` copies. The source project repeated that expression across 14 files.
  Centralizing it is the kit's main deviation from the source.
- `multiplayer.is_server()` with no peer isn't trusted on its own. Solo is decided by "no
  session".
- Never add an `is_host: bool` field. `@rpc("authority")` checks Godot's own authority, and a
  parallel flag can disagree.
- In nodes that might outlive their `MultiplayerAPI` (teardown), prefer the autoload helpers over
  touching `self.multiplayer`. A freed `Node.multiplayer` reference passes `!= null` and then
  throws "null instance".

**Templates:** `steam_network.gd` (helpers), used throughout.

---

## P2 — Request → validate → broadcast

**When:** a client triggers anything that changes shared state: attack, cast, pick an item,
deposit, use.

```gdscript
func request_x(arg: Vector3) -> void:              # called by local input
    if not SteamNetwork.has_active_session():
        _do_x(arg)
    elif SteamNetwork.is_authoritative():
        _do_x.rpc(arg)
    else:
        _request_x.rpc_id(1, arg)

@rpc("any_peer", "reliable", "call_remote")
func _request_x(arg: Vector3) -> void:
    if not multiplayer.is_server():
        return
    if multiplayer.get_remote_sender_id() != owner_peer_id:   # ownership check
        NetLog.warn(NetLog.Category.ACTION, "Rejected x from %d" % multiplayer.get_remote_sender_id())
        return
    if not _is_legal(arg):                                    # re-run the checks host-side
        return
    _do_x.rpc(arg)

@rpc("authority", "reliable", "call_local")
func _do_x(arg: Vector3) -> void:                             # runs on EVERY peer
    ...
```

**Rules**
- The client **doesn't** apply the result locally. Local *feedback* (charge bar, UI state) can be
  immediate; the authoritative effect waits for the broadcast.
- The handler re-runs **every** legality check (turn, range, cooldown, "is in zone", "has item").
  The client's own pre-check is a UX convenience, not authority.
- `call_local` on the broadcast so the host takes the same path as everyone else.
- Everything the broadcast function needs comes from its arguments, not from peer-local state that
  might differ.

**Templates:** `net_player_body.gd` → `request_action` / `_request_action` / `_perform_action`.

---

## P3 — Client-requested state with retry + ack

**When:** a client needs something from the host as soon as the client's scene exists: its
avatar, a draft pool, results, a catch-up.

```gdscript
func _ready() -> void:
    if SteamNetwork.is_authoritative():
        _build_state()                 # host/solo builds directly
        return
    var retry := NetRetry.new()
    add_child(retry)
    retry.start(func() -> void: _request_state.rpc_id(1), func() -> bool: return _synced)

@rpc("any_peer", "reliable", "call_remote")
func _request_state() -> void:
    if not multiplayer.is_server():
        return
    _deliver_state.rpc_id(multiplayer.get_remote_sender_id(), PackedStringArray(_pool), _turn)

@rpc("authority", "reliable", "call_remote")
func _deliver_state(pool: PackedStringArray, turn: int) -> void:
    _pool = Array(pool); _turn = turn; _synced = true
```

**Rules**
- **The host never pushes initial state from its own `_ready()`.** The client may not have loaded
  the scene yet, and an RPC to a missing node is silently dropped.
- **Retry.** The host may not have loaded the scene yet either. One attempt isn't reliable.
- The host handler is **idempotent**: duplicates from retries change nothing.
- The ack is either an explicit RPC (`_catch_up_done`, `_ready_ack`) or an observable condition
  ("my avatar exists").
- Give up with a **warning** after N attempts. That means misconfiguration, not timing.
- Once the handshake is done, the host may broadcast later updates proactively, because the
  client's node is now known to exist.

**Templates:** `net_retry.gd`; used by `net_player_spawner.gd`, `net_entity_spawner.gd`,
`loading_gate.gd`.

---

## P4 — Live broadcast + catch-up + dedupe

**When:** the host owns a population that changes over time (NPCs, pickups) and clients may join
late or load slowly.

- **Live:** on host spawn → `_spawn_remote.rpc(id, data, pos)` to everyone connected (optimization).
- **Catch-up:** client requests (P3) → host `rpc_id`s every **currently alive** entity, then an
  explicit `_catch_up_done` ack (completeness guarantee).
- **Dedupe:** the client keeps a never-cleared `seen_ids` set. Overlapping live and catch-up
  deliveries are harmless, and a catch-up crossing a despawn can't resurrect anything.
- **Catch-up sends current state:** a player at their *current* position, not their spawn point,
  so late joiners don't see a snap.
- **Bookkeeping:** the host removes entries on `tree_exiting`, so catch-up never iterates freed
  instances and the dict doesn't leak.

**Templates:** `net_entity_spawner.gd`, `net_player_spawner.gd` (`_request_spawn` catch-up loop).

---

## P5 — Deterministic naming

**When:** any node an RPC will ever target.

```gdscript
node.name = "Entity_%d" % entity_id         # BEFORE add_child
parent.add_child(node)
```

| Node kind | Name scheme |
|---|---|
| Player avatar | `Player_<peer_id>` |
| Host-owned entity | `Entity_<entity_id>` |
| Per-action spawn (projectile, hook) | `<Kind>_<owner_peer_id>_<sequence>`, with the sequence incremented inside the `call_local` function |
| A scene root added under `/root` manually | A **fixed constant** name. Remove any stale same-named node synchronously (`remove_child` then `queue_free`) before adding. |

**Rules**
- Name **before** `add_child()`. Godot resolves sibling collisions at insertion, so renaming
  afterwards is too late.
- Never let Godot auto-name a networked node (`@Node3D@46`). Auto-names are per-process and won't
  match across peers.
- Don't reuse a name for a *new* instance right after freeing the old one (`Hook_<peer>` per
  boat). The remote peer's node cache can still map that path to the freed node. Add a sequence.
- Parents must also match across peers. Spawn into a fixed, authored node.

---

## P6 — Identity by id / path, never Resource

**When:** an RPC must refer to "a thing": an entity, an item, a species, a loadout.

```gdscript
# Wire format: plain data every peer can resolve against its OWN shipped files.
{ "species": "pike", "head_path": "res://parts/heads/spiky.tres", "size": 1.42 }

# Receiver
var head := load(data.get("head_path", "")) as HeadDefinition
var fish := spawner.find_entity(entity_id)          # entity by id
```

**Rules**
- Every peer has identical `.tres` files, so a **resource path** round-trips via `load()`.
- Send **instance values** too (rolled size, modified stats). A path alone resolves to the
  unmodified template.
- `""`, not `null`, for "none". RPC string args can't be null.
- An unknown id or path on the receiver indicates a version mismatch. Log a warning and skip;
  don't crash.
- Bulk tables go as parallel `Packed*Array`s (`PackedInt32Array` peer ids, `PackedFloat32Array`
  scores…), not `Array[Dictionary]`.
- When rebuilding typed arrays from wire data, append element by element. Assigning an
  `as`-cast untyped Array to a typed property fails at runtime.

---

## P7 — Shared seed

**When:** procedural layout (map chunk, play area, spawn regions) that every peer can compute
independently.

```gdscript
var rng := RandomNumberGenerator.new()
if SteamNetwork.has_active_session():
    rng.seed = hash([SteamNetwork.current_lobby_id, SceneRouter.current_round])
else:
    rng.randomize()
```

**Rules**
- The lobby id is identical on every member and set before gameplay. That makes it a free seed
  with zero RPCs.
- Include the round number if layouts should differ per round. A plain lobby-id seed repeats the
  same layout every round (a known gap in the source).
- The **call sequence must be identical** on every peer: same exported values, same number of
  draws, same order. Use a dedicated `RandomNumberGenerator`, never global `randf()`.
- Use this only for things derived from **data**. Anything that depends on simulation (physics,
  AI) stays host-authoritative (P4).
- For multiple draws from one seed (one per player), offset deterministically
  (`seed + 1 + call_index`).

---

## P8 — Throttled, staggered, interpolated transforms

**When:** many host-simulated entities moving continuously.

```gdscript
const BROADCAST_GROUPS: int = 4                     # 60 Hz / 4 = 15 Hz per entity
static var _next_group: int = 0
func _ready() -> void:
    _group = _next_group % BROADCAST_GROUPS; _next_group += 1

func _physics_process(delta: float) -> void:
    if not is_multiplayer_authority():
        global_position = global_position.lerp(_target, clampf(delta * smoothing, 0.0, 1.0))
        return
    ...
    if _frame % BROADCAST_GROUPS == _group and SteamNetwork.has_active_session():
        _broadcast_transform.rpc(global_position)
```

**Rules**
- Simulate at physics rate on the host; **send** at 10–20 Hz.
- **Stagger with an explicit counter.** `get_instance_id() % N` can collapse every entity into one
  bucket because instance ids are allocated with a stride. A random phase only evens out on
  average, while the modulo split sends exactly N/groups per frame.
- Receivers **ease** toward the latest target every frame (exponential smoothing). The first
  update **snaps**.
- Receivers keep `_physics_process` off until the first update arrives.
- Cheap checks first: `if do_broadcast and has_active_session()`, not the reverse, so the
  property read is skipped on most frames.
- Send only what's visible (position + flip flag), not full rotation, if the visual doesn't
  need it.
- A handful of avatars at every frame is fine. 100+ entities at every frame isn't (6000+ RPCs/s ×
  peers).
- For many entities, consider batching into one replicator RPC with Packed arrays. Godot doesn't
  coalesce RPCs. The source didn't need this yet.

**Templates:** `net_npc.gd`.

---

## P9 — Reliable state with echo guard

```gdscript
var current_state: State = State.IDLE:
    set(value):
        if value == current_state: return
        current_state = value
        if is_multiplayer_authority() and SteamNetwork.has_active_session():
            _broadcast_state.rpc(value)          # only the authority broadcasts

@rpc("authority", "reliable", "call_remote")
func _broadcast_state(s: State) -> void:
    current_state = s                            # same setter; guard prevents echo
```

**Rules:** reliable (a lost transition leaves a client stuck). The `is_multiplayer_authority()`
guard in the setter stops the receiver from re-broadcasting. Clients use state for
animation/visuals only, never to make decisions.

---

## P10 — Owner prediction + soft reconciliation

**When:** the local player's own avatar must feel instant, but the host stays authoritative.

| Machine | `freeze` | Simulates | On host snapshot |
|---|---|---|---|
| Host (any avatar) | false | yes, authoritative | n/a (`call_remote`) |
| Owning client | false | yes, prediction with same inputs | store as reconcile target |
| Other clients | **true** | no | apply directly |

```gdscript
# inside _integrate_forces, after the movement model, owner client only:
var error := target_pos - state.transform.origin
if error.length() > snap_distance:            # fresh spawn / long packet loss → snap
    state.transform = Transform3D(Basis.from_euler(target_rot), target_pos); return
var w := 1.0 - exp(-rate * 60.0 * delta)      # frame-rate-independent blend
state.transform = Transform3D(state.transform.basis.slerp(Basis.from_euler(target_rot), w),
                              state.transform.origin + error * w)
state.linear_velocity = state.linear_velocity.lerp(target_lin_vel, w)
```

**Rules**
- **Not rollback.** No input buffer, no re-simulation, because physics isn't deterministic across
  machines. Just an exponential pull.
- Apply corrections **inside `_integrate_forces`**, not in the RPC callback, so they don't fight
  the physics step.
- `slerp` the basis; don't subtract Euler angles (wraps at ±π).
- Guard reconciliation until the first snapshot arrives (`_reconcile_pending`), or a fresh avatar
  gets pulled toward `Vector3.ZERO`.
- Source values: `reconcile_correction_rate = 0.15`, `reconcile_snap_distance = 5.0 m`.
  Tuned by reasoning, not live-measured.
- Prediction is for **movement only**. Combat, casting, and pickups stay request → validate →
  broadcast (P2).
- Side effect: the predicting client collides locally against other avatars' last-received
  (frozen) positions. That reads as responsive; the host still has the final word.

**Templates:** `net_player_body.gd`.

---

## P11 — Input relay

```gdscript
# owner, every physics frame, if not host:
_submit_input.rpc_id(1, move_input, buttons, stance)

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _submit_input(move: Vector2, buttons: int, stance: int) -> void:
    if not is_inside_tree(): return
    if multiplayer.get_remote_sender_id() != owner_peer_id: return
    move_input = move; _buttons = buttons; _stance = stance
```

**Rules**
- **Every value the authoritative simulation reads must be in the relay.** The source shipped
  with `stance` missing, so the host simulated every client with the default stance.
- Values the receiver *displays* but doesn't simulate (speed readouts) are **derived** on the
  receiver from replicated state (e.g. `linear_velocity.dot(forward)`), not added to the payload.
- `unreliable_ordered`: losing a packet is fine, but reordering would replay a stale stick
  position.
- Sender-check against the owner.

---

## P12 — Autoload-routed flow control

```gdscript
# SceneRouter (autoload)
func goto_screen_for_everyone(s: Screen) -> void:
    if not SteamNetwork.has_active_session(): goto_screen(s); return
    _networked_goto_screen.rpc(s)

@rpc("authority", "reliable", "call_local")
func _networked_goto_screen(s: Screen) -> void:
    goto_screen(s)
```

**Rules**
- Autoloads exist at the same path on every peer from boot, so these RPCs can't race scene
  loads.
- Cross-screen data (submissions, points, round) lives in autoloads. Scene nodes are freed on
  every change.
- Match-state RPCs that **must not** run together get separate RPCs. Example: "advance round"
  vs "reset match", where reset also clears points.
- `Screen` enum is **append-only**. Exported enums serialize as ints in `.tscn`.
- Per-machine session data (e.g. a pool only the host reads) is cleared on every peer at
  "new match", via a separate `call_remote` RPC plus a local clear on the host.

**Templates:** `scene_router.gd`.

---

## P13 — Ready gate

**When:** a transition where entering early is visibly wrong (a gameplay round).

1. Every peer does its local work (threaded load, asset bakes, warm spawn).
2. Peer reports ready: host locally; client via P3 with an ack.
3. Host counts against `SteamNetwork.full_roster()`; broadcasts `"Players ready X / Y"`.
4. All ready → host broadcasts advance (`call_local`). An `_advancing` flag prevents double-fire.
5. `peer_disconnected` → drop from the wait set and **re-check**, so a leaver can't stall
   everyone.
6. Bound local waits with a timeout and proceed degraded rather than hang.

**Templates:** `loading_gate.gd`.

---

## P14 — Warm scene swap (advanced)

**When:** spawning and initial sync should finish *before* the player sees the scene.

1. In the loading gate: `var scene := packed.instantiate()`, set `scene.name = FIXED_NAME`,
   remove any stale node with that name **synchronously**, then `get_tree().root.add_child(scene)`.
   It now runs for real, covered by the opaque loading UI. Its first camera auto-activates, so
   shaders compile during loading.
2. Wait for "my avatar spawned" (`spawner.is_spawned(my_id)` + `player_spawned`) and, on
   clients, entity `catch_up_complete`. Check current state too, since signals only report future
   changes. Bound by a timeout.
3. Report ready (P13). On advance, every peer calls
   `SceneRouter.swap_in_preloaded_scene(screen, scene)`. **Not** `goto_screen_for_everyone`,
   which would throw the warm instance away.

**Pitfall:** the scene's authored root name ("Node3D") collides with the previous round's
still-queued-for-deletion root on *some* peers. Godot renames it `Node3D2` there, and every RPC
path then differs between peers. Always force a fixed name.

**Trade-off:** the hidden scene processes input, so a player can start moving before the reveal.
Pausing it would also pause the Timers the spawn handshake needs.

---

## P15 — Host-only roster

```gdscript
SteamNetwork.full_roster()   # [my_id] + multiplayer.get_peers()
```

Only complete **on the host**. A client's `get_peers()` reliably contains only the host. Turn
order, ready counts, and results rows are built on the host and sent. For deterministic ordering
with ties, sort with an explicit tie-break (original roster index); `sort_custom` isn't stable.

---

## P16 — Broadcast the fact, apply local slices

**When:** a host-decided outcome changes **per-machine local state** (inventory, owned items,
save data) that only one machine holds.

```gdscript
@rpc("authority", "reliable", "call_local")
func _broadcast_pick(picker: int, item_path: String, pool: PackedStringArray, turn: int) -> void:
    _pool = Array(pool); _turn = turn                 # shared view: everyone
    if picker == SteamNetwork.local_peer_id():         # local slice: only the picker
        Inventory.add(load(item_path))
```

**Corollary (owner submits its own data):** when per-machine data must reach the host (a player's
*modified* item), **only the owner** sends it (`rpc_id(1, serialized)`). Other peers' copies of
"your" data may be stale. In the source, each peer released its own stale copy of everyone's fish,
and modified fish never appeared.

---

## P17 — Local cosmetic reaction

Audio, VFX, camera shake, and UI flashes are triggered **locally** from state each peer already
receives: a state change, a spawn, a broadcast action. Don't add "play_sound" RPCs. That doubles
the traffic and creates ordering bugs between the sound and the event.

---

## P18 — Teardown guards

```gdscript
@rpc("authority", "unreliable", "call_remote")
func _broadcast_transform(...) -> void:
    if not is_inside_tree(): return            # packet arrived mid-teardown

func _integrate_forces(state) -> void:
    if not is_inside_tree(): return            # physics server can call once more

func _target_valid() -> bool:
    return target != null and is_instance_valid(target)   # `!= null` misses freed objects
```

Apply to: every unreliable RPC receiver, every high-frequency reliable receiver, every physics
callback on a networked body, and every stored reference to another networked node.

---

## P19 — Broadcast before emit

If emitting a local signal can (synchronously) free the node, for example "returned" → handler
clears the line → `queue_free` + despawn RPC, then **send the network broadcast first and emit
second**. Otherwise the despawn RPC overtakes the event RPC, the receiver frees the node, and the
event is dropped. In the source, joiners never received any catch for this reason.
