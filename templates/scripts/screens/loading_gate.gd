# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     loading_gate.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Control
class_name LoadingGate
## Every peer loads the next scene locally; nobody enters it until EVERY peer is ready.
##
## Flow: background-load [member target_screen]'s scene -> report ready to the host -> host
## counts reports against [method SteamNetwork.full_roster] -> host broadcasts advance.[br]
## A peer that disconnects mid-load is dropped from the wait set so it can't stall everyone.[br]
## Solo is the roster-of-one case of the same logic -- no separate path.[br]
## Holding [member _preloaded] keeps the loaded PackedScene in ResourceLoader's cache, so the
## final [code]change_scene_to_file()[/code] is warm. For a deeper warm-up (instantiate the
## scene hidden, let spawners finish, then [method SceneRouter.swap_in_preloaded_scene]), see
## docs/multiplayer/04_PATTERNS.md, "Warm scene swap" -- and its fixed-name pitfall.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## Screen every peer advances to once all are ready.
@export var target_screen: SceneRouter.Screen = SceneRouter.Screen.GAMEPLAY

var _preloaded: PackedScene = null
var _scene_path: String = ""
var _local_ready: bool = false
var _acked: bool = false  # client only: host confirmed our ready report
var _ready_peers: Dictionary[int, bool] = {}  # host only
var _advancing: bool = false  # host only
var _status_label: Label
var _ready_label: Label


func _ready() -> void:
	_build_ui()
	if SteamNetwork.is_authoritative() and SteamNetwork.has_active_session():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_scene_path = SceneRouter.SCREEN_PATHS.get(target_screen, "")
	if _scene_path == "" or ResourceLoader.load_threaded_request(_scene_path) != OK:
		NetLog.warn(
			NetLog.Category.LOADING,
			"Threaded load unavailable for '%s' -- reporting ready cold" % _scene_path
		)
		_report_ready()
		return
	set_process(true)


func _process(_delta: float) -> void:
	var progress: Array = []
	var status: ResourceLoader.ThreadLoadStatus = (
		ResourceLoader.load_threaded_get_status(_scene_path, progress)
	)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		var fraction: float = progress[0] if not progress.is_empty() else 0.0
		_status_label.text = "Loading... %d%%" % int(fraction * 100.0)
		return
	set_process(false)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		_preloaded = ResourceLoader.load_threaded_get(_scene_path) as PackedScene
	else:
		NetLog.warn(NetLog.Category.LOADING, "Threaded load failed (%d) -- will load cold" % status)
	_report_ready()


func _report_ready() -> void:
	if _local_ready:
		return
	_local_ready = true
	_status_label.text = (
		"Ready -- waiting for other players..." if SteamNetwork.has_active_session() else "Ready..."
	)
	if SteamNetwork.is_authoritative():
		_mark_ready(SteamNetwork.local_peer_id())
		return
	# Retried: a fast client can finish loading before the host's own copy of this node exists.
	var retry := NetRetry.new()
	retry.label = "loading ready report"
	add_child(retry)
	retry.start(func() -> void: _client_ready.rpc_id(1), func() -> bool: return _acked)


@rpc("any_peer", "reliable", "call_remote")
func _client_ready() -> void:
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	_ready_ack.rpc_id(sender_id)
	_mark_ready(sender_id)


@rpc("authority", "reliable", "call_remote")
func _ready_ack() -> void:
	_acked = true


## Host only. Idempotent.
func _mark_ready(peer_id: int) -> void:
	if _ready_peers.has(peer_id):
		return
	_ready_peers[peer_id] = true
	var roster: Array[int] = SteamNetwork.full_roster()
	NetLog.info(
		NetLog.Category.LOADING,
		"Peer %d ready (%d/%d)" % [peer_id, _ready_peers.size(), roster.size()]
	)
	if SteamNetwork.has_active_session():
		_show_ready_count.rpc(_ready_peers.size(), roster.size())
	_check_all_ready()


func _check_all_ready() -> void:
	if _advancing:
		return
	for peer_id: int in SteamNetwork.full_roster():
		if not _ready_peers.has(peer_id):
			return
	_advancing = true
	NetLog.info(NetLog.Category.LOADING, "All peers ready -- advancing")
	if SteamNetwork.has_active_session():
		_advance.rpc()
	else:
		_advance()


func _on_peer_disconnected(peer_id: int) -> void:
	_ready_peers.erase(peer_id)
	_check_all_ready()


@rpc("authority", "reliable", "call_local")
func _show_ready_count(ready_count: int, total: int) -> void:
	_ready_label.text = "Players ready: %d / %d" % [ready_count, total]


@rpc("authority", "reliable", "call_local")
func _advance() -> void:
	SceneRouter.goto_screen(target_screen)


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.16)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_CENTER)
	add_child(layout)
	_status_label = Label.new()
	_status_label.text = "Loading..."
	layout.add_child(_status_label)
	_ready_label = Label.new()
	_ready_label.visible = SteamNetwork.has_active_session()
	layout.add_child(_ready_label)
