# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_npc.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node3D
class_name NetNpc
## Host-simulated AI entity, replicated cheaply enough for 100+ concurrent instances.
##
## [b]Host:[/b] runs the state machine; broadcasts position at a throttled, evenly STAGGERED
## rate (unreliable) and every state change once (reliable).[br]
## [b]Clients:[/b] no decisions at all; ease toward the last received position every frame.
## Physics processing stays off until the first update arrives.[br]
## Spawn through [NetEntitySpawner], which assigns [member entity_id] and the node name.[br]
## Replace [method _think] with your AI.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## Behavioral states. Replicated reliably; clients use them for animation only.
enum State {
	## Spawned, not yet ticked.
	IDLE = 0,
	## Moving toward [member _target_position].
	WANDER = 1,
	## Example placeholder -- add your own states.
	ALERT = 2,
}

## Physics frames per staggered broadcast cycle. 60 Hz / 4 = 15 Hz per entity.
const BROADCAST_GROUPS: int = 4

## Explicit counter, not [code]get_instance_id() % N[/code] -- instance ids are allocated with a
## stride that can share a factor with N and put every entity in one bucket.
static var _next_broadcast_group: int = 0

## Host-assigned network identity. Set by the spawner before add_child(); identical on all peers.
@export var entity_id: int = 0
## Client-side easing toward received positions. Higher tracks tighter, lower is smoother.[br]
## [b]Units:[/b] 1/second. Placeholder value -- tune by eye at your broadcast rate.
@export var remote_smoothing_speed: float = 10.0
## Movement speed while wandering.[br]
## [b]Units:[/b] meters per second. Placeholder value.
@export var move_speed: float = 2.0

## Replicated state. Only the authority's own changes are broadcast -- the guard is what stops a
## client's received assignment from echoing back out.
var current_state: State = State.IDLE:
	set(value):
		if value == current_state:
			return
		current_state = value
		if is_multiplayer_authority() and SteamNetwork.has_active_session():
			_broadcast_state.rpc(value)

var _frame_count: int = 0
var _broadcast_group: int = 0
var _has_remote_target: bool = false
var _remote_target: Vector3 = Vector3.ZERO
var _target_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	_broadcast_group = _next_broadcast_group % BROADCAST_GROUPS
	_next_broadcast_group += 1
	if not is_multiplayer_authority():
		set_physics_process(false)  # re-enabled by the first _broadcast_transform


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		global_position = global_position.lerp(
			_remote_target, clampf(delta * remote_smoothing_speed, 0.0, 1.0)
		)
		return

	_frame_count += 1
	_think(delta)

	var do_broadcast: bool = (_frame_count % BROADCAST_GROUPS) == _broadcast_group
	if do_broadcast and SteamNetwork.has_active_session():
		_broadcast_transform.rpc(global_position)


## Host-only AI tick. Replace with your behavior.
func _think(delta: float) -> void:
	if current_state == State.IDLE:
		var offset := Vector3(randf_range(-5.0, 5.0), 0.0, randf_range(-5.0, 5.0))
		_target_position = global_position + offset
		current_state = State.WANDER
	elif current_state == State.WANDER:
		global_position = global_position.move_toward(_target_position, move_speed * delta)
		if global_position.distance_squared_to(_target_position) < 0.01:
			current_state = State.IDLE


@rpc("authority", "unreliable", "call_remote")
func _broadcast_transform(new_position: Vector3) -> void:
	if not is_inside_tree():
		return
	if not _has_remote_target:
		# First update snaps -- easing from the spawn point would visibly slide in.
		global_position = new_position
		_has_remote_target = true
		set_physics_process(true)
	_remote_target = new_position


## Reliable: a dropped state change would leave a client stuck showing the wrong state.
@rpc("authority", "reliable", "call_remote")
func _broadcast_state(new_state: State) -> void:
	current_state = new_state
