# 06 — Testing & Debugging

Multiplayer bugs are mostly invisible in solo and host-only runs. Budget for two-machine testing
from the first spawned avatar onward.

---

## 1. Test setups

| Setup | What it can test | Limits |
|---|---|---|
| **Solo** (no lobby) | Fallback paths, gameplay logic | Zero network code exercised |
| **Host-only** (lobby, nobody joined) | Steam init, lobby creation, self-join guard (#1), host spawn path | No client paths at all |
| **Two machines, two Steam accounts** | Everything | Needs a second PC (or VM) and account |
| ENet on one machine (optional dev transport) | Everything *except* Steam lobby code | Not provided. See §6 |

> **Two accounts.** Plan on two machines, each logged into a different Steam account. One
> account can't reliably be two members of its own lobby.

Run **byte-identical builds** on both machines: same commit, re-exported or editor-run from the
same files. RPC method indices depend on the scripts ([05_PITFALLS.md](05_PITFALLS.md) #8).

## 2. Two-machine test matrix

Run after any change to networked code. Copy into the PR description.

| # | Scenario | Pass when |
|---|---|---|
| T1 | Solo start → gameplay → 3 rounds | No errors; Steam closed also works |
| T2 | Host-only: host lobby | `unique_id=1 is_server=true`; **no** "Joined lobby" line for own lobby |
| T3 | Join by id | Both member lists update; client `is_server=false`; host logs `Peer N connected` |
| T4 | Host Start | Both pass the loading gate together; "ready 2 / 2" |
| T5 | Spawn | Two avatars on each machine; each moves only its own; client's own feels instant |
| T6 | Client loads **faster** than host | Client still gets its avatar. Simulate by adding a temporary delay to the host's gameplay `_ready()`. |
| T7 | Late join mid-round (if supported) | Joiner sees existing avatars/entities at current positions, once each |
| T8 | Every client control | Each input visibly affects the client's avatar **on the host's screen** |
| T9 | Discrete action from client | Appears on both; host log shows request → broadcast |
| T10 | Forged request | Temporarily call the request RPC for another player's avatar. Host logs "Rejected …" |
| T11 | 3 full rounds | Round numbers match. Zero `Node not found`, `!is_inside_tree`, `null instance` errors in **either** log |
| T12 | Client quits mid-round | Its avatar disappears on the host; the round still completes |
| T13 | Client quits mid-loading | Remaining peers proceed (ready count re-checks) |
| T14 | Host quits | Client returns to a usable lobby screen and can host/join again |
| T15 | Leave lobby → host again | Works without restarting the game |

## 3. Logs

### Where they are

`project.godot [logging]` writes every `print` / `push_warning` / `push_error` to
`user://logs/godot.log`, rotating 5 files:

| OS | Path |
|---|---|
| Windows | `%APPDATA%\Godot\app_userdata\<Project Name>\logs\godot.log` |
| Linux | `~/.local/share/godot/app_userdata/<Project Name>/logs/godot.log` |
| macOS | `~/Library/Application Support/Godot/app_userdata/<Project Name>/logs/godot.log` |

(Paths differ if `application/config/use_custom_user_dir` is set.) After a test, **collect both
machines' files**. Attach both to a bug report or paste both into a prompt.

### Reading them

Every NetLog line is `[LEVEL][Category][peer <id>] message`. The peer id tells you which machine
wrote it, even when logs are interleaved.

Lines worth finding first:

| Line | Proves |
|---|---|
| `Hosting lobby X -- unique_id=1 is_server=true` | Host peer up |
| `Joined lobby X (host H) -- unique_id=N is_server=false` | Client peer up |
| `Peer N connected` (on host) | RPCs can flow |
| `Player 'Player_N' ready: owner=… me=… local=… host=… freeze=…` | The role decision per avatar per machine. Most "can't move" bugs show here. |
| `… acknowledged after N attempt(s)` | A handshake completed. N > 1 is normal (load-order race handled). |
| `… gave up after N attempts` | **Not** a race. Host-side misconfiguration (null export, wrong path). |
| `Rejected …` | Ownership/validation guard fired. Expected only in T10. |

### Turning up the volume

```gdscript
NetLog.min_level = NetLog.Level.DEBUG
NetLog.enabled_categories = [NetLog.Category.ACTION]   # empty = all
```

Set these at runtime through the Remote scene inspector (the `NetLog` autoload), or temporarily
in code. DEBUG on MOVEMENT/ENTITY is per-frame and very loud, so scope it with
`enabled_categories`.

## 4. Debugging playbook

1. **Get both logs.** Never debug a networking bug from one side.
2. **Find the first error, not the loudest.** "Node not found" floods often follow one earlier
   naming or ordering problem.
3. **Check roles.** Do the `owner / me / local / host / freeze` values match the table in
   [04_PATTERNS.md](04_PATTERNS.md) P10?
4. **Check the handshake.** Did "acknowledged" appear? If it gave up, inspect host-side exports.
5. **Check the relay.** For a "control doesn't work" bug, is the value in `_submit_input`?
6. **Check the order.** For a "client never sees event X" bug, does a despawn or free reach the
   client before X? (P19)
7. **Check the remote tree.** In the debugger's Remote tab on each machine, networked node names
   must match exactly. `@Node3D@N` means a naming bug.
8. **Rule out version skew.** Same commit, both machines.
9. **Add a one-line NetLog at the decision point**, not a guessed fix. The source project's
   rule: diagnose from a live log before changing behavior.

## 5. Static review checklist (before running anything)

- [ ] Every `@rpc("any_peer")` handler starts with `if not multiplayer.is_server(): return` (when
      host-targeted) and an owner check where ownership applies.
- [ ] Every `.rpc(` call is inside a `has_active_session()` branch, or the function is only
      reachable with a session.
- [ ] Every networked node gets `.name` before `add_child(`.
- [ ] No `Resource` parameter in any RPC signature.
- [ ] No `randf` / `randi` / `randomize()` in networked entity setup, except shared-seed RNGs.
- [ ] Every unreliable receiver and `_integrate_forces` starts with `is_inside_tree()`.
- [ ] Cross-node references dereferenced through `is_instance_valid`.
- [ ] Data needed after a scene change lives in an autoload.
- [ ] No `is_host` boolean anywhere.
- [ ] Every per-frame `NetLog.debug` is wrapped in `would_log()`.

## 6. Optional: ENet dev transport (one machine, two editor instances)

Not part of the kit, and not tested in the source project. Everything downstream of
`multiplayer.multiplayer_peer` is transport-agnostic, so you can add a dev-only path to
`SteamNetwork`:

```gdscript
const DEV_FAKE_LOBBY_ID: int = 1   # non-zero so has_active_session() is true; also the shared seed

func dev_host_enet(port: int = 7777) -> void:
    var peer := ENetMultiplayerPeer.new()
    peer.create_server(port)
    multiplayer.multiplayer_peer = peer
    current_lobby_id = DEV_FAKE_LOBBY_ID

func dev_join_enet(address: String = "127.0.0.1", port: int = 7777) -> void:
    var peer := ENetMultiplayerPeer.new()
    peer.create_client(address, port)
    multiplayer.multiplayer_peer = peer
    current_lobby_id = DEV_FAKE_LOBBY_ID
```

Then run two instances (Debug → Customize Run Instances → 2). Caveats: lobby UI calls
`Steam.getLobbyOwner` and the member list, so gate those on a real Steam lobby; it doesn't test
Steam relay behavior; strip it from release builds.
