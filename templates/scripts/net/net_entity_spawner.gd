# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_entity_spawner.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
class_name NetEntitySpawner
## Replicates a host-owned population of non-player entities (NPCs, pickups, projectiles).
##
## Only the host decides what exists. Each entity gets a host-assigned [code]entity_id[/code],
## is named [code]Entity_<id>[/code] before [code]add_child()[/code] (identical NodePath on every
## peer), and is described on the wire by [code]spawn_data[/code] -- a Dictionary of plain values
## the receiver resolves against ITS OWN shipped resources. Never send a Resource.[br]
## [b]Two delivery paths:[/b] live spawns broadcast to already-connected peers (an optimization);
## a client-requested catch-up with an explicit ack (the completeness guarantee for late or slow
## loaders). Receivers dedupe by id, so overlap between the two is harmless.[br]
## Override [method _serialize_entity] and [method _apply_spawn_data] for your entity type.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## [param entity] entered the tree on this machine (host original or client replica).
signal entity_spawned(entity_id: int, entity: Node3D)
## Client only: the host's catch-up reply has fully arrived.
signal catch_up_complete()

## Scene instantiated for every entity on every peer.
@export var entity_scene: PackedScene
## Parent entities are added under. Must exist at the same path on every peer.
@export var spawn_parent: Node

## Client only: true once the catch-up acknowledgement lands. Host/solo never sets it.
var client_synced: bool = false

var _entities: Dictionary[int, Node3D] = {}  # every peer: entity_id -> live instance
## Client only: every id ever received. Never cleared, so a catch-up reply that crosses a
## despawn in flight can't resurrect an entity the host already removed.
var _seen_ids: Dictionary[int, bool] = {}
var _next_entity_id: int = 0  # host only


func _ready() -> void:
	if not SteamNetwork.has_active_session() or multiplayer.is_server():
		return
	var retry := NetRetry.new()
	retry.label = "entity catch-up request"
	add_child(retry)
	retry.start(func() -> void: _request_catch_up.rpc_id(1), func() -> bool: return client_synced)


## HOST/SOLO ONLY. Creates an entity everywhere. [param spawn_data] must be wire-safe.
## Returns the host's instance, or null if called on a client.
func spawn_entity(spawn_data: Dictionary, at: Vector3) -> Node3D:
	if not SteamNetwork.is_authoritative():
		push_warning("NetEntitySpawner: spawn_entity() called on a client -- ignored.")
		return null
	_next_entity_id += 1
	var entity_id: int = _next_entity_id
	var entity: Node3D = _create_local(entity_id, spawn_data, at)
	if SteamNetwork.has_active_session():
		_spawn_remote.rpc(entity_id, spawn_data, at)
	return entity


## HOST/SOLO ONLY. Removes an entity everywhere.
func despawn_entity(entity_id: int) -> void:
	if not SteamNetwork.is_authoritative():
		return
	if SteamNetwork.has_active_session():
		_despawn.rpc(entity_id)
	else:
		_despawn(entity_id)


## This machine's instance for [param entity_id], or null. Use for identity-by-id lookups when
## an RPC refers to an entity.
func find_entity(entity_id: int) -> Node3D:
	var entity: Node3D = _entities.get(entity_id, null)
	return entity if is_instance_valid(entity) else null


## Describes a live entity for catch-up. Default: none. Override to include whatever
## [method _apply_spawn_data] needs (current HP, rolled size, variant path...).
func _serialize_entity(_entity: Node3D) -> Dictionary:
	return {}


## Applies [param spawn_data] to a fresh instance BEFORE it enters the tree. Override.
func _apply_spawn_data(_entity: Node3D, _spawn_data: Dictionary) -> void:
	pass


func _create_local(entity_id: int, spawn_data: Dictionary, at: Vector3) -> Node3D:
	var entity: Node3D = entity_scene.instantiate() as Node3D
	entity.name = "Entity_%d" % entity_id
	entity.set(&"entity_id", entity_id)
	_apply_spawn_data(entity, spawn_data)
	spawn_parent.add_child(entity)
	entity.global_position = at
	_entities[entity_id] = entity
	entity.tree_exiting.connect(func() -> void: _entities.erase(entity_id))
	entity_spawned.emit(entity_id, entity)
	return entity


@rpc("any_peer", "reliable", "call_remote")
func _request_catch_up() -> void:
	if not multiplayer.is_server():
		return
	var requester_id: int = multiplayer.get_remote_sender_id()
	NetLog.info(
		NetLog.Category.SPAWN,
		"Catch-up for peer %d: %d entities" % [requester_id, _entities.size()]
	)
	for entity_id: int in _entities:
		var entity: Node3D = find_entity(entity_id)
		if entity != null:
			_spawn_remote.rpc_id(
				requester_id, entity_id, _serialize_entity(entity), entity.global_position
			)
	_catch_up_done.rpc_id(requester_id)


@rpc("authority", "reliable", "call_remote")
func _spawn_remote(entity_id: int, spawn_data: Dictionary, at: Vector3) -> void:
	if _seen_ids.has(entity_id):
		return  # live broadcast and catch-up overlapped, or already despawned -- dedupe
	_seen_ids[entity_id] = true
	_create_local(entity_id, spawn_data, at)


@rpc("authority", "reliable", "call_remote")
func _catch_up_done() -> void:
	client_synced = true
	catch_up_complete.emit()


@rpc("authority", "reliable", "call_local")
func _despawn(entity_id: int) -> void:
	var entity: Node3D = find_entity(entity_id)
	if entity != null:
		entity.queue_free()
