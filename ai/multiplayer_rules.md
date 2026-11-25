---
paths:
  - "**/*.gd"
  - "**/*.tscn"
---

# Multiplayer Rules (Steam / GodotSteam, host-authoritative)

Applies to any change that touches networking: `@rpc`, spawning, replication, session state,
screen flow, or anything that must look the same on every peer. Full docs are in
`docs/multiplayer/`. Read `04_PATTERNS.md` before writing a new networked feature, and
`05_PITFALLS.md` before debugging one.

## Model (do not change without explicit approval)

- Host-authoritative listen server over `SteamMultiplayerPeer`. Host = peer id **1**.
- The host simulates everything shared. Clients send input and requests, and display results.
- The owning client predicts only its **own avatar's movement**, with soft reconciliation.
  Everything else on clients is display-only.
- No lockstep or rollback: physics isn't deterministic across machines.
- Solo = a session of one. Same code paths, direct calls instead of `.rpc()`.
- Multiplayer authority stays **1** on every node. `owner_peer_id` marks whose input drives an
  avatar. Never `set_multiplayer_authority()` to a client.

## Must

1. Gate decisions with `SteamNetwork.is_authoritative()`. Gate every `.rpc()` and every
   `multiplayer.multiplayer_peer` touch with `SteamNetwork.has_active_session()`, with a direct
   call in the `else` branch.
2. Client-triggered effects follow **request → host validates → `call_local` broadcast**. The
   client does not apply the effect locally first.
3. Every `@rpc("any_peer")` host handler starts with `if not multiplayer.is_server(): return`,
   and checks `multiplayer.get_remote_sender_id() == owner_peer_id` wherever ownership applies.
   Re-run every legality check host-side.
4. Anything a client needs when its scene loads is **client-requested with retry** (`NetRetry`)
   and acknowledged. The host never pushes initial state from its own `_ready()`.
5. Every node an RPC targets gets a **deterministic name before `add_child()`**:
   `Player_<peer>`, `Entity_<id>`, `<Kind>_<owner>_<seq>`, or a fixed constant for manually
   added scene roots.
6. RPC payloads are plain data: ids, resource **paths**, numbers, Colors, Packed arrays. Never
   `Resource`s. Use `""` for "none".
7. Random per-instance values are rolled once on the host and sent. Shared layout derives from a
   seed every peer computes (lobby id, plus round number).
8. Channels: continuous → `unreliable`; owner input → `unreliable_ordered`; spawns, state,
   actions, scores, flow → `reliable`.
9. Every value the authoritative simulation reads is either local input on the host or in the
   input relay.
10. `is_inside_tree()` guard at the top of every unreliable/high-rate RPC receiver and of
    `_integrate_forces` on networked bodies. `is_instance_valid()` (not `!= null`) on stored
    references to other networked nodes.
11. If a local signal emission can free the node, **broadcast first, emit second**.
12. Cross-screen data lives in autoloads. Screen changes for everyone go through
    `SceneRouter.goto_screen_for_everyone()`.
13. Rosters, turn order, and ready counts are built **on the host** (`SteamNetwork.full_roster()`).
14. Log through `NetLog` with a category. Wrap per-frame `debug` calls in `NetLog.would_log()`.
15. Many moving entities: broadcast ~15 Hz, staggered by an explicit counter, interpolated on
    receivers.
16. Per-machine local state (inventory, save data) is changed only by the machine that owns it,
    in response to a host broadcast.
17. Cosmetic feedback (SFX/VFX/UI) is a local reaction to replicated state. No "play effect"
    RPCs.

## Never

- Track "am I host" in a separate boolean.
- Use `get_instance_id() % N` for stagger buckets.
- Insert mid-enum into an exported enum (`SceneRouter.Screen`). Append only.
- Let a receiver re-roll a random value the host already rolled.
- Fall back to "any avatar" when the local player's avatar isn't spawned yet. Wait for it.
- Call `Steam.*` without checking `SteamManager.is_available`.
- Treat a passing solo or host-only run as proof a networked feature works.

## When asked to add or change a networked feature

1. Say which patterns (P1–P19) apply and which requirement IDs (FR-*) it touches.
2. List every new RPC with permission/mode/local-remote and the reason for each choice.
3. State the solo path explicitly.
4. List the two-machine tests from `06_TESTING_DEBUGGING.md` §2 that cover it, and mark the work
   **untested live** until those run.
5. If the design needs to break a Must/Never rule, stop and ask first.

## When debugging

Ask for **both** machines' `user://logs/godot.log`. Find the first error, not the loudest.
Match symptoms against the index at the bottom of `05_PITFALLS.md`. Add a targeted `NetLog` line
at the decision point rather than shipping a guessed fix.
