extends CanvasLayer

# Touch control overlay injected into ABUELA 3.0.9 (Godot 4.7.2).
#
# The original game is keyboard/mouse only:
#   move_*  -> WASD / arrows                    (polled in the state machine)
#   camera_left/right -> player body yaw, camera_up/down -> CameraPivot pitch
#   use -> left mouse button (fire), interact -> E / right mouse button
#   run -> Shift, crouch -> Ctrl/C, jump -> Space, slot_1..4 -> 1..4, drop_item -> Q
#
# Two different dispatch paths are needed, and mixing them up is what used to
# make buttons "not work":
#
#   * movement (move_*, run) and hold-style states (crouch, jump) are *polled*
#     by the game through Input.is_action_pressed(), so Input.action_press()
#     is the right call and gives analog strength for the joystick.
#   * one-shot commands (use / interact / slot_N / drop_item / wheel_*) are
#     handled in the player's _unhandled_input() via event.is_action().
#     Input.action_press() only flips internal state and emits NO event at all,
#     so those buttons were silently ignored. They get a real InputEventAction.

const JOY_ZONE_X := 0.42          # left of this fraction of the screen = joystick
const LOOK_ZONE_X := 0.58         # right of this fraction = look area
const JOY_RADIUS := 125.0         # px, joystick deflection radius
const DEAD_ZONE := 0.10
const JOY_SMOOTH := 22.0          # higher = snappier joystick response
const KNOB_SMOOTH := 26.0
const AUTO_RUN := true            # run automatically at full joystick deflection
const RUN_THRESHOLD := 0.85
const PITCH_LIMIT := 1.35         # rad, same range the game itself uses
const LOOK_SCALE := 1.0           # multiplier on the game mouse sensitivity
const BTN_R := 46.0
const EDGE_MARGIN := 34.0         # distance of the button cluster from the screen edge
const ROW_GAP := 12.0
const MOUSE_INDEX := -1000        # pseudo touch index for the desktop mouse fallback
const TAP_MOVE_TOLERANCE := 46.0  # px a finger may drift and still count as a tap
# one-shot actions keep their event "pressed" for at least this long, otherwise a
# fast tap can press+release inside one physics frame and the game misses it
const MIN_HOLD := 0.07

# buttons handled through real action events (one-shot commands)
const EVENT_ACTIONS := ["use", "interact", "drop_item", "wheel_up", "wheel_down",
		"slot_1", "slot_2", "slot_3", "slot_4"]
# buttons that are polled by the game (held while the finger is down)
const HOLD_ACTIONS := ["run"]
# the game's own crouch state machine never triggers (same on PC), so crouch is
# driven directly here: crouch_camera_y / crouch_capsule_height are applied to
# the camera pivot and the collision shape below.
const CROUCH_CAMERA_DROP := 0.55  # metres the camera dips when crouching
const CROUCH_CAPSULE_HEIGHT := 1.0
const CROUCH_STEP := 7.0          # lerp speed of the crouch transition

class Btn:
	var action := ""
	var label := ""
	var rect := Rect2()
	var held := false
	var index := -1
	var down_pos := Vector2.ZERO
	var fired := false            # event already sent for this press
	var press_time := 0.0
	var release_at := -1.0

var _canvas: Control
var _player: Node = null
var _pivot: Node3D = null
var _joy_touch := -1
var _look_touch := -1
var _joy_origin := Vector2.ZERO
var _joy_pos := Vector2.ZERO
var _joy_target := Vector2.ZERO
var _joy_smooth := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _owners := {}                 # touch index -> {kind, action, btn}
var _ui_mode := true              # true while the menu is up (no player yet)
var _touch_emulation := false     # desktop test: mouse is turned into a finger
var _pending_clicks: Array[Vector2] = []
var _buttons: Array[Btn] = []
var _slots: Array = []            # the game's own inventory slot controls
var _scale := 1.0
var _ui_targets := {}            # touch index -> {kind, control}
var _fs_check: CheckBox = null
var _crouching := false
var _crouch_blend := 0.0          # 0 = standing, 1 = fully crouched
var _cam: Camera3D = null
var _stand_cam_y := 0.0
var _stand_camera_y := -1.0
var _stand_capsule := -1.0
var _capsule_shape: CollisionShape3D = null
var _capsule_radius := 0.5

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.name = "TouchUI"
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_ui)
	add_child(_canvas)
	_make_buttons()
	_touch_emulation = bool(ProjectSettings.get_setting("input_devices/pointing/emulate_touch_from_mouse", false))
	_enforce_fullscreen()
	set_process(true)
	print("[TOUCH] overlay ready (touch_emulation=", _touch_emulation, ")")

