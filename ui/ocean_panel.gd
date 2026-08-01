extends PanelContainer
## Native Godot UI that replaces the old ImGui debug GUI.

signal mesh_quality_changed(index: int)

var water: Node
var camera: Camera3D

@onready var fps_label: Label = %FpsLabel
@onready var camera_label: Label = %CameraLabel
@onready var spray_checkbox: CheckBox = %SprayCheckbox
@onready var resolution_option: OptionButton = %ResolutionOption
@onready var quality_option: OptionButton = %QualityOption
@onready var updates_slider: HSlider = %UpdatesSlider
@onready var updates_value: Label = %UpdatesValue
@onready var water_color_button: ColorPickerButton = %WaterColorButton
@onready var foam_color_button: ColorPickerButton = %FoamColorButton
@onready var cascade_tabs: TabContainer = %CascadeTabs
@onready var fov_slider: HSlider = %FovSlider
@onready var fov_value: Label = %FovValue
@onready var footer_label: Label = %FooterLabel
@onready var quit_button: Button = %QuitButton

func _ready() -> void:
	var modifier := 'Cmd' if OS.get_name() == 'macOS' else 'Ctrl'
	footer_label.text = 'Esc: show GUI / free mouse\n%s-H: toggle GUI   %s-F: toggle fullscreen' % [modifier, modifier]
	quit_button.pressed.connect(func(): get_tree().quit())

## Wires the UI up to the water and camera. Called by main.gd after the scene is ready.
func build_ui() -> void:
	spray_checkbox.set_pressed_no_signal(water.get_node('WaterSprayEmitter').visible)
	spray_checkbox.toggled.connect(func(on: bool): water.get_node('WaterSprayEmitter').visible = on)

	var resolutions := [128, 256, 512]
	resolution_option.clear()
	for size in resolutions:
		resolution_option.add_item('%dx%d' % [size, size], size)
	resolution_option.select(resolutions.find(water.map_size))
	resolution_option.item_selected.connect(func(index: int): water.map_size = resolution_option.get_item_id(index))

	var quality_keys: Array = water.MeshQuality.keys()
	quality_option.clear()
	for i in quality_keys.size():
		quality_option.add_item(String(quality_keys[i]).capitalize(), i)
	quality_option.select(water.mesh_quality)
	quality_option.item_selected.connect(func(index: int):
		water.mesh_quality = index
		mesh_quality_changed.emit(index))

	updates_slider.max_value = 60.0
	updates_slider.value = water.updates_per_second
	updates_value.text = '%.0f' % water.updates_per_second
	updates_slider.value_changed.connect(func(value: float):
		water.updates_per_second = value
		updates_value.text = '%.0f' % value)

	water_color_button.color = water.water_color
	water_color_button.color_changed.connect(func(color: Color): water.water_color = color)
	foam_color_button.color = water.foam_color
	foam_color_button.color_changed.connect(func(color: Color): water.foam_color = color)

	fov_slider.value = camera.fov
	fov_value.text = '%.0f' % camera.fov
	fov_slider.value_changed.connect(func(value: float):
		camera.fov = value
		fov_value.text = '%.0f' % value)

	for i in water.parameters.size():
		_build_cascade_tab(i)

