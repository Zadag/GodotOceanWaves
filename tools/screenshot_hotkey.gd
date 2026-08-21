extends Node
## Debug helpers (digit keys, so OS shortcut keys are not swallowed):
##   F10 = save a screenshot into res://screenshots/ (timestamped)
##   1   = toggle ambient sea-spray emitter
##   2   = toggle fog volume
##   3   = toggle water mask debug (masked ocean renders MAGENTA instead of hidden)
##   4   = toggle the ocean mesh itself
##   5   = toggle this debug overlay

const WATER_MAT := preload('res://assets/water/mat_water.tres')

var _label : Label
var _ship : Node3D
var _spray : Node3D
var _fog : Node3D
var _water : Node3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_label = Label.new()
	_label.position = Vector2(12, 12)
	_label.add_theme_font_size_override('font_size', 15)
	_label.add_theme_color_override('font_color', Color(1.0, 1.0, 0.3))
	_label.add_theme_color_override('font_outline_color', Color.BLACK)
	_label.add_theme_constant_override('outline_size', 6)
	layer.add_child(_label)

func _find_later() -> void:
	if _ship == null:
		_ship = get_tree().root.find_child('Ship', true, false) as Node3D
		_spray = get_tree().root.find_child('WaterSprayEmitter', true, false) as Node3D
		_fog = get_tree().root.find_child('FogVolume', true, false) as Node3D
		_water = get_tree().root.find_child('Water', true, false) as Node3D

func _process(_delta: float) -> void:
	if _label == null: return
	if _ship == null:
		_ship = get_tree().root.find_child('Ship', true, false) as Node3D
		_spray = get_tree().root.find_child('WaterSprayEmitter', true, false) as Node3D
		_fog = get_tree().root.find_child('FogVolume', true, false) as Node3D
		_water = get_tree().root.find_child('Water', true, false) as Node3D

	var foam: Variant = WATER_MAT.get_shader_parameter(&'hull_foam')
	var mask_enabled: bool = foam != null and (foam as Vector4).w > 0.5
	var text := 'mask=%s  mask_debug=%s  deck=%.2f' % [
		mask_enabled,
		true if WATER_MAT.get_shader_parameter(&'mask_debug') else false,
		WATER_MAT.get_shader_parameter(&'deck_height_local'),
	]
	if _ship is RigidBody3D:
		var draft : float = (_ship as RigidBody3D).mass / (1000.0 * 13.6)
		text += '\nship origin_y=%.2f  draft=%.2f' % [_ship.global_position.y, draft]
	if _spray: text += '\n[1] spray visible=%s' % _spray.visible
	if _fog: text += '\n[2] fog visible=%s' % _fog.visible
	if _water: text += '\n[4] water visible=%s' % _water.visible
	_label.text = text

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F10:
				_take_screenshot()
			KEY_1:
				_toggle(&'_spray')
			KEY_2:
				_toggle(&'_fog')
			KEY_3:
				var current: Variant = WATER_MAT.get_shader_parameter(&'mask_debug')
				WATER_MAT.set_shader_parameter(&'mask_debug', not (current if current != null else false))
			KEY_4:
				_toggle(&'_water')
			KEY_5:
				_label.visible = not _label.visible

func _toggle(field: StringName) -> void:
	var node := get(field) as Node3D
	if node == null:
		_process(0.0)
		node = get(field) as Node3D
	if node is Node3D:
		node.visible = not node.visible
		print('[debug] %s visible = %s' % [field, node.visible])

func _take_screenshot() -> void:
	var image := get_viewport().get_texture().get_image()
	var stamp := Time.get_datetime_string_from_system().replace(':', '-').replace(' ', '_')
	var path := 'res://screenshots/shot_%s.png' % stamp
	if image.save_png(path) != OK:
		push_warning('Screenshot save failed: %s' % path)