func _enforce_fullscreen() -> void:
	# the port always runs fullscreen; the in-game checkbox is neutralised below
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)


func _make_buttons() -> void:
	_buttons.clear()
	for spec in [["use", "FIRE"], ["interact", "USE"], ["run", "RUN"],
			["crouch", "CROUCH"], ["jump", "JUMP"], ["drop_item", "DROP"]]:
		var b := Btn.new()
		b.action = spec[0]
		b.label = spec[1]
		_buttons.append(b)

# ---------------------------------------------------------------- layout

func _layout_buttons() -> void:
	var vs := get_viewport().get_visible_rect().size
	if vs.x <= 0.0:
		return
	_scale = clampf(minf(vs.x / 1152.0, vs.y / 648.0), 0.85, 2.2)
	var r := BTN_R * _scale
	var m := EDGE_MARGIN * _scale
	var gap := ROW_GAP * _scale
	# right hand cluster: primary action in the bottom right corner,
	# the rest stacked above / to the left of it (thumb friendly)
	var col_a := vs.x - m - r          # column closest to the right edge
	var col_b := col_a - 2.0 * r - gap
	var rows := [vs.y - m - r, vs.y - m - 3.0 * r - gap, vs.y - m - 5.0 * r - 2.0 * gap]
	var col_a_actions := ["use", "run", "jump"]
	var col_b_actions := ["interact", "crouch", "drop_item"]
	for i in 3:
		_set_rect(col_a_actions[i], Rect2(Vector2(col_a - r, rows[i] - r), Vector2(r * 2.0, r * 2.0)))
		_set_rect(col_b_actions[i], Rect2(Vector2(col_b - r, rows[i] - r), Vector2(r * 2.0, r * 2.0)))

func _set_rect(action: String, rect: Rect2) -> void:
	for b in _buttons:
		if b.action == action:
			b.rect = rect
			return

# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_handle_point(t.position, t.device, t.index)
		else:
			_release_point(t.index, t.position)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton and not _touch_emulation:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_handle_point(mb.position, 0, MOUSE_INDEX)
			else:
				_release_point(MOUSE_INDEX, mb.position)
	elif event is InputEventMouseMotion and not _touch_emulation and _look_touch == MOUSE_INDEX:
		var mm := event as InputEventMouseMotion
		_handle_move(mm.relative)


func _handle_point(pos: Vector2, device: int = 0, index: int = -1) -> void:
	if _owners.has(index):
		return
	# Sliders and ItemLists only understand mouse input in Godot, so they are
	# driven from touch directly. This applies in the menus as well.
	if _handle_ui_widget(pos, index):
		return
	if _ui_mode:
		# Menu / UI screen. On a real device Godot's buttons already react to
		# native touch events, so nothing has to be done. Only emulated touches
		# (desktop testing, device id -1) need to be forwarded as mouse clicks.
		if device == InputEvent.DEVICE_ID_EMULATION:
			_pending_clicks.append(pos)
		return
	# let the game's own HUD buttons receive the tap first
	if _over_game_button(pos):
		return
	var best: Btn = null
	var best_d := 1e20
	for b in _buttons:
		if b.rect.has_point(pos):
			var d := b.rect.get_center().distance_to(pos)
			if d < best_d:
				best_d = d
				best = b
	if best != null:
		_press_button(best, pos, index)
		return
	# the game's own inventory bar: tapping a slot selects that item
	var slot := _slot_at(pos)
	if slot >= 0:
		_owners[index] = {"kind": "slot", "action": "slot_" + str(slot + 1)}
		_send_event("slot_" + str(slot + 1), true)
		_consume()
		return
	var vs := get_viewport().get_visible_rect().size
	if pos.x < vs.x * JOY_ZONE_X:
		if _joy_touch < 0:
			_joy_touch = index
			_owners[index] = {"kind": "joy"}
			_joy_origin = pos
			_joy_pos = pos
			_joy_knob = pos
			_joy_target = Vector2.ZERO
			_joy_smooth = Vector2.ZERO
			_consume()
		return
	if pos.x > vs.x * LOOK_ZONE_X:
		if _look_touch < 0:
			_look_touch = index
			_owners[index] = {"kind": "look"}
			_consume()
		return


# --- touch support for Range (sliders) and ItemList -----------------------

func _widget_at(pos: Vector2) -> Control:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _find_widget(scene, pos)


