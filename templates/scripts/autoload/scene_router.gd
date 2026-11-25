# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     scene_router.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
## Screen switching, local and host-driven-for-everyone, plus match state that must survive
## scene changes.
##
## Register as autoload [code]SceneRouter[/code], after [code]SteamNetwork[/code]. Callers ask
## for a [enum Screen], never a raw path.[br]
## [b]Why an autoload hosts the RPCs:[/b] autoloads exist at the same NodePath on every peer from
## boot, so an RPC routed through one can't race scene-load timing the way a node inside a
## freshly-loaded scene can.[br]
## [b]Persisting data:[/b] [code]change_scene_to_file()[/code] frees the whole old scene. Anything
## a later screen needs (round results, submissions) lives here or in another autoload.
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## This machine just entered [param screen].
signal screen_changed(screen: Screen)
## The shared round counter changed (on every peer). [param round_number]: 1-based.
signal round_changed(round_number: int)

## Every screen in the game. APPEND ONLY: an exported [enum Screen] serializes as a plain int in
## .tscn files, so inserting mid-enum silently renumbers every saved value after it.
enum Screen {
	START,
	LOBBY,
	LOADING,
	GAMEPLAY,
	RESULTS,
}

## [enum Screen] -> scene path. Replace with your project's scenes.
const SCREEN_PATHS: Dictionary[Screen, String] = {
	Screen.START: "res://scenes/screens/start_screen.tscn",
	Screen.LOBBY: "res://scenes/screens/lobby_screen.tscn",
	Screen.LOADING: "res://scenes/screens/loading_gate.tscn",
	Screen.GAMEPLAY: "res://scenes/gameplay/gameplay.tscn",
	Screen.RESULTS: "res://scenes/screens/results_screen.tscn",
}

## Rounds per match. Placeholder -- set to your design's value.
const TOTAL_ROUNDS: int = 3

## Screen this machine is currently showing.
var current_screen: Screen = Screen.START
## 1-based round counter, kept identical on every peer by [method _networked_set_round].
var current_round: int = 1


## Switches THIS machine only. Use [method goto_screen_for_everyone] for match flow.
func goto_screen(screen: Screen) -> void:
	var path: String = SCREEN_PATHS.get(screen, "")
	if path == "":
		push_warning("SceneRouter: no scene path registered for screen %s." % Screen.keys()[screen])
		return
	var err: Error = get_tree().change_scene_to_file(path)
	if err != OK:
		push_warning("SceneRouter: change_scene_to_file(%s) failed with error %d." % [path, err])
		return
	_on_screen_entered(screen)


## Host-only in effect: moves every connected peer (this one included) to [param screen].
## Falls back to a plain local switch with no active session, so solo play uses the same call.
func goto_screen_for_everyone(screen: Screen) -> void:
	if not SteamNetwork.has_active_session():
		goto_screen(screen)
		return
	_networked_goto_screen.rpc(screen)


## Promotes an already-instantiated node (a direct child of the tree root) to current_scene and
## frees the old one. Used by a loading gate that pre-builds the next scene off-screen.
func swap_in_preloaded_scene(screen: Screen, node: Node) -> void:
	var old_scene: Node = get_tree().current_scene
	get_tree().current_scene = node
	if old_scene != null and old_scene != node:
		old_scene.queue_free()
	_on_screen_entered(screen)


## Host-only in effect. Advances the round, or ends the match and returns to the lobby.
func finish_round() -> void:
	var match_complete: bool = current_round >= TOTAL_ROUNDS
	var next_round: int = 1 if match_complete else current_round + 1
	_set_round_everywhere(next_round)
	goto_screen_for_everyone(Screen.LOBBY if match_complete else Screen.LOADING)


## Host-only in effect. Call at "a new match begins now" (the lobby's Start button).
func reset_match() -> void:
	_set_round_everywhere(1)


func _set_round_everywhere(round_number: int) -> void:
	if SteamNetwork.has_active_session():
		_networked_set_round.rpc(round_number)
	else:
		_networked_set_round(round_number)


func _on_screen_entered(screen: Screen) -> void:
	current_screen = screen
	NetLog.info(NetLog.Category.SCENE, "Entered screen %s" % Screen.keys()[screen])
	screen_changed.emit(screen)


## call_local so the host takes the same dispatch path as clients instead of jumping a full
## round-trip ahead of them.
@rpc("authority", "reliable", "call_local")
func _networked_goto_screen(screen: Screen) -> void:
	goto_screen(screen)


@rpc("authority", "reliable", "call_local")
func _networked_set_round(round_number: int) -> void:
	current_round = round_number
	round_changed.emit(current_round)
