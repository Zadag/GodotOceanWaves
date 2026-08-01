@tool
extends Node3D

var clipmap_tile_size := 1.0 # Not the smallest tile size, but one that reduces the amount of vertex jitter.
var previous_tile := Vector3i.MAX

@onready var viewport : Variant = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera : Variant = viewport.get_camera_3d()
@onready var water := $Water
@onready var ocean_panel := $UICanvas/OceanPanel

func _init() -> void:
	if Engine.is_editor_hint(): return
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Size the game window to roughly fill the screen instead of the small default.
	var screen_size := Vector2(DisplayServer.screen_get_size())
	var window_size := Vector2i((screen_size * 0.9).floor())
	var window_position := ((screen_size - Vector2(window_size)) / 2.0).floor()
	DisplayServer.window_set_size(window_size)
	DisplayServer.window_set_position(Vector2i(window_position))

func _ready() -> void:
	if Engine.is_editor_hint():
		ocean_panel.visible = false
		return
	ocean_panel.water = water
	ocean_panel.camera = camera
	ocean_panel.build_ui()
	ocean_panel.mesh_quality_changed.connect(_on_mesh_quality_changed)

func _process(delta : float) -> void:
	if not Engine.is_editor_hint():
		ocean_panel.update_dynamic()
		camera.enable_camera_movement = not ocean_panel.is_ui_active()

func _physics_process(delta: float) -> void:
	# Shift water mesh whenever player moves into a new tile.
	var tile := (Vector3(camera.global_position.x, 0.0, camera.global_position.z) / clipmap_tile_size).ceil()
	if not tile.is_equal_approx(previous_tile):
		water.global_position = tile * clipmap_tile_size
		previous_tile = tile

	# Vary audio samples based on total wind speed across all cascades.
	var total_wind_speed := 0.0
	for params in water.parameters:
		total_wind_speed += params.wind_speed
	$OceanAudioPlayer.volume_db = lerpf(-30.0, 15.0, minf(total_wind_speed/15.0, 1.0))
	$WindAudioPlayer.volume_db = lerpf(5.0, -30.0, minf(total_wind_speed/15.0, 1.0))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_imgui'):
		ocean_panel.visible = not ocean_panel.visible
	elif event.is_action_pressed(&'toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&'ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

func _on_mesh_quality_changed(index: int) -> void:
	clipmap_tile_size = 1.0 if index == water.MeshQuality.HIGH else 4.0
