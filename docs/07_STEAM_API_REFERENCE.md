# 07 — Steam / GodotSteam API Reference

Every Steam-side call the kit makes, how sure we are of each, and what to do before release.

**Reference versions:** GodotSteam GDExtension **4.21** · Steamworks SDK **1.65** · Godot **4.7.1**.
GodotSteam signatures change between versions. When something throws, check the installed
version's docs **before** anything else ([05_PITFALLS.md](05_PITFALLS.md) #2).

Legend: ✅ confirmed in live runs · 🔵 compiled against 4.21 (symbol exists), behavior from
GodotSteam docs, not live-run · ❓ not used in the source project.

---

## 1. Initialization

| Call | Notes | Status |
|---|---|---|
| `Steam.steamInitEx(app_id: int, embed_callbacks: bool) -> Dictionary` | Returns `{status: int, verbal: String}`. `embed_callbacks = true` means GodotSteam pumps callbacks, so no `run_callbacks()` is needed. | ✅ |
| `Steam.STEAM_API_INIT_RESULT_OK` | Success value for `status`. | ✅ |

Needs: the Steam client running and logged in, plus `steam_appid.txt` for non-Steam launches
(editor, a double-clicked export).

## 2. Lobbies

| Call / signal | Notes | Status |
|---|---|---|
| `Steam.createLobby(type: int, max_members: int)` | Async; result arrives in `lobby_created`. | ✅ |
| `Steam.LOBBY_TYPE_FRIENDS_ONLY` / `LOBBY_TYPE_PUBLIC` / `LOBBY_TYPE_PRIVATE` / `LOBBY_TYPE_INVISIBLE` | Kit uses FRIENDS_ONLY. | ✅ (FRIENDS_ONLY) |
| signal `lobby_created(connect: int, lobby_id: int)` | `connect == Steam.RESULT_OK` (1) on success. The source compared against literal `1`; the kit uses `Steam.RESULT_OK`. | ✅ / 🔵 constant |
| `Steam.joinLobby(lobby_id: int)` | Async; result arrives in `lobby_joined`. | ✅ |
| signal `lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)` | `response == Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS`. **Fires for the creator's own entry too.** | ✅ |
| signal `lobby_chat_update(lobby_id, changed_id, making_change_id, chat_state)` | Any member join/leave/disconnect. Used only as "refresh the member list". | ✅ |
| `Steam.leaveLobby(lobby_id: int)` | | ✅ |
| `Steam.getLobbyOwner(lobby_id) -> int` | The host's Steam ID. Used to connect the client peer and to detect self-join. | ✅ |
| `Steam.getNumLobbyMembers(lobby_id) -> int` / `getLobbyMemberByIndex(lobby_id, i) -> int` | Steam IDs in Steam's order (not join order). | ✅ |
| `Steam.getSteamID() -> int` / `getPersonaName() -> String` / `getFriendPersonaName(steam_id) -> String` | Remote names come from Steam's cache and may lag a join briefly. | ✅ |
| signal `join_requested(lobby_id: int, steam_id: int)` | Overlay "Join Game" / accepted invite **while running**. | 🔵 |
| Launch arg `+connect_lobby <lobby_id>` | Accepted invite while the game **isn't running**. Read via `OS.get_cmdline_args()`. | 🔵 |
| `Steam.setLobbyData` / `getLobbyData` / `setLobbyJoinable` / `requestLobbyList` + `lobby_match_list` | Public matchmaking / lobby browser. Out of scope. | ❓ |

## 3. Transport: `SteamMultiplayerPeer`

| Call | Notes | Status |
|---|---|---|
| `SteamMultiplayerPeer.new()` | Included in the GodotSteam 4.21 GDExtension (no separate addon). | ✅ |
| `peer.create_host(virtual_port: int)` | **No trailing options array.** Host becomes peer id 1. | ✅ |
| `peer.create_client(host_steam_id: int, virtual_port: int)` | Same `virtual_port` as the host. | ✅ |
| `multiplayer.multiplayer_peer = peer` | From here on, plain Godot `@rpc` works. | ✅ |

Traffic goes through Steam's networking, so players don't exchange IPs or forward ports.

## 4. Files & project setup

| Item | Ship it? | Notes |
|---|---|---|
| `addons/godotsteam/` (`godotsteam.gdextension` + per-platform libs) | ✅ yes | The `.gdextension` `[dependencies]` copies `steam_api64.dll` / `libsteam_api.so` / `libsteam_api.dylib` next to the export. |
| `steam_appid.txt` | ❌ **no** | Dev only, gitignored, one per machine. |
| Debug vs release libs | | `template_debug` vs `template_release` are chosen per export type automatically. |
| Editor plugin "GodotSteam GDExtension Updater" | optional | Only updates the addon; not needed at runtime. |

Clean up stray `~*.TMP` files Windows leaves in `addons/godotsteam/win64/` when the editor holds
the DLL during an update. They're harmless but noisy in git.

## 5. Release checklist

- [ ] Real Steamworks App ID obtained; `SteamManager.DEV_APP_ID` replaced (or passed to
      `initialize()`).
- [ ] `steam_appid.txt` **not** included in the build or depot.
- [ ] Game launched **through Steam** at least once on a clean machine (no `steam_appid.txt`).
- [ ] Overlay invite tested both ways (running / not running): FR-LOBBY-8.
- [ ] Export includes `addons/godotsteam/<platform>` libs (check the export folder for
      `steam_api64.dll` etc.).
- [ ] Debug-only paths (ENet dev transport, debug panels) stripped or gated on
      `OS.is_debug_build()`.
- [ ] `NetLog.min_level` default is INFO (not DEBUG).
- [ ] Lobby type is correct for launch (FRIENDS_ONLY vs PUBLIC).
- [ ] Two-machine matrix ([06_TESTING_DEBUGGING.md](06_TESTING_DEBUGGING.md) §2) passed on the
      release build.

## 6. Not implemented: Steam platform features (pointers only)

None of these are used in the source project. Names are from GodotSteam's docs and haven't been
verified here. Check them against your installed version before relying on them.

| Feature | Starting points | Fit with this architecture |
|---|---|---|
| Achievements | `Steam.setAchievement(name)`, `Steam.storeStats()` | Trigger **locally on the owning machine** from replicated results (P17/P16). Never from another player's machine. |
| Stats | `Steam.setStatInt/Float`, `Steam.storeStats()` | Same as above. |
| Leaderboards | `Steam.findLeaderboard(name)` → signal → `Steam.uploadLeaderboardScore(...)` | Upload from each player's own machine, using the host-broadcast score. |
| Steam Cloud | `Steam.fileWrite` / `fileRead`, or Auto-Cloud configured in Steamworks for `user://` | Local save data is per-machine anyway; Auto-Cloud is usually enough. |
| Rich Presence | `Steam.setRichPresence(key, value)` | Optional `"connect"` key enables "Join Game" from the friends list. |