func _find_widget(n: Node, pos: Vector2) -> Control:
	if n is Control:
		var c := n as Control
		if (c is Range or c is ItemList) and c.is_visible_in_tree() \
				and c.get_global_rect().has_point(pos):
			return c
	for child in n.get_children():
		var r := _find_widget(child, pos)
		if r != null:
			return r
	return null


func _handle_ui_widget(pos: Vector2, index: int) -> bool:
	var w := _widget_at(pos)
	if w == null:
		return false
	if w is ItemList:
		_select_item_at(w as ItemList, pos)
		_owners[index] = {"kind": "widget", "control": w}
	else:
		_set_range_from_pos(w as Range, pos)
		_owners[index] = {"kind": "widget", "control": w}
	_consume()
	return true


func _select_item_at(list: ItemList, pos: Vector2) -> void:
	# ItemList positions are relative to the control
	var local := pos - list.get_global_rect().position
	var idx := list.get_item_at_position(local, true)
	if idx < 0:
		return
	list.select(idx)
	list.emit_signal("item_selected", idx)
	print("[TOUCH] item list -> ", idx)


func _set_range_from_pos(r: Range, pos: Vector2) -> void:
	var rect := r.get_global_rect()
	if rect.size.x <= 0.0:
		return
	var t := clampf((pos.x - rect.position.x) / rect.size.x, 0.0, 1.0)
	r.value = lerpf(r.min_value, r.max_value, t)
	if r is Slider:
		(r as Slider).emit_signal("value_changed", r.value)


func _press_button(b: Btn, pos: Vector2, index: int) -> void:
	b.held = true
	b.index = index
	b.down_pos = pos
	b.fired = false
	_owners[index] = {"kind": "button", "action": b.action, "btn": b}
	if b.action == "crouch":
		_toggle_crouch()
		b.fired = true
	elif b.action in EVENT_ACTIONS or b.action == "jump":
		# one-shot command: a real action event, sent now
		_send_event(b.action, true)
		b.fired = true
		b.press_time = _now()
	else:
		# polled action (run): hold it while the finger is down
		Input.action_press(b.action)
	_consume()


func _handle_drag(event: InputEventScreenDrag) -> void:
	var owner = _owners.get(event.index, null)
	if owner != null and owner["kind"] == "widget":
		var w = owner["control"]
		if w != null and is_instance_valid(w):
			if w is ItemList:
				_select_item_at(w as ItemList, event.position)
			elif w is Range:
				_set_range_from_pos(w as Range, event.position)
			_consume()
		return
	if _ui_mode:
		return
	if owner == null:
		return
	if owner["kind"] == "joy":
		_joy_pos = event.position
		_update_joystick_target()
		_consume()
	elif owner["kind"] == "look":
		_handle_move(event.relative)
	elif owner["kind"] == "widget":
		var w = owner["control"]
		if w != null and is_instance_valid(w):
			if w is ItemList:
				_select_item_at(w as ItemList, event.position)
			elif w is Range:
				_set_range_from_pos(w as Range, event.position)
			_consume()


func _release_point(index: int, pos: Vector2 = Vector2(-1, -1)) -> void:
	var owner = _owners.get(index, null)
	if owner == null:
		return
	_owners.erase(index)
	var kind: String = owner["kind"]
	match kind:
		"slot":
			_send_event(owner["action"], false)
		"button":
			var b: Btn = owner["btn"]
			b.held = false
			b.index = -1
			if b.action == "crouch":
				pass
			elif b.action in EVENT_ACTIONS or b.action == "jump":
				# respect the minimum hold so the game sees the press
				var elapsed := _now() - b.press_time
				if elapsed >= MIN_HOLD:
					_send_event(b.action, false)
				else:
					b.release_at = _now() + (MIN_HOLD - elapsed)
			else:
				Input.action_release(b.action)
		"joy":
			_joy_touch = -1
			_joy_target = Vector2.ZERO
			for a in ["move_up", "move_down", "move_left", "move_right"]:
				Input.action_release(a)
			if not _button_holds("run"):
				Input.action_release("run")
		"look":
			_look_touch = -1
		"widget":
			pass


func _now() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


func _flush_button_releases() -> void:
	var t := _now()
	for b in _buttons:
		if b.release_at > 0.0 and t >= b.release_at:
			b.release_at = -1.0
			if b.fired:
				b.fired = false
				_send_event(b.action, false)


func _toggle_crouch() -> void:
	_crouching = not _crouching
	print("[TOUCH] crouch ", "on" if _crouching else "off")


