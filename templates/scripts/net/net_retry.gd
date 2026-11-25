# ==============================================================================
# [Project Name]
# Copyright (c) October 8, 2026 [Author/Company]
# All rights reserved.
#
# File:     net_retry.gd
# Author:   [Author]
# Created:  October 8, 2026
# Modified: October 8, 2026
# ==============================================================================

extends Node
class_name NetRetry
## Resends a client -> host request on a timer until it is acknowledged or gives up.
##
## [b]Why this exists:[/b] an RPC sent to a NodePath the receiver hasn't instantiated yet is
## silently dropped -- no error on the sender, no queue, no retry. Any client -> host request sent
## from a scene node's [method Node._ready] can arrive before the host has loaded that scene.[br]
## Pair with an idempotent host handler: a late duplicate must be harmless.[br]
## [codeblock]
## var retry := NetRetry.new()
## add_child(retry)
## retry.start(func() -> void: _request_state.rpc_id(1), func() -> bool: return _synced)
## [/codeblock]
##
## @tutorial(Patterns): res://docs/multiplayer/04_PATTERNS.md

## Acknowledged: [code]is_done[/code] returned true. The node frees itself after emitting.
signal succeeded(attempts: int)
## Ran out of attempts. Something other than load-order timing is broken. Frees itself after.
signal gave_up(attempts: int)

## Seconds between resends.[br]
## [b]Units:[/b] seconds. Source-project value: 0.5-1.0.
@export var interval: float = 1.0
## Attempts (including the first) before giving up with a warning.[br]
## Source-project value: 15.
@export var max_attempts: int = 15
## NetLog category for this retry's log lines.
@export var log_category: NetLog.Category = NetLog.Category.SPAWN
## Label used in log lines, e.g. "player spawn request".
@export var label: String = "request"

var _send: Callable
var _is_done: Callable
var _attempts: int = 0
var _timer: Timer = null


## Sends once immediately, then every [member interval] seconds until [param is_done] returns
## true or [member max_attempts] is reached.
## [param send]: no-arg Callable that performs the RPC.
## [param is_done]: no-arg Callable returning bool; true stops the retries.
func start(send: Callable, is_done: Callable) -> void:
	_send = send
	_is_done = is_done
	_attempts = 1
	_send.call()

	_timer = Timer.new()
	_timer.wait_time = interval
	_timer.timeout.connect(_on_timeout)
	add_child(_timer)
	_timer.start()


## Stops early without emitting. Safe to call more than once.
func stop() -> void:
	if _timer != null:
		_timer.stop()
	queue_free()


func _on_timeout() -> void:
	if _is_done.call():
		NetLog.info(log_category, "%s acknowledged after %d attempt(s)" % [label, _attempts])
		succeeded.emit(_attempts)
		stop()
		return
	if _attempts >= max_attempts:
		NetLog.warn(
			log_category,
			"%s gave up after %d attempts -- not a load-order race; check host-side config."
			% [label, _attempts]
		)
		gave_up.emit(_attempts)
		stop()
		return
	_attempts += 1
	NetLog.info(log_category, "Retrying %s (attempt %d)" % [label, _attempts])
	_send.call()
