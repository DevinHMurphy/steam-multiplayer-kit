# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_player_body.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends RigidBody3D
class_name NetPlayerBody
## Host-authoritative player avatar with owner-side prediction and soft reconciliation.
##
## Three roles per instance, decided by [member owner_peer_id] vs. this machine's peer id:[br]
## - [b]Host[/b] (any avatar): runs the real simulation, broadcasts its transform.[br]
## - [b]Owning client[/b]: reads input, relays it to the host, ALSO simulates locally for instant
##   feel, and blends toward the host's snapshots ([method _apply_reconciliation]).[br]
## - [b]Everyone else[/b]: [code]freeze[/code]d; displays the host's broadcast.[br]
## Godot's multiplayer authority stays at its default (1, the host) for every avatar.
## [member owner_peer_id] decides whose INPUT drives it; authority decides who may WRITE state.[br]
## Discrete actions go request -> host validate -> broadcast; see [method request_action].[br]
## Replace [method _read_input] and [method _simulate] with your game's controls and forces.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

# ============================================================
# INPUT MAP SETUP (Project Settings -> Input Map) -- template placeholders, rename to yours:
#   "move_left" / "move_right" / "move_forward" / "move_back" -> movement axis (owner only)
#   "primary_action" -> example discrete action routed through request_action()
# ============================================================

## A discrete action resolved on the host. [param action_id] is game-defined.
signal action_performed(action_id: int, target: Vector3)

## Godot peer id whose input drives this avatar. Set by the spawner BEFORE add_child().[br]
## [b]Default 1:[/b] equals [code]multiplayer.get_unique_id()[/code] with no peer, so solo play
## needs no special case.
@export var owner_peer_id: int = 1
## False: never read local input, even on the owning machine (menu previews, replays).
@export var accept_input: bool = true

@export_group("Simulation")
## Thrust applied per unit of forward input.[br]
## [b]Units:[/b] newtons. Placeholder value -- tune for your game.
@export var move_force: float = 20.0
## Yaw torque per unit of turn input.[br]
## [b]Units:[/b] newton-meters. Placeholder value -- tune for your game.
@export var turn_torque: float = 6.0

@export_group("Replication")
## Broadcast the authoritative transform every N physics frames. 1 = every frame (the source
## project's setting for a handful of avatars). Raise to 2-4 with many avatars.
@export_range(1, 10) var broadcast_every_n_frames: int = 1
## Fraction of prediction error corrected per 1/60 s. [b]0.0:[/b] never correct.
## [b]1.0:[/b] hard snap every snapshot (jittery). Source-project value: 0.15.
@export_range(0.0, 1.0) var reconcile_correction_rate: float = 0.15
## Error beyond which reconciliation snaps instead of blending (fresh spawn, packet loss).[br]
## [b]Units:[/b] meters. Source-project value: 5.0.
@export var reconcile_snap_distance: float = 5.0
@export_group("")

## Latest movement input. On the host this is the owner's relayed value, not local keys.
var move_input: Vector2 = Vector2.ZERO

var _frame_count: int = 0
var _reconcile_pending: bool = false
var _reconcile_position: Vector3 = Vector3.ZERO
var _reconcile_rotation: Vector3 = Vector3.ZERO
var _reconcile_linear_velocity: Vector3 = Vector3.ZERO
var _reconcile_angular_velocity: Vector3 = Vector3.ZERO


func _ready() -> void:
	freeze = not (is_host() or is_predicting_locally())
	NetLog.info(
		NetLog.Category.MOVEMENT,
		"Player '%s' ready: owner=%d me=%d local=%s host=%s freeze=%s"
		% [name, owner_peer_id, multiplayer.get_unique_id(), is_local_player(), is_host(), freeze]
	)


## This machine's keyboard drives this avatar.
func is_local_player() -> bool:
	return multiplayer.get_unique_id() == owner_peer_id


## This machine runs the authoritative simulation (host, or solo).
func is_host() -> bool:
	return multiplayer.get_unique_id() == 1


## Owning client that is not the host: simulates locally and reconciles.
func is_predicting_locally() -> bool:
	return is_local_player() and not is_host()


## Asks the host to perform a discrete action (attack, use, cast). Instant on host/solo; relayed
## otherwise. Never apply the result locally on a client -- wait for the broadcast.
func request_action(action_id: int, target: Vector3) -> void:
	if not SteamNetwork.has_active_session():
		_perform_action(action_id, target)
	elif is_host():
		_perform_action.rpc(action_id, target)
	else:
		_request_action.rpc_id(1, action_id, target)