func _capture_stand_pose() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _pivot == null or not is_instance_valid(_pivot):
		return
	# only sample while fully standing, otherwise the reference height is wrong
	if _crouch_blend > 0.02:
		return
	_stand_camera_y = _pivot.position.y
	var cs := _player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	_capsule_shape = cs
	if cs != null and cs.shape is CapsuleShape3D:
		_stand_capsule = cs.shape.height
		_capsule_radius = (cs.shape as CapsuleShape3D).radius


func _apply_crouch(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _pivot == null or not is_instance_valid(_pivot):
		return
	_capture_stand_pose()
	if _stand_camera_y < 0.0:
		return
	var target := 1.0 if _crouching else 0.0
	if absf(target - _crouch_blend) < 0.001:
		return
	_crouch_blend = move_toward(_crouch_blend, target, CROUCH_STEP * delta)
	# the game rewrites CameraPivot.position every frame, but the camera's own
	# local offset is ours to drive, so lower that instead
	if _cam != null and is_instance_valid(_cam):
		_cam.position.y = _stand_cam_y - CROUCH_CAMERA_DROP * _crouch_blend
	if _capsule_shape != null and _stand_capsule > 0.0 and _capsule_shape.shape is CapsuleShape3D:
		var cap := _capsule_shape.shape as CapsuleShape3D
		cap.height = lerpf(_stand_capsule, maxf(CROUCH_CAPSULE_HEIGHT, _capsule_radius * 2.0), _crouch_blend)


func _send_event(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)


func _handle_move(rel: Vector2) -> void:
	if _ui_mode or rel == Vector2.ZERO:
		return
	var sens := 0.002
	var g := get_tree().root.get_node_or_null("/root/Global")
	if g:
		var s = g.get("mouse_sensitivity")
		if s != null:
			sens = float(s)
	# compensate for wider viewports so the same physical swipe turns the
	# camera by the same amount on every screen
	var vs := get_viewport().get_visible_rect().size
	var res_scale := vs.x / 1152.0
	var yaw := -rel.x * sens * LOOK_SCALE * res_scale
	var pitch := -rel.y * sens * LOOK_SCALE * res_scale
	if _player and is_instance_valid(_player):
		_player.rotation.y += yaw
	if _pivot and is_instance_valid(_pivot):
		_pivot.rotation.x = clampf(_pivot.rotation.x + pitch, -PITCH_LIMIT, PITCH_LIMIT)


func _update_joystick_target() -> void:
	var radius := JOY_RADIUS * _scale
	var d := _joy_pos - _joy_origin
	if d.length() > radius:
		d = d.normalized() * radius
	_joy_target = d / radius
	if _joy_target.length() < DEAD_ZONE:
		_joy_target = Vector2.ZERO

# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	while not _pending_clicks.is_empty():
		_inject_click(_pending_clicks.pop_front())
	_track_player()
	_layout_buttons()
	_keep_fullscreen()
	_apply_joystick(delta)
	_apply_crouch(delta)
	_flush_button_releases()
	_canvas.queue_redraw()


func _keep_fullscreen() -> void:
	# windowed modes are not supported in this port
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN \
			and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_neutralise_fullscreen_toggle()


func _neutralise_fullscreen_toggle() -> void:
	# the Settings screen has a Fullscreen checkbox; keep it ticked and disabled
	# so it cannot drag the game back into a window
	if _fs_check != null and is_instance_valid(_fs_check):
		if not _fs_check.disabled or not _fs_check.button_pressed:
			_fs_check.button_pressed = true
			_fs_check.disabled = true
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var cb := _find_checkbox(scene)
	if cb != null:
		_fs_check = cb
		cb.button_pressed = true
		cb.disabled = true


func _find_checkbox(n: Node) -> CheckBox:
	if n is CheckBox:
		return n as CheckBox
	for c in n.get_children():
		var r := _find_checkbox(c)
		if r != null:
			return r
	return null


func _apply_joystick(delta: float) -> void:
	# frame rate independent smoothing for a steady, non jittery walk
	var t := 1.0 - exp(-JOY_SMOOTH * delta)
	_joy_smooth = _joy_smooth.lerp(_joy_target, t)
	_joy_knob = _joy_knob.lerp(_joy_pos, 1.0 - exp(-KNOB_SMOOTH * delta))
	if _joy_touch < 0 and _joy_smooth.length() < 0.001:
		_joy_smooth = Vector2.ZERO
	var v := _joy_smooth
	if v.length() < DEAD_ZONE:
		v = Vector2.ZERO
	_set_action("move_left", -v.x)
	_set_action("move_right", v.x)
	_set_action("move_up", -v.y)
	_set_action("move_down", v.y)
	if AUTO_RUN and _joy_touch >= 0 and not _button_holds("run"):
		_set_action("run", 1.0 if v.length() >= RUN_THRESHOLD else 0.0)


func _button_holds(action: String) -> bool:
	for b in _buttons:
		if b.action == action and b.held:
			return true
	return false


func _set_action(action: String, strength: float) -> void:
	if strength > 0.02:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)

