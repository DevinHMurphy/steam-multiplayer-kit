# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_player_spawner.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
class_name NetPlayerSpawner
## Spawns one player avatar per peer -- solo, host, and clients all through the same path.
##
## [b]Client-requested, not host-pushed:[/b] each client sends [method _request_spawn] once ITS
## copy of this node exists (with [NetRetry], since the host may not have loaded the scene yet).
## The host then spawns the requester everywhere and catches the requester up on every existing
## avatar at its CURRENT position. Host-pushed spawning races scene loading and silently drops.[br]
## [b]Loadout:[/b] per-machine choices (cosmetics, equipment) travel as a Dictionary of plain
## Variants -- resource PATHS, Colors, ints -- never Resources. See [method _local_loadout].[br]
## [b]Player scene contract:[/b] root exposes [code]owner_peer_id: int[/code]; optional
## [code]apply_loadout(loadout: Dictionary)[/code]. See [NetPlayerBody].[br]
## [b]Naming:[/b] avatars are named [code]Player_<peer_id>[/code] BEFORE [code]add_child()[/code]
## so every peer resolves the same NodePath for RPCs.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## [param peer_id]'s avatar entered the tree on this machine.
signal player_spawned(peer_id: int, player: Node3D)

## Avatar scene instantiated for every player, solo included. One scene, no solo variant.
@export var player_scene: PackedScene
## Parent the avatars are added under. Must exist at the same path on every peer.
@export var spawn_parent: Node
## Spawn locations, used round-robin by [method _pick_spawn_position]. Empty: world origin.
@export var spawn_points: Array[Node3D] = []

var _spawned: Dictionary[int, Node3D] = {}
var _spawn_index: int = 0


func _ready() -> void:
	if SteamNetwork.is_authoritative():
		NetLog.info(NetLog.Category.SPAWN, "PlayerSpawner ready as host/solo")
		if SteamNetwork.has_active_session():
			multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		# Deferred so every sibling's _ready() (level setup, spawn point generation) has run.
		_spawn_for_peer.call_deferred(SteamNetwork.local_peer_id(), _local_loadout())
		return

	NetLog.info(NetLog.Category.SPAWN, "PlayerSpawner ready as client, requesting spawn")
	var retry := NetRetry.new()
	retry.label = "player spawn request"
	add_child(retry)
	retry.start(
		func() -> void: _request_spawn.rpc_id(1, _local_loadout()),
		func() -> bool: return _spawned.has(SteamNetwork.local_peer_id())
	)


## Whether [param peer_id]'s avatar exists on this machine. Poll this for state that predates a
## [signal player_spawned] connection.
func is_spawned(peer_id: int) -> bool:
	return _spawned.has(peer_id)


## [param peer_id]'s avatar on this machine, or null.
func get_player(peer_id: int) -> Node3D:
	return _spawned.get(peer_id, null)


## THIS machine's loadout, sent to the host. Override in a subclass; keep values wire-safe
## (String paths, Color, int, float, bool, Packed arrays).
func _local_loadout() -> Dictionary:
	return {}


## Host-authoritative spawn point, rolled once here and sent to everyone. Never let each peer
## roll its own -- they'd disagree.
func _pick_spawn_position() -> Vector3:
	if spawn_points.is_empty():
		return Vector3.ZERO
	var point: Node3D = spawn_points[_spawn_index % spawn_points.size()]
	_spawn_index += 1
	return point.global_position


func _spawn_for_peer(peer_id: int, loadout: Dictionary) -> void:
	if _spawned.has(peer_id):
		return
	var spawn_position: Vector3 = _pick_spawn_position()
	if SteamNetwork.has_active_session():
		_spawn_player.rpc(peer_id, spawn_position, loadout)
	else:
		_spawn_player(peer_id, spawn_position, loadout)


func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server() and _spawned.has(peer_id):
		_despawn_player.rpc(peer_id)


## Host receives a client's spawn request. Idempotent: retries after success are no-ops.
@rpc("any_peer", "reliable", "call_remote")
func _request_spawn(loadout: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	var requester_id: int = multiplayer.get_remote_sender_id()
	NetLog.info(NetLog.Category.SPAWN, "Host received spawn request from peer %d" % requester_id)
	_spawn_for_peer(requester_id, loadout)
	for existing_id: int in _spawned:
		if existing_id == requester_id:
			continue
		var existing: Node3D = _spawned[existing_id]
		_spawn_player.rpc_id(
			requester_id, existing_id, existing.global_position, _loadout_of(existing)
		)


## Reads an existing avatar's APPLIED loadout back for late-joiner catch-up. Override alongside
## [method _local_loadout] if the avatar can report it.
func _loadout_of(player: Node3D) -> Dictionary:
	if player.has_method(&"get_loadout"):
		return player.call(&"get_loadout")
	return {}


@rpc("authority", "reliable", "call_local")
func _spawn_player(peer_id: int, spawn_position: Vector3, loadout: Dictionary) -> void:
	if _spawned.has(peer_id) or player_scene == null or spawn_parent == null:
		return
	var player: Node3D = player_scene.instantiate() as Node3D
	player.set(&"owner_peer_id", peer_id)
	player.name = "Player_%d" % peer_id
	spawn_parent.add_child(player)
	player.global_position = spawn_position
	if player.has_method(&"apply_loadout"):
		player.call(&"apply_loadout", loadout)
	_spawned[peer_id] = player
	NetLog.info(NetLog.Category.SPAWN, "Spawned player %d at %s" % [peer_id, spawn_position])
	player_spawned.emit(peer_id, player)


@rpc("authority", "reliable", "call_local")
func _despawn_player(peer_id: int) -> void:
	var player: Node3D = _spawned.get(peer_id, null)
	_spawned.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()
	NetLog.info(NetLog.Category.SPAWN, "Despawned player %d" % peer_id)
