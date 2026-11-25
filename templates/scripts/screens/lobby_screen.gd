# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     lobby_screen.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Control
class_name LobbyScreen
## Steam lobby screen: host, join by id, live member list, host-only Start, Leave.
##
## UI is built in code so the template needs no .tscn wiring -- attach to a bare Control scene
## and register its path as [code]SceneRouter.Screen.LOBBY[/code]. Restyle freely.[br]
## [b]Host-only Start[/b] calls [method SceneRouter.reset_match] then moves everyone to the
## loading gate. Start visibility is keyed off [code]multiplayer.is_server()[/code], the same
## check the RPC permission uses.[br]
## The lobby id is a read-only LineEdit (selectable, Ctrl+C) plus a Copy button. Friends can
## also join through the Steam overlay -- see [method SteamNetwork._on_join_requested].
##
## @tutorial(Implementation guide): res://docs/multiplayer/03_IMPLEMENTATION_GUIDE.md

var _title_label: Label
var _status_label: Label
var _lobby_id_row: HBoxContainer
var _lobby_id_field: LineEdit
var _host_button: Button
var _join_row: HBoxContainer
var _join_input: LineEdit
var _members_list: VBoxContainer
var _start_button: Button
var _leave_button: Button


func _ready() -> void:
	_build_ui()
	SteamNetwork.lobby_created.connect(_on_lobby_entered)
	SteamNetwork.lobby_joined.connect(_on_lobby_entered)
	SteamNetwork.lobby_members_changed.connect(_refresh)
	SteamNetwork.session_ended.connect(_refresh)
	_refresh()


func _on_lobby_entered(success: bool) -> void:
	if not success:
		_status_label.text = "Failed -- see console."
	_refresh()


func _on_join_pressed() -> void:
	var lobby_id: int = _join_input.text.strip_edges().to_int()
	if lobby_id <= 0:
		_status_label.text = "Enter a valid lobby id first."
		return
	SteamNetwork.join_lobby(lobby_id)


func _on_start_pressed() -> void:
	SceneRouter.reset_match()
	SceneRouter.goto_screen_for_everyone(SceneRouter.Screen.LOADING)


func _on_leave_pressed() -> void:
	SteamNetwork.leave_lobby()
	_refresh()


## Single source of truth for every widget's visibility -- derived from live session state, so
## the screen can't drift into a half-updated combination.
func _refresh() -> void:
	var in_lobby: bool = SteamNetwork.current_lobby_id != 0
	var is_host: bool = in_lobby and multiplayer.is_server()

	_host_button.visible = not in_lobby
	_join_row.visible = not in_lobby
	_lobby_id_row.visible = in_lobby
	_start_button.visible = is_host
	_leave_button.visible = in_lobby

	if not SteamManager.is_available:
		_status_label.text = "Steam: NOT available (open Steam and restart)"
	elif not in_lobby:
		_status_label.text = "Steam: available"
	else:
		_status_label.text = "Hosting." if is_host else "Joined -- waiting for host to start."

	if in_lobby:
		var owner_id: int = Steam.getLobbyOwner(SteamNetwork.current_lobby_id)
		_title_label.text = "%s's Lobby" % SteamNetwork.get_member_name(owner_id)
		_lobby_id_field.text = str(SteamNetwork.current_lobby_id)
	else:
		_title_label.text = "Lobby"

	for child: Node in _members_list.get_children():
		child.queue_free()
	for steam_id: int in SteamNetwork.get_lobby_members():
		var label := Label.new()
		label.text = SteamNetwork.get_member_name(steam_id)
		_members_list.add_child(label)


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.12, 0.16)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var layout := VBoxContainer.new()
	layout.set_anchors_preset(Control.PRESET_CENTER)
	layout.grow_horizontal = Control.GROW_DIRECTION_BOTH
	layout.grow_vertical = Control.GROW_DIRECTION_BOTH
	layout.add_theme_constant_override("separation", 12)
	add_child(layout)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 32)
	layout.add_child(_title_label)
	_status_label = Label.new()
	layout.add_child(_status_label)

	_lobby_id_row = HBoxContainer.new()
	layout.add_child(_lobby_id_row)
	_lobby_id_field = LineEdit.new()
	_lobby_id_field.editable = false
	_lobby_id_field.custom_minimum_size = Vector2(180.0, 0.0)
	_lobby_id_row.add_child(_lobby_id_field)
	var copy_button := Button.new()
	copy_button.text = "Copy"
	copy_button.pressed.connect(func() -> void: DisplayServer.clipboard_set(_lobby_id_field.text))
	_lobby_id_row.add_child(copy_button)

	_host_button = Button.new()
	_host_button.text = "Host Lobby"
	_host_button.pressed.connect(func() -> void: SteamNetwork.host_lobby())
	layout.add_child(_host_button)

	_join_row = HBoxContainer.new()
	layout.add_child(_join_row)
	_join_input = LineEdit.new()
	_join_input.placeholder_text = "Lobby ID"
	_join_input.custom_minimum_size = Vector2(180.0, 0.0)
	_join_row.add_child(_join_input)
	var join_button := Button.new()
	join_button.text = "Join"
	join_button.pressed.connect(_on_join_pressed)
	_join_row.add_child(join_button)

	_members_list = VBoxContainer.new()
	layout.add_child(_members_list)

	_start_button = Button.new()
	_start_button.text = "Start Match ->"
	_start_button.pressed.connect(_on_start_pressed)
	layout.add_child(_start_button)

	_leave_button = Button.new()
	_leave_button.text = "<- Leave Lobby"
	_leave_button.pressed.connect(_on_leave_pressed)
	layout.add_child(_leave_button)
