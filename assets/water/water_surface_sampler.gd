extends Node
## GPU water-surface sampler.
##
## Dispatches a tiny compute shader (water_surface.glsl) against the wave
## displacement maps produced by the water's WaveGenerator and reads the results
## back to the CPU. The shader mirrors the exact displacement accumulation in
## water.gdshader so other nodes (e.g. the demo ship) can query accurate wave
## heights at arbitrary world positions for buoyancy.
##
## Usage:
##   var index := sampler.register_point(world_pos)
##   sampler.set_point(index, world_pos)  # each tick
##   var height := sampler.get_height(index)

const MAX_SAMPLES := 32
const SHADER_PATH := 'res://assets/shaders/compute/water_surface.glsl'
const WATER_MAT := preload('res://assets/water/mat_water.tres')

@export var water_path : NodePath
var water : Node3D

var _context : RenderingContext
var _shader_rid := RID()
var _sampler_rid := RID()
var _texture_rid := RID()
var _set0 := RID()
var _set1 := RID()
var _set2 := RID()
var _uniform_buffer : RenderingContext.Descriptor
var _positions_buffer : RenderingContext.Descriptor
var _results_buffer : RenderingContext.Descriptor
var _pipeline : Callable

var _sample_positions : PackedVector3Array
var _sample_heights : PackedFloat32Array
var _num_samples := 0

func _init() -> void:
	_sample_positions.resize(MAX_SAMPLES)
	_sample_heights.resize(MAX_SAMPLES)

func _ready() -> void:
	water = get_node_or_null(water_path)
	if water == null:
		push_warning('WaterSurfaceSampler: no Water node assigned; sampler disabled.')
		set_physics_process(false)
		return
	_setup_gpu()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _context:
		_context.free()

func register_point(world_position := Vector3.ZERO) -> int:
	assert(_num_samples < MAX_SAMPLES, 'WaterSurfaceSampler: too many sample points!')
	var index := _num_samples
	_sample_positions[index] = world_position
	_sample_heights[index] = 0.0
	_num_samples += 1
	return index

func set_point(index: int, world_position: Vector3) -> void:
	_sample_positions[index] = world_position

func get_height(index: int) -> float:
	return _sample_heights[index]

func _setup_gpu() -> void:
	_context = RenderingContext.create(RenderingServer.get_rendering_device())
	if _context.device == null:
		push_warning('WaterSurfaceSampler: no rendering device available; sampler disabled.')
		set_physics_process(false)
		return
	_shader_rid = _context.load_shader(SHADER_PATH)

	var sampler_state := RDSamplerState.new()
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_sampler_rid = _context.deletion_queue.push(_context.device.sampler_create(sampler_state))

	_uniform_buffer = _context.create_uniform_buffer(144)
	_positions_buffer = _context.create_storage_buffer(MAX_SAMPLES * 16)
	_results_buffer = _context.create_storage_buffer(MAX_SAMPLES * 16)
	_set1 = _context.create_descriptor_set([_uniform_buffer], _shader_rid, 1)
	_set2 = _context.create_descriptor_set([_positions_buffer, _results_buffer], _shader_rid, 2)
	# Set 0 (displacement texture) is created lazily once the wave generator's
	# texture RID is available; see _ensure_set0().
	_pipeline = _context.create_pipeline([1, 1, 1], [_set1], _shader_rid)

func _ensure_set0() -> bool:
	if _set0.is_valid(): return true
	if not _texture_rid.is_valid(): return false
	var descriptor := RenderingContext.Descriptor.new(_texture_rid, RenderingDevice.UNIFORM_TYPE_TEXTURE)
	var sampler_descriptor := RenderingContext.Descriptor.new(_sampler_rid, RenderingDevice.UNIFORM_TYPE_SAMPLER)
	_set0 = _context.create_descriptor_set([descriptor, sampler_descriptor], _shader_rid, 0)
	return true

func _physics_process(_delta: float) -> void:
	if _num_samples == 0 or not _context: return
	if water == null or water.wave_generator == null: return

	# Rebind the displacement texture if it was recreated (e.g. cascade changes).
	var texture_rid : RID = water.displacement_maps.texture_rd_rid
	if texture_rid.is_valid() and texture_rid != _texture_rid:
		_texture_rid = texture_rid
		if _set0.is_valid():
			_context.deletion_queue.free_rid(_context.device, _set0)
			_set0 = RID()
	if not _ensure_set0(): return

	var map_scales : PackedVector4Array = WATER_MAT.get_shader_parameter(&'map_scales')
	var num_cascades : int = water.parameters.size()
	if num_cascades <= 0 or map_scales.is_empty(): return

	# --- Uniform buffer (std140 layout) ---
	var uniform_data := PackedByteArray()
	uniform_data.resize(144)
	var origin := Vector2(water.global_position.x, water.global_position.z)
	for i in 8:
		var scale := map_scales[i] if i < map_scales.size() else Vector4.ZERO
		var offset := i * 16
		uniform_data.encode_float(offset + 0, scale.x)
		uniform_data.encode_float(offset + 4, scale.y)
		uniform_data.encode_float(offset + 8, scale.z)
		uniform_data.encode_float(offset + 12, scale.w)
	uniform_data.encode_float(128, origin.x)
	uniform_data.encode_float(132, origin.y)
	uniform_data.encode_u32(136, num_cascades)
	uniform_data.encode_u32(140, _num_samples)
	_context.device.buffer_update(_uniform_buffer.rid, 0, 144, uniform_data)

	# --- Positions buffer (std430, vec4 per point) ---
	var pos_data := PackedByteArray()
	pos_data.resize(_num_samples * 16)
	for i in _num_samples:
		var p := _sample_positions[i]
		pos_data.encode_float(i * 16 + 0, p.x)
		pos_data.encode_float(i * 16 + 4, p.z)
	_context.device.buffer_update(_positions_buffer.rid, 0, _num_samples * 16, pos_data)

	# --- Dispatch + read back ---
	# Note: sync() is not allowed on the main device; the compute list is
	# auto-submitted at frame end, so results are one frame stale (fine for
	# buoyancy at physics tick rate).
	var compute_list := _context.compute_list_begin()
	_pipeline.call(_context, compute_list, PackedByteArray(), [_set0, _set1, _set2])
	_context.compute_list_end()
	var raw := _context.device.buffer_get_data(_results_buffer.rid)
	for i in _num_samples:
		_sample_heights[i] = raw.decode_float(i * 16 + 12)
