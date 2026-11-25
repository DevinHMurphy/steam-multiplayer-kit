# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_log.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
## Leveled, categorized, peer-tagged logging for networking code.
##
## Register as autoload [code]NetLog[/code], before [code]SteamNetwork[/code]. Every line is
## prefixed with this machine's peer id, because "which machine printed this" is the question
## most multiplayer bugs turn on -- logs pasted from two instances still read clearly.[br]
## Pair with project.godot [code][logging] file_logging/enable_file_logging=true[/code] so every
## run lands in [code]user://logs/godot.log[/code] for both instances.[br]
## [b]Hot paths:[/b] gate on [method would_log] before building a formatted message -- the
## [code]%[/code] format runs before the call, whether or not anything prints.
##
## @tutorial(Testing and debugging): res://docs/multiplayer/06_TESTING_DEBUGGING.md

## Severity, most to least severe. A line prints when its level is <= [member min_level].
enum Level { ERROR, WARN, INFO, DEBUG }

## Which subsystem a line belongs to. Extend freely; keep [constant _CATEGORY_NAMES] in step.
enum Category {
	LOBBY,     ## SteamNetwork, lobby screen
	SCENE,     ## SceneRouter transitions
	SPAWN,     ## Player and entity spawners
	MOVEMENT,  ## Player input relay, transform broadcast, reconciliation
	ENTITY,    ## NPC/AI state and transform broadcast
	ACTION,    ## Discrete player actions (request -> validate -> broadcast)
	ROUND,     ## Match/round flow, scoring
	LOADING,   ## Loading gate, cross-peer ready counting
}

const _LEVEL_NAMES: Array[String] = ["ERROR", "WARN", "INFO", "DEBUG"]
const _CATEGORY_NAMES: Array[String] = [
	"Lobby", "Scene", "Spawn", "Movement", "Entity", "Action", "Round", "Loading"
]

## Minimum level printed. INFO shows every spawn/connect/state change without per-frame chatter;
## flip to DEBUG (Remote inspector or here) while chasing a desync.
var min_level: Level = Level.INFO

## Empty = all categories. Non-empty = ONLY these print, e.g. [code][Category.ACTION][/code].
var enabled_categories: Array[Category] = []


func error(category: Category, message: String) -> void:
	_log(Level.ERROR, category, message)


func warn(category: Category, message: String) -> void:
	_log(Level.WARN, category, message)


func info(category: Category, message: String) -> void:
	_log(Level.INFO, category, message)


## Per-frame traffic: RPC sends/receives, transform broadcasts. Off by default.
func debug(category: Category, message: String) -> void:
	_log(Level.DEBUG, category, message)


## Whether a line at [param level]/[param category] would print. Check this before formatting a
## message in any per-frame or per-entity path.
func would_log(level: Level, category: Category) -> bool:
	if level > min_level:
		return false
	return enabled_categories.is_empty() or enabled_categories.has(category)


func _log(level: Level, category: Category, message: String) -> void:
	if not would_log(level, category):
		return
	# get_unique_id() is safe with no peer attached: it returns 1, same as solo play.
	var line: String = "[%s][%s][peer %d] %s" % [
		_LEVEL_NAMES[level], _CATEGORY_NAMES[category], multiplayer.get_unique_id(), message
	]
	if level == Level.ERROR:
		push_error(line)
	elif level == Level.WARN:
		push_warning(line)
	else:
		print(line)
