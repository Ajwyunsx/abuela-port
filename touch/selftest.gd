extends Node

# Injected only into test builds. Drives the touch overlay with synthetic input
# and verifies the actual game reactions: movement, look, every action button,
# crouch/stand, jump, inventory taps and the menu tap path.

var overlay: Node
var player
var sm
var pivot
var seen := []          # events observed by the game-level _unhandled_input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventAction and event.pressed:
		seen.append(event.action)
	elif event is InputEventKey and event.pressed:
		seen.append("key" + str(event.keycode))

func _ready() -> void:
	await get_tree().process_frame
	overlay = get_tree().root.get_node_or_null("/root/TouchControls")
	print("[TEST] overlay=", overlay)
	if overlay == null:
		get_tree().quit()
		return
	# menu widgets (music slider / difficulty list) must be tested while the
	# menu scene is still alive: it is freed once the game starts
	await get_tree().create_timer(0.5).timeout
	await _test_menu_widgets()

	var pb := _find_button(get_tree().current_scene, "PlayGame")
	if pb:
		pb.pressed.emit()
	var g := get_tree().root.get_node_or_null("/root/Global")
	for i in 60:
		await get_tree().create_timer(0.5).timeout
		player = g.get("player")
		if player:
			break
	if player == null:
		print("[TEST] FAIL: no player")
		get_tree().quit()
		return
	sm = player.get_node_or_null("StateMachine")
	pivot = player.get_node_or_null("CameraPivot")
	await get_tree().create_timer(2.0).timeout
	print("[TEST] player=", player.name, " on_floor=", player.is_on_floor())

	# ---------- joystick ----------
	var p0: Vector3 = player.global_position
	overlay.call("_handle_point", Vector2(140, 540), 0, 0)
	_drag(0, Vector2(140, 440), Vector2(0, -100))
	await get_tree().create_timer(1.5).timeout
	var p1: Vector3 = player.global_position
	print("[TEST] joystick moved=", p1.distance_to(p0) > 0.5)

	# ---------- two fingers: look while moving ----------
	var yaw0: float = player.rotation.y
	overlay.call("_handle_point", Vector2(900, 300), 0, 1)
	_drag(1, Vector2(1050, 300), Vector2(150, 0))
	await get_tree().process_frame
	print("[TEST] two fingers: yaw changed=", absf(player.rotation.y - yaw0) > 0.01,
			" joystick alive=", Input.is_action_pressed("move_up"))
	overlay.call("_release_point", 1, Vector2(1050, 300))
	await get_tree().create_timer(1.0).timeout
	print("[TEST] after lifting look: joystick alive=", Input.is_action_pressed("move_up"),
			" still moving=", player.global_position.distance_to(p1) > 0.5)
	overlay.call("_release_point", 0, Vector2(140, 440))
	await get_tree().create_timer(0.8).timeout
	print("[TEST] after lifting joystick: stopped=", not Input.is_action_pressed("move_up"))

	# ---------- pitch ----------
	var pitch0: float = pivot.rotation.x
	overlay.call("_handle_point", Vector2(900, 300), 0, 2)
	_drag(2, Vector2(900, 200), Vector2(0, -100))
	await get_tree().process_frame
	print("[TEST] pitch changed=", absf(pivot.rotation.x - pitch0) > 0.01)
	overlay.call("_release_point", 2, Vector2(900, 200))

	# ---------- every button: does it really reach the game? ----------
	var btns: Array = overlay.get("_buttons")
	for b in btns:
		var center: Vector2 = b.rect.get_center()
		seen.clear()
		overlay.call("_handle_point", center, 0, 30)
		await get_tree().process_frame
		await get_tree().process_frame
		var ev_seen := seen.duplicate()
		var held := Input.is_action_pressed(b.action)
		overlay.call("_release_point", 30, center)
		await get_tree().process_frame
		print("[TEST] button %-10s event_seen=%s held_while_down=%s"
				% [b.action, str(ev_seen), str(held)])

	# ---------- crouch: toggle down and back up ----------
	# the button loop above may have left crouch engaged; normalise first
	if overlay.get("_crouching"):
		await _press_button("crouch")
		await get_tree().create_timer(1.0).timeout
	var cam2: Node3D = pivot.get_node_or_null("Camera3D")
	var stand_y: float = cam2.position.y
	await _press_button("crouch")
	await get_tree().create_timer(0.9).timeout
	var crouch_y: float = cam2.position.y
	print("[TEST] crouch: cam.y %.2f -> %.2f  lowered=%s (crouching=%s)"
			% [stand_y, crouch_y, str(crouch_y < stand_y - 0.2), str(overlay.get("_crouching"))])
	await _press_button("crouch")
	await get_tree().create_timer(0.9).timeout
	print("[TEST] stood up: cam.y %.2f -> %.2f  restored=%s" % [crouch_y, cam2.position.y, str(absf(cam2.position.y - stand_y) < 0.05)])

	# ---------- jump ----------
	# the test player is idle but Granny may already be chasing; jumping only
	# works from Idle/Walk, so wait for a usable moment
	var ok_to_jump := false
	for _i in 120:
		await get_tree().create_timer(0.1).timeout
		var st := _state()
		if st == "Idle" or st == "Walk" or st == "CrouchWalk":
			ok_to_jump = true
			break
	if not ok_to_jump:
		print("[TEST] jump skipped: player is in state ", _state())
	print("[TEST] jump precondition: on_floor=%s state=%s pos=%s"
			% [str(player.is_on_floor()), _state(), str(player.global_position)])
	if ok_to_jump:
		var y_before: float = player.global_position.y
		await _press_button("jump")
		await get_tree().create_timer(0.35).timeout
		var st_jump: String = _state()
		var peak: float = player.global_position.y
		await get_tree().create_timer(1.5).timeout
		print("[TEST] jump: state_after_press=%s  left_ground=%s  landed_state=%s  on_floor=%s"
				% [st_jump, str(st_jump == "Jump"), _state(), str(player.is_on_floor())])

	# ---------- inventory ----------
	var slots: Array = overlay.get("_slots")
	print("[TEST] inventory slots=", slots.size())
	if slots.size() > 0:
		var c: Control = slots[0]
		var center: Vector2 = c.get_global_rect().get_center()
		seen.clear()
		overlay.call("_handle_point", center, 0, 40)
		await get_tree().process_frame
		print("[TEST] slot tap event_seen=", str(seen))
		overlay.call("_release_point", 40, center)

	# ---------- layout ----------
	var vsz: Vector2 = get_viewport().get_visible_rect().size
	print("[TEST] viewport=", vsz)
	for b in btns:
		print("[TEST]   btn ", b.action, " rect=", b.rect)

	if DisplayServer.get_name() != "headless":
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("/tmp/abuela_shot.png")
		print("[TEST] screenshot saved, mode=", DisplayServer.window_get_mode(),
				" fullscreen=", DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN,
				" size=", DisplayServer.window_get_size())
	print("[TEST] done")
	get_tree().quit()

