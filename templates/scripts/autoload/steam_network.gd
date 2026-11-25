# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     steam_network.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
## Steam lobby host/join, and the bridge from a Steam lobby to Godot's MultiplayerAPI.
##
## Register as autoload [code]SteamNetwork[/code], after [code]SteamManager[/code] and
## [code]NetLog[/code]. Once [code]multiplayer.multiplayer_peer[/code] is a
## [code]SteamMultiplayerPeer[/code], every [code]@rpc[/code] in the project works exactly as it
## would over ENet -- nothing else needs to know Steam is underneath.[br]
## [b]Session/authority helpers:[/b] gameplay code asks [method has_active_session],
## [method is_authoritative], and [method local_peer_id] here instead of re-deriving them, so
## solo play (no lobby) and hosting share one code path.[br]
## [b]Never track "am I host" as a separate flag.[/b] [code]@rpc("authority")[/code] permission
## checks Godot's own [code]multiplayer.is_server()[/code]; a parallel flag can disagree with it.
##
## @tutorial(Kit architecture): res://docs/multiplayer/01_ARCHITECTURE.md

## Steam confirmed (or failed) creating a lobby this machine now hosts.
## [param success]: false on any Steam-side failure; details are logged.
signal lobby_created(success: bool)
## This machine finished joining someone else's lobby as a client.
## [param success]: false if Steam refused the join; details are logged.
signal lobby_joined(success: bool)
## The Steam-side member list changed (join, leave, disconnect). Fires before the
## MultiplayerAPI peer is RPC-ready -- use [signal peer_connected] for gameplay.
signal lobby_members_changed()
## A MultiplayerAPI peer is connected and RPC-ready. [param peer_id]: Godot peer id.
signal peer_connected(peer_id: int)
## A MultiplayerAPI peer left. [param peer_id]: Godot peer id.
signal peer_disconnected(peer_id: int)
## This machine lost its connection to the host; the session has already been torn down.
signal session_ended()

## Steam lobby visibility. FRIENDS_ONLY suits "play with friends" games; use
## [code]Steam.LOBBY_TYPE_PUBLIC[/code] plus lobby data/search for public matchmaking.
const LOBBY_TYPE: int = Steam.LOBBY_TYPE_FRIENDS_ONLY
## SteamMultiplayerPeer virtual port. Host and client must use the same value.
const VIRTUAL_PORT: int = 0
## Default lobby capacity passed to [method host_lobby].
const DEFAULT_MAX_PLAYERS: int = 4

## Steam lobby id this machine is in, or 0 when not in a lobby. Identical on every member, so it
## doubles as a free shared seed (see docs/multiplayer/04_PATTERNS.md, "Shared seed").
var current_lobby_id: int = 0

var _peer: MultiplayerPeer = null


func _ready() -> void:
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	# UNVERIFIED in the source project: overlay "Join Game" / friend invite acceptance.
	Steam.join_requested.connect(_on_join_requested)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# --- Session / authority helpers -----------------------------------------------------------

## True only with a real lobby AND an attached peer. Guard every [code].rpc()[/code] and every
## [code]multiplayer.multiplayer_peer[/code] touch behind this.
func has_active_session() -> bool:
	return current_lobby_id != 0 and multiplayer.multiplayer_peer != null


## True on the host, and always true in solo play. The single gate for "may this machine decide
## shared state?" -- spawning, validation, scoring, round flow.
func is_authoritative() -> bool:
	return not has_active_session() or multiplayer.is_server()


## This machine's Godot peer id: 1 on the host and in solo play, a large random int on clients.
func local_peer_id() -> int:
	return multiplayer.get_unique_id()


## Every connected peer id, this machine's first. [b]Only complete on the host[/b] --
## [code]multiplayer.get_peers()[/code] on a client reliably lists only the host.
func full_roster() -> Array[int]:
	var roster: Array[int] = [multiplayer.get_unique_id()]
	if has_active_session():
		for peer_id: int in multiplayer.get_peers():
			roster.append(peer_id)
	return roster


# --- Lobby lifecycle -----------------------------------------------------------------------

## Creates a Steam lobby; [method _on_lobby_created] then stands this machine up as host.
func host_lobby(max_players: int = DEFAULT_MAX_PLAYERS) -> void:
	if not SteamManager.is_available:
		NetLog.warn(NetLog.Category.LOBBY, "Cannot host, Steam is not available")
		return
	NetLog.info(NetLog.Category.LOBBY, "Creating a lobby (max %d players)..." % max_players)
	Steam.createLobby(LOBBY_TYPE, max_players)


## Joins an existing lobby by numeric id; [method _on_lobby_joined] connects the client peer.
func join_lobby(lobby_id: int) -> void:
	if not SteamManager.is_available:
		NetLog.warn(NetLog.Category.LOBBY, "Cannot join, Steam is not available")
		return
	NetLog.info(NetLog.Category.LOBBY, "Joining lobby %d..." % lobby_id)
	Steam.joinLobby(lobby_id)