func _physics_process(_delta: float) -> void:
	if is_local_player() and accept_input:
		move_input = _read_input()
		if not is_host():
			_submit_input.rpc_id(1, move_input)

	_frame_count += 1
	var do_broadcast: bool = _frame_count % broadcast_every_n_frames == 0
	if do_broadcast and is_host() and SteamNetwork.has_active_session():
		_broadcast_transform.rpc(
			global_position, global_rotation, linear_velocity, angular_velocity
		)


## Local input sample. Called only on the owning machine. Replace with your controls.
func _read_input() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_back", &"move_forward")


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not (is_host() or is_predicting_locally()):
		return
	if not is_inside_tree():
		return  # physics-server callback can fire once more during scene teardown
	_simulate(state, state.get_step())
	if is_predicting_locally():
		_apply_reconciliation(state, state.get_step())


## The movement model. Runs on the host (authoritative) and the owning client (prediction) with
## the same inputs. Replace with your game's forces.
func _simulate(state: PhysicsDirectBodyState3D, _delta: float) -> void:
	var forward: Vector3 = -state.transform.basis.z
	state.apply_central_force(forward * move_input.y * move_force)
	state.apply_torque(Vector3.UP * -move_input.x * turn_torque)


## Exponential pull toward the host snapshot -- NOT rollback/replay. Physics engines (Jolt
## included) are not bit-identical across machines, so re-simulation would not converge anyway.
func _apply_reconciliation(state: PhysicsDirectBodyState3D, delta: float) -> void:
	if not _reconcile_pending:
		return
	var error: Vector3 = _reconcile_position - state.transform.origin
	if error.length() > reconcile_snap_distance:
		state.transform = Transform3D(Basis.from_euler(_reconcile_rotation), _reconcile_position)
		state.linear_velocity = _reconcile_linear_velocity
		state.angular_velocity = _reconcile_angular_velocity
		_reconcile_pending = false
		return
	var weight: float = 1.0 - exp(-reconcile_correction_rate * 60.0 * delta)
	var target_basis: Basis = Basis.from_euler(_reconcile_rotation)
	var new_basis: Basis = state.transform.basis.slerp(target_basis, weight)
	state.transform = Transform3D(new_basis, state.transform.origin + error * weight)
	state.linear_velocity = state.linear_velocity.lerp(_reconcile_linear_velocity, weight)
	state.angular_velocity = state.angular_velocity.lerp(_reconcile_angular_velocity, weight)


## Owner -> host, every physics frame. unreliable_ordered: stale input is worthless, but out-of-
## order input would replay an old stick position. Sender-checked against the owner.
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _submit_input(new_move_input: Vector2) -> void:
	if not is_inside_tree():
		return
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		NetLog.warn(
			NetLog.Category.MOVEMENT,
			"Rejected input for '%s' from peer %d" % [name, multiplayer.get_remote_sender_id()]
		)
		return
	move_input = new_move_input


## Host -> everyone else. Owning client queues it for reconciliation; others apply directly.
@rpc("authority", "unreliable", "call_remote")
func _broadcast_transform(pos: Vector3, rot: Vector3, lin_vel: Vector3, ang_vel: Vector3) -> void:
	if not is_inside_tree():
		return
	if is_predicting_locally():
		_reconcile_position = pos
		_reconcile_rotation = rot
		_reconcile_linear_velocity = lin_vel
		_reconcile_angular_velocity = ang_vel
		_reconcile_pending = true
		return
	global_position = pos
	global_rotation = rot
	linear_velocity = lin_vel
	angular_velocity = ang_vel


@rpc("any_peer", "reliable", "call_remote")
func _request_action(action_id: int, target: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		NetLog.warn(
			NetLog.Category.ACTION,
			"Rejected action for '%s' from peer %d" % [name, multiplayer.get_remote_sender_id()]
		)
		return
	if not _validate_action(action_id, target):
		return
	_perform_action.rpc(action_id, target)


## Host-side legality check (cooldown, range, state). Never trust the client's claim.
func _validate_action(_action_id: int, _target: Vector3) -> bool:
	return true


## Runs identically on every peer. Spawned nodes get deterministic names (owner + sequence).
@rpc("authority", "reliable", "call_local")
func _perform_action(action_id: int, target: Vector3) -> void:
	NetLog.info(
		NetLog.Category.ACTION, "'%s' performed action %d at %s" % [name, action_id, target]
	)
	action_performed.emit(action_id, target)
