# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     steam_manager.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
## Steam API lifecycle: initializes GodotSteam once and exposes whether it succeeded.
##
## Register as autoload [code]SteamManager[/code], FIRST in the autoload list. Does NOT
## self-initialize in [method Node._ready] -- the boot scene calls [method initialize] once,
## before the first screen loads, so every screen reads an already-settled
## [member is_available] instead of racing init.[br]
## Every other Steam call in the project must check [member is_available] first.[br]
## A failed init (Steam client not running) is a logged warning, never a crash -- solo play
## must keep working without Steam.
##
## @tutorial(Kit architecture): res://docs/multiplayer/01_ARCHITECTURE.md

## Valve's public "Spacewar" placeholder App ID. Swap for the real Steamworks App ID before a
## release build -- nothing else needs to change. Also requires a gitignored
## [code]steam_appid.txt[/code] containing the same id at the project root for editor runs and
## non-Steam-launched exports.
const DEV_APP_ID: int = 480

## True only once [method initialize] succeeded. Read this before ANY [code]Steam.*[/code] call.
var is_available: bool = false
## Raw status from [code]Steam.steamInitEx()[/code]; -1 until [method initialize] runs.
var init_status: int = -1
## Human-readable init result from GodotSteam ("verbal" field).
var init_message: String = ""


## Initializes Steam. [code]embed_callbacks = true[/code] makes GodotSteam pump Steam callbacks
## internally, so no [code]Steam.run_callbacks()[/code] poll is needed anywhere.[br]
## Logs both outcomes so init can be confirmed from the console alone.
## [param app_id]: Steamworks App ID to initialize against.[br]
## Returns [code]true[/code] on success.
func initialize(app_id: int = DEV_APP_ID) -> bool:
	print("SteamManager: initializing Steam (app id %d)..." % app_id)

	var result: Dictionary = Steam.steamInitEx(app_id, true)
	init_status = result.get("status", -1)
	init_message = result.get("verbal", "")

	is_available = init_status == Steam.STEAM_API_INIT_RESULT_OK
	if is_available:
		print("SteamManager: Steam initialized (app id %d)." % app_id)
	else:
		push_warning(
			"SteamManager: Steam did not initialize (status %d): %s" % [init_status, init_message]
		)
	return is_available