## Leaves the lobby and drops the peer. Safe whether hosting, joined, or not in a lobby.
func leave_lobby() -> void:
	if current_lobby_id != 0:
		NetLog.info(NetLog.Category.LOBBY, "Leaving lobby %d" % current_lobby_id)
		Steam.leaveLobby(current_lobby_id)
	current_lobby_id = 0
	_peer = null
	multiplayer.multiplayer_peer = null


## Steam ids of every lobby member (this machine included), in Steam's order. Empty if not in a
## lobby. Steam ids are NOT Godot peer ids -- see docs/multiplayer/01_ARCHITECTURE.md, "Identity".
func get_lobby_members() -> Array[int]:
	var members: Array[int] = []
	if current_lobby_id == 0:
		return members
	var count: int = Steam.getNumLobbyMembers(current_lobby_id)
	for i: int in count:
		members.append(Steam.getLobbyMemberByIndex(current_lobby_id, i))
	return members


## Display name for a Steam id. Remote names come from Steam's cache and may lag a join briefly.
func get_member_name(steam_id: int) -> String:
	if steam_id == Steam.getSteamID():
		return Steam.getPersonaName()
	return Steam.getFriendPersonaName(steam_id)


## Joins the lobby passed on the command line as [code]+connect_lobby <id>[/code] -- what Steam
## does when a friend accepts an invite while the game is NOT running. Call once from boot,
## after [code]SteamManager.initialize()[/code]. Returns true if a join was started.
## UNVERIFIED in the source project.
func join_lobby_from_command_line() -> bool:
	var args: PackedStringArray = OS.get_cmdline_args()
	var index: int = args.find("+connect_lobby")
	if index == -1 or index + 1 >= args.size():
		return false
	var lobby_id: int = args[index + 1].to_int()
	if lobby_id <= 0:
		return false
	join_lobby(lobby_id)
	return true


# --- Steam callbacks -----------------------------------------------------------------------

func _on_lobby_created(connect_result: int, lobby_id: int) -> void:
	if connect_result != Steam.RESULT_OK:
		NetLog.warn(NetLog.Category.LOBBY, "Lobby creation failed (result %d)" % connect_result)
		lobby_created.emit(false)
		return

	current_lobby_id = lobby_id
	var peer := SteamMultiplayerPeer.new()
	peer.create_host(VIRTUAL_PORT)
	_peer = peer
	multiplayer.multiplayer_peer = _peer

	NetLog.info(
		NetLog.Category.LOBBY,
		"Hosting lobby %d -- unique_id=%d is_server=%s"
		% [lobby_id, multiplayer.get_unique_id(), multiplayer.is_server()]
	)
	lobby_created.emit(true)
	lobby_members_changed.emit()


## Steam fires this for EVERY lobby entry, including the creator's own automatic entry right
## after [method _on_lobby_created]. The owner check below is load-bearing: without it the host
## replaces its own server peer with a client peer pointed at itself and loses authority.
func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		NetLog.warn(
			NetLog.Category.LOBBY, "Joining lobby %d failed (response %d)" % [lobby_id, response]
		)
		lobby_joined.emit(false)
		return

	var host_steam_id: int = Steam.getLobbyOwner(lobby_id)
	if host_steam_id == Steam.getSteamID():
		return

	current_lobby_id = lobby_id
	var peer := SteamMultiplayerPeer.new()
	peer.create_client(host_steam_id, VIRTUAL_PORT)
	_peer = peer
	multiplayer.multiplayer_peer = _peer

	NetLog.info(
		NetLog.Category.LOBBY,
		"Joined lobby %d (host %d) -- unique_id=%d is_server=%s"
		% [lobby_id, host_steam_id, multiplayer.get_unique_id(), multiplayer.is_server()]
	)
	lobby_joined.emit(true)
	lobby_members_changed.emit()


func _on_lobby_chat_update(
	_lobby_id: int, _changed_id: int, _making_change_id: int, _chat_state: int
) -> void:
	lobby_members_changed.emit()


## Friend accepted an invite / clicked "Join Game" while the game IS running.
## UNVERIFIED in the source project -- confirm the argument order on first live test.
func _on_join_requested(lobby_id: int, _friend_steam_id: int) -> void:
	if current_lobby_id != 0:
		leave_lobby()
	join_lobby(lobby_id)


# --- MultiplayerAPI callbacks --------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	NetLog.info(
		NetLog.Category.LOBBY,
		"Peer %d connected (my unique_id=%d, is_server=%s)"
		% [peer_id, multiplayer.get_unique_id(), multiplayer.is_server()]
	)
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	NetLog.info(NetLog.Category.LOBBY, "Peer %d disconnected" % peer_id)
	peer_disconnected.emit(peer_id)


func _on_connected_to_server() -> void:
	NetLog.info(
		NetLog.Category.LOBBY, "Connected to host (my unique_id=%d)" % multiplayer.get_unique_id()
	)


func _on_connection_failed() -> void:
	NetLog.error(NetLog.Category.LOBBY, "Connection to host failed")


func _on_server_disconnected() -> void:
	NetLog.warn(NetLog.Category.LOBBY, "Disconnected from host")
	leave_lobby()
	session_ended.emit()