func _test_menu_widgets() -> void:
	# go back to the menu: the settings screen holds both widgets
	var settings = _find_node(get_tree().current_scene, "Settings")
	var menu = _find_node(get_tree().current_scene, "Menu")
	if settings == null:
		print("[TEST] widgets: no Settings node")
		return
	settings.visible = true
	if menu:
		menu.visible = false
	await get_tree().process_frame
	await get_tree().process_frame

	var music = _find_node(settings, "Music")
	if music is HSlider:
		var before: float = music.value
		var rect: Rect2 = music.get_global_rect()
		var click := Vector2(rect.position.x + rect.size.x * 0.85, rect.position.y + rect.size.y * 0.5)
		overlay.call("_handle_point", click, 0, 60)
		await get_tree().process_frame
		overlay.call("_release_point", 60, click)
		print("[TEST] music slider: %.3f -> %.3f  changed=%s"
				% [before, music.value, str(absf(music.value - before) > 0.05)])
		# drag along the track
		var before2: float = music.value
		var start := Vector2(rect.position.x + rect.size.x * 0.85, rect.position.y + rect.size.y * 0.5)
		overlay.call("_handle_point", start, 0, 61)
		var target := Vector2(rect.position.x + rect.size.x * 0.15, rect.position.y + rect.size.y * 0.5)
		_drag(61, target, target - start)
		overlay.call("_release_point", 61, target)
		print("[TEST] music slider drag: %.3f -> %.3f  changed=%s"
				% [before2, music.value, str(absf(music.value - before2) > 0.05)])
	else:
		print("[TEST] widgets: Music is ", music)

	# the difficulty list is collapsed behind a Deploy button; open it first.
	# (a Button needs a real pointer or a touch on a device, so the test fires
	# its signal directly - what matters here is that the list becomes usable)
	var deploy = _find_node(settings, "Deploy")
	if deploy is Button and deploy.is_visible_in_tree():
		(deploy as Button).pressed.emit()
		await get_tree().create_timer(0.4).timeout
		print("[TEST] difficulty list opened: rect=%s"
				% str(_find_node(settings, "ItemList").get_global_rect()))

	var list = _find_node(settings, "ItemList")
	if list is ItemList:
		var il := list as ItemList
		var sel_before := il.get_selected_items()
		var rect2: Rect2 = il.get_global_rect()
		print("[TEST] difficulty list: %d items, selected=%s, rect=%s"
				% [il.item_count, str(sel_before), str(rect2)])
		var item_h := rect2.size.y / maxf(il.item_count, 1)
		var click2 := Vector2(rect2.position.x + rect2.size.x * 0.5,
				rect2.position.y + item_h * 2.5)
		overlay.call("_handle_point", click2, 0, 62)
		await get_tree().process_frame
		overlay.call("_release_point", 62, click2)
		await get_tree().process_frame
		print("[TEST] difficulty after tap: selected=%s" % str(il.get_selected_items()))
	else:
		print("[TEST] widgets: ItemList is ", list)

	settings.visible = false
	if menu:
		menu.visible = true
	await get_tree().process_frame


func _find_node(n: Node, target: String) -> Node:
	if n == null:
		return null
	if n.name == target:
		return n
	for c in n.get_children():
		var r = _find_node(c, target)
		if r != null:
			return r
	return null


func _drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var d := InputEventScreenDrag.new()
	d.index = index
	d.position = pos
	d.relative = rel
	overlay.call("_handle_drag", d)

func _press_button(action: String) -> void:
	for b in overlay.get("_buttons"):
		if b.action == action:
			var center: Vector2 = b.rect.get_center()
			overlay.call("_handle_point", center, 0, 50)
			await get_tree().process_frame
			overlay.call("_release_point", 50, center)
			await get_tree().process_frame
			return

func _state() -> String:
	if sm == null:
		return "?"
	var s = sm.get("current_state")
	if s == null:
		return "null"
	return str(s.name) if s is Node else str(s)

func _find_button(n: Node, t: String) -> Node:
	if n == null:
		return null
	if n.name == t:
		return n
	for c in n.get_children():
		var r = _find_button(c, t)
		if r:
			return r
	return null