func _build_cascade_tab(index: int) -> void:
	var params: Resource = water.parameters[index]
	var tab := VBoxContainer.new()
	tab.name = 'Cascade %d' % (index + 1)
	tab.add_theme_constant_override('separation', 6)
	cascade_tabs.add_child(tab)

	var tile_length_row := HBoxContainer.new()
	tile_length_row.add_theme_constant_override('separation', 8)
	tile_length_row.add_child(_make_label('Tile Length:', "Denotes the distance the cascade's tile should cover (in meters)."))
	var tile_x := _make_spin_box(params.tile_length.x, 1.0, 1000.0, 1.0)
	tile_x.value_changed.connect(func(value: float): params.tile_length = Vector2(value, params.tile_length.y))
	var tile_y := _make_spin_box(params.tile_length.y, 1.0, 1000.0, 1.0)
	tile_y.value_changed.connect(func(value: float): params.tile_length = Vector2(params.tile_length.x, value))
	tile_length_row.add_child(tile_x)
	tile_length_row.add_child(tile_y)
	tab.add_child(tile_length_row)

	_add_slider_row(tab, 'Displacement Scale:', '', 0.0, 2.0, 0.01, params.displacement_scale, func(value: float): params.displacement_scale = value)
	_add_slider_row(tab, 'Normal Scale:', '', 0.0, 2.0, 0.01, params.normal_scale, func(value: float): params.normal_scale = value)

	_add_spin_row(tab, 'Wind Speed:', 'Denotes the average wind speed above the water (in meters per second).\nIncreasing makes waves steeper and more \'chaotic\'.', params.wind_speed, 0.0, 100.0, 0.1, func(value: float): params.wind_speed = value)
	_add_slider_row(tab, 'Wind Direction:', '', -360.0, 360.0, 1.0, params.wind_direction, func(value: float): params.wind_direction = value)
	_add_spin_row(tab, 'Fetch Length:', 'Denotes the distance from shoreline (in kilometers).\nIncreasing makes waves steeper, but reduces their \'choppiness\'.', params.fetch_length, 0.0, 1000.0, 1.0, func(value: float): params.fetch_length = value)
	_add_slider_row(tab, 'Swell:', 'Modifies waves to clump in a more elongated, parallel manner.', 0.0, 2.0, 0.01, params.swell, func(value: float): params.swell = value)
	_add_slider_row(tab, 'Spread:', 'Modifies how much wind and swell affect the direction of the waves.', 0.0, 1.0, 0.01, params.spread, func(value: float): params.spread = value)
	_add_slider_row(tab, 'Detail:', 'Modifies the attenuation of high frequency waves.', 0.0, 1.0, 0.01, params.detail, func(value: float): params.detail = value)
	_add_slider_row(tab, 'Whitecap:', 'Modifies how steep a wave needs to be before foam can accumulate.', 0.0, 2.0, 0.01, params.whitecap, func(value: float): params.whitecap = value)
	_add_slider_row(tab, 'Foam Amount:', '', 0.0, 10.0, 0.01, params.foam_amount, func(value: float): params.foam_amount = value)

func _make_label(text: String, tooltip: String) -> Label:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tooltip
	label.custom_minimum_size = Vector2(175, 0)
	return label

func _make_slider(value: float, min_value: float, max_value: float, step: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.custom_minimum_size = Vector2(150, 0)
	slider.value = value
	return slider

func _make_spin_box(value: float, min_value: float, max_value: float, step: float) -> SpinBox:
	var spin_box := SpinBox.new()
	spin_box.min_value = min_value
	spin_box.max_value = max_value
	spin_box.step = step
	spin_box.custom_minimum_size = Vector2(140, 0)
	spin_box.value = value
	return spin_box

func _add_slider_row(parent: VBoxContainer, title: String, tooltip: String, min_value: float, max_value: float, step: float, value: float, on_changed: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override('separation', 8)
	row.add_child(_make_label(title, tooltip))
	var slider := _make_slider(value, min_value, max_value, step)
	slider.value_changed.connect(on_changed)
	row.add_child(slider)
	parent.add_child(row)

func _add_spin_row(parent: VBoxContainer, title: String, tooltip: String, value: float, min_value: float, max_value: float, step: float, on_changed: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override('separation', 8)
	row.add_child(_make_label(title, tooltip))
	var spin_box := _make_spin_box(value, min_value, max_value, step)
	spin_box.value_changed.connect(on_changed)
	row.add_child(spin_box)
	parent.add_child(row)

func update_dynamic() -> void:
	var fps := Engine.get_frames_per_second()
	fps_label.text = 'FPS: %d (%.2fms)' % [fps, 1000.0 / fps]
	camera_label.text = 'Camera Position: %+.2v' % camera.global_position

## Returns true when the GUI should capture mouse/keyboard input so the
## free-look camera stays still. A visible panel counts as active (Esc shows
## the GUI to free the cursor); otherwise only hover and text-focus count.
func is_ui_active() -> bool:
	if visible:
		return true
	var viewport := get_viewport()
	if viewport.gui_get_hovered_control() != null:
		return true
	var focus := viewport.gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is CodeEdit
