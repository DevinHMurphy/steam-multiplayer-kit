# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     boot.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
## Entry point (project.godot run/main_scene). Initializes Steam BEFORE the first screen.
##
## Every screen can then read [code]SteamManager.is_available[/code] as a settled fact. If the
## game was launched from a Steam invite ([code]+connect_lobby <id>[/code]), joins that lobby and
## opens the lobby screen; otherwise opens the start screen.


func _ready() -> void:
	SteamManager.initialize()
	if SteamManager.is_available and SteamNetwork.join_lobby_from_command_line():
		SceneRouter.goto_screen.call_deferred(SceneRouter.Screen.LOBBY)
		return
	SceneRouter.goto_screen.call_deferred(SceneRouter.Screen.START)
