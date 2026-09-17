extends Node3D
## First-person ship controller (CS-style): mouse look + arrow keys/WASD to walk
## around the deck. Parented to the ship, so all movement happens in the ship's
## local plane — the character stays glued to the deck as the hull pitches and
## rolls. Right-click captures/releases the mouse.

@export_range(0.1, 10.0) var move_speed := 4.0
@export_range(0.1, 10.0) var mouse_sensitivity := 3.0
@export var walk_bounds := Vector2(2.2, 7.8)   # Max deck offsets in ship-local XZ.

const CABIN_CENTER := Vector2(0.0, -0.6)   # Cabin footprint in ship-local XZ.
const CABIN_HALF := Vector2(1.2, 3.1)
const OBSTACLE_MARGIN := 0.3

var enable_camera_movement := true:
	set(value):
		if value == enable_camera_movement:
			return
		enable_camera_movement = value
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE)

@onready var camera: Camera3D = $Camera

var _yaw := 0.0
var _pitch := 0.0

func _ready() -> void:
	_yaw = rotation.y
	if enable_camera_movement:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	if not enable_camera_movement:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	elif event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x / 1000.0 * mouse_sensitivity
		_pitch -= event.relative.y / 1000.0 * mouse_sensitivity
		_pitch = clampf(_pitch, -1.5, 1.5)
		rotation.y = _yaw
		camera.rotation.x = _pitch

func _physics_process(delta: float) -> void:
	if not enable_camera_movement:
		return
	var input := Vector2(
		float(Input.is_action_pressed(&'move_right')) - float(Input.is_action_pressed(&'move_left')),
		float(Input.is_action_pressed(&'move_forward')) - float(Input.is_action_pressed(&'move_backward'))
	)
	if input == Vector2.ZERO:
		return
	var dir := transform.basis * Vector3(input.x, 0.0, -input.y)
	var new_pos := position + dir * move_speed * delta
	var plane_pos := _resolve_obstacles(Vector2(new_pos.x, new_pos.z))
	plane_pos.x = clampf(plane_pos.x, -walk_bounds.x, walk_bounds.x)
	plane_pos.y = clampf(plane_pos.y, -walk_bounds.y, walk_bounds.y)
	position.x = plane_pos.x
	position.z = plane_pos.y

## Keeps the player out of the cabin by pushing them to the nearest cabin face.
func _resolve_obstacles(plane_pos: Vector2) -> Vector2:
	var min_c := CABIN_CENTER - CABIN_HALF - Vector2(OBSTACLE_MARGIN, OBSTACLE_MARGIN)
	var max_c := CABIN_CENTER + CABIN_HALF + Vector2(OBSTACLE_MARGIN, OBSTACLE_MARGIN)
	var closest := Vector2(clampf(plane_pos.x, min_c.x, max_c.x), clampf(plane_pos.y, min_c.y, max_c.y))
	if plane_pos != closest:
		return plane_pos
	var left := plane_pos.x - min_c.x
	var right := max_c.x - plane_pos.x
	var top := plane_pos.y - min_c.y
	var bottom := max_c.y - plane_pos.y
	var d := minf(minf(left, right), minf(top, bottom))
	if d == left:
		plane_pos.x = min_c.x
	elif d == right:
		plane_pos.x = max_c.x
	elif d == top:
		plane_pos.y = min_c.y
	else:
		plane_pos.y = max_c.y
	return plane_pos