func _consume() -> void:
	get_viewport().set_input_as_handled()

# ---------------------------------------------------------------- player / menu

func _track_player() -> void:
	var g := get_tree().root.get_node_or_null("/root/Global")
	var p = null
	if g:
		p = g.get("player")
	if p == null:
		_player = null
		_pivot = null
		_ui_mode = true
		return
	_ui_mode = false
	if p != _player:
		_player = p
		_pivot = p.get_node_or_null("CameraPivot") as Node3D
		_cam = _pivot.get_node_or_null("Camera3D") as Camera3D if _pivot else null
		_crouching = false
		_crouch_blend = 0.0
		_stand_camera_y = -1.0
		_stand_capsule = -1.0
		_capsule_shape = null
		_stand_cam_y = _cam.position.y if _cam else 0.0
		_collect_slots()
		print("[TOUCH] player found: ", p.name, " inventory slots: ", _slots.size())

func _inject_click(pos: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.global_position = pos
	get_viewport().push_input(mm)
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	mb.position = pos
	mb.global_position = pos
	get_viewport().push_input(mb)
	var mb2 := InputEventMouseButton.new()
	mb2.button_index = MOUSE_BUTTON_LEFT
	mb2.pressed = false
	mb2.position = pos
	mb2.global_position = pos
	get_viewport().push_input(mb2)

# ---------------------------------------------------------------- game HUD

func _over_game_button(pos: Vector2) -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	return _find_button_at(scene, pos)

func _find_button_at(n: Node, pos: Vector2) -> bool:
	if n is BaseButton:
		var b := n as BaseButton
		if b.is_visible_in_tree() and b.get_global_rect().has_point(pos):
			return true
	for c in n.get_children():
		if _find_button_at(c, pos):
			return true
	return false

# --- the game's inventory bar (Slot1..Slot4) ------------------------------

func _collect_slots() -> void:
	_slots.clear()
	if _player == null or not is_instance_valid(_player):
		return
	var ui = _player.get_node_or_null("UI")
	if ui == null:
		return
	for i in 4:
		var slot = _find_slot(ui, "Slot" + str(i + 1))
		if slot != null:
			_slots.append(slot)

func _find_slot(n: Node, target: String) -> Node:
	if n.name == target:
		return n
	for c in n.get_children():
		var r = _find_slot(c, target)
		if r != null:
			return r
	return null

func _slot_at(pos: Vector2) -> int:
	for i in _slots.size():
		var slot = _slots[i]
		if slot == null or not is_instance_valid(slot):
			continue
		var c := slot as Control
		if c == null or not c.is_visible_in_tree():
			continue
		if c.get_global_rect().has_point(pos):
			return i
	return -1

# ---------------------------------------------------------------- drawing

func _draw_ui() -> void:
	if _ui_mode:
		return
	var c := _canvas
	var r := BTN_R * _scale
	var jr := JOY_RADIUS * _scale
	# joystick
	if _joy_touch >= 0:
		c.draw_circle(_joy_origin, jr, Color(1, 1, 1, 0.10))
		c.draw_arc(_joy_origin, jr, 0, TAU, 48, Color(1, 1, 1, 0.35), 3.0)
		c.draw_circle(_joy_knob, 30.0 * _scale, Color(1, 1, 1, 0.35))
	# while idle nothing is drawn: the joystick appears only under the thumb
	# buttons
	var font := ThemeDB.fallback_font
	for b in _buttons:
		var col := Color(1, 1, 1, 0.16)
		if b.held:
			col = Color(0.4, 0.9, 1.0, 0.45)
		c.draw_circle(b.rect.get_center(), r, col)
		c.draw_arc(b.rect.get_center(), r, 0, TAU, 32, Color(1, 1, 1, 0.45), 2.0)
		var fs := int(18 * _scale)
		var w := font.get_string_size(b.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		c.draw_string(font, b.rect.get_center() + Vector2(-w * 0.5, fs * 0.35), b.label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.85))
