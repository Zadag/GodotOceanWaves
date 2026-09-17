extends RigidBody3D
## A buoyant ship that rides the waves sampled by a WaterSurfaceSampler using
## true Archimedean buoyancy (buoyancy from immersed volume), so the hull's mass
## sets its draft: heavier ships float lower and heave/rock more slowly.
##
## Each "Floater" marker child is the keel of a vertical column of the hull's
## waterplane. Every physics tick the sampler is asked for the wave height at
## each floater, and buoyancy = rho * g * (cell_area * submerged_depth) is
## applied at the submerged volume's centroid, which gives natural pitch/roll
## restoring.
##
## Stability measures:
##  - A low center of mass (keel ballast) gives a strong righting moment.
##  - Sampled heights are low-pass filtered so thin wave crests don't slam the
##    hull with an instant buoyancy spike (they "break" instead of lifting it).
##  - Buoyancy is stiffened by `buoyancy_stiffness` with a compensating preload,
##    so heave/roll track incoming waves faster without changing the draft.
##  - Forces act through the center of mass with explicit torques; drags are set
##    under critically damped so motion stays lively but cannot build forever.

@export var water_surface_sampler : NodePath
@export var water_density := 1000.0      # kg/m^3.
## Effective hull waterplane (m^2). Static draft = mass / (water_density * waterplane_area).
## Sized so the 33 t hull keeps the approved ~2.43 m draft (waterline ~+0.13 local):
## raise this together with mass or the hull rides visibly deeper.
@export var waterplane_area := 13.6
@export var hull_depth := 5.0            # Column height at which buoyancy saturates (fully submerged hull).
## Multiplies buoyancy stiffness WITHOUT shifting the static waterline (a matching
## preload cancels the extra force at equilibrium draft). Heave/roll respond this
## many times faster to incoming waves; 1.0 = pure Archimedean response.
@export_range(1.0, 4.0) var buoyancy_stiffness := 1.8
@export var water_drag := 2.0            # Linear damping (scaled by the floater's weight share).
@export var angular_drag := 0.7          # Torque damping factor (lower = livelier roll).
@export var height_smoothing := 0.05     # Seconds of low-pass filtering applied to sampled wave heights.
@export_range(-3.0, 0.0) var ballast_y := -1.8  # Center of mass height (local), deep in the keel.

@export_group('Water Interaction')
## Local Y of the weather deck. Offshore crests feed a separate shallow-water
## simulation here, so overtopping runs over the deck and around the cabin.
@export_range(0.0, 3.0) var deck_height := 1.45
## Local Y of the static waterline along the hull sides (draft-dependent).
## With 33 t on 13.6 m^2 the static draft is ~2.43 m -> waterline ~+0.13 local.
@export_range(-2.2, 1.5) var waterline_height := 0.15
## Meters a wave must rise above the deck for full-intensity crash splashes.
@export_range(0.2, 3.0) var crash_height_range := 1.0

const WATER_MAT := preload('res://assets/water/mat_water.tres')
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')

## Baked top-down signed distance field of the hull outline (assets/water/hull_sdf.png).
const HULL_SDF := preload('res://assets/water/hull_sdf.png')
## Ship-local rect of the baked silhouette: xy = min XZ corner, zw = 1/span XZ.
const HULL_UV_RECT := Vector4(-2.6251, -8.2, 0.19248, 0.060976)
const SDF_RANGE := 2.0   # Metres encoded between texel values 0.5 and 0.0/1.0.

## Ship-local XZ corners of the deck used to sample wave overtopping.
const DECK_SAMPLE_CORNERS := [Vector2(-1.8, -6.8), Vector2(1.8, -6.8), Vector2(1.8, 6.8), Vector2(-1.8, 6.8)]

var _sampler : Node
var _floaters : Array[Marker3D] = []
var _sample_indices : Array[int] = []
var _smoothed_heights : PackedFloat32Array = []
var _deck_indices : Array[int] = []
var _deck_overtopping := PackedFloat32Array()
var _splash_mat : ShaderMaterial
var _crash_intensity := 0.0
var _cached_map_scales := PackedVector4Array()
var _deck_wash: MeshInstance3D

func _ready() -> void:
	_sampler = get_node(water_surface_sampler) if not water_surface_sampler.is_empty() else null
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, ballast_y, 0.0)
	for child in get_children():
		if child is Marker3D and child.name.begins_with('Floater'):
			_floaters.append(child)
			_sample_indices.append(_sampler.register_point(child.global_position) if _sampler else -1)
	# Seed the filter with each floater's own height (depth 0) so buoyancy ramps in
	# gently instead of spiking the hull out of the water on the first physics tick.
	_smoothed_heights.resize(_floaters.size())
	for i in _floaters.size():
		_smoothed_heights[i] = _floaters[i].global_position.y
	for corner in DECK_SAMPLE_CORNERS:
		_deck_indices.append(_sampler.register_point(to_global(Vector3(corner.x, deck_height, corner.y))) if _sampler else -1)
	_deck_overtopping.resize(_deck_indices.size())
	_setup_water_interaction()
	_deck_wash = $DeckWash
	_deck_wash.setup(self, _sampler, HULL_SDF, HULL_UV_RECT, deck_height)

## Configures the water shader's hull mask/foam and the hull splash emitter.
func _setup_water_interaction() -> void:
	WATER_MAT.set_shader_parameter(&'ship_transform_inverse', global_transform.affine_inverse())
	WATER_MAT.set_shader_parameter(&'hull_sdf', HULL_SDF)
	WATER_MAT.set_shader_parameter(&'hull_uv_rect', HULL_UV_RECT)
	WATER_MAT.set_shader_parameter(&'sdf_range', SDF_RANGE)
	WATER_MAT.set_shader_parameter(&'deck_height_local', deck_height)
	WATER_MAT.set_shader_parameter(&'hull_foam', Vector4(to_global(Vector3(0.0, deck_height, 0.0)).y, 1.1, 1.0, 1.0))
	# Cull ALL ambient sea spray inside the hull silhouette (any height) — crest-riding
	# billboards would otherwise blanket the boat and read as a water sheet over the deck.
	SPRAY_MAT.set_shader_parameter(&'occluder_transform_inverse', global_transform.affine_inverse())
	SPRAY_MAT.set_shader_parameter(&'occluder_sdf', HULL_SDF)
	SPRAY_MAT.set_shader_parameter(&'occluder_uv_rect', HULL_UV_RECT)
	SPRAY_MAT.set_shader_parameter(&'occluder_sdf_range', SDF_RANGE)

	var emitter := get_node_or_null('HullSplashEmitter') as GPUParticles3D
	if emitter == null: return
	_splash_mat = emitter.process_material as ShaderMaterial
	if _splash_mat == null: return
	_splash_mat.set_shader_parameter(&'num_particles', emitter.amount)
	_splash_mat.set_shader_parameter(&'lifetime', emitter.lifetime)
	_splash_mat.set_shader_parameter(&'hull_sdf', HULL_SDF)
	_splash_mat.set_shader_parameter(&'hull_uv_rect', HULL_UV_RECT)
	_splash_mat.set_shader_parameter(&'sdf_range', SDF_RANGE)
	_splash_mat.set_shader_parameter(&'ship_transform_inverse', global_transform.affine_inverse())
	_splash_mat.set_shader_parameter(&'ring_heights', Vector4(waterline_height, deck_height, 0.45, 0.0))

func _process(delta: float) -> void:
	# Keep the water shader's hull mask glued to the ship (pitch/roll included).
	var inverse := global_transform.affine_inverse()
	WATER_MAT.set_shader_parameter(&'ship_transform_inverse', inverse)
	SPRAY_MAT.set_shader_parameter(&'occluder_transform_inverse', inverse)
	# Exact world Y of the deck plane (accounts for pitch/roll), used to gate the foam ring.
	WATER_MAT.set_shader_parameter(&'hull_foam', Vector4(to_global(Vector3(0.0, deck_height, 0.0)).y, 1.1, 1.0, 1.0))
	if _splash_mat != null:
		_splash_mat.set_shader_parameter(&'ship_transform_inverse', inverse)
	if _splash_mat == null: return

	# Mirror the water material's cascade scales into the splash shader (changes rarely).
	var map_scales : PackedVector4Array = WATER_MAT.get_shader_parameter(&'map_scales')
	if map_scales != _cached_map_scales:
		_cached_map_scales = map_scales
		_splash_mat.set_shader_parameter(&'map_scales', map_scales)

	# Crash intensity: how far the deepest deck overtopping rises above the deck, smoothed.
	if _deck_overtopping.is_empty(): return
	var excess := 0.0
	for d in _deck_overtopping:
		excess = maxf(excess, d)
	var target := clampf(excess / crash_height_range, 0.0, 1.0)
	_crash_intensity = lerpf(_crash_intensity, target, 1.0 - exp(-delta / 0.2))
	_splash_mat.set_shader_parameter(&'crash_intensity', _crash_intensity)

func _physics_process(delta: float) -> void:
	if not _sampler: return
	var filter := 1.0
	if height_smoothing > 0.0:
		filter = 1.0 - exp(-delta / height_smoothing)
	for i in _floaters.size():
		_sampler.set_point(_sample_indices[i], _floaters[i].global_position)
		_smoothed_heights[i] = lerpf(_smoothed_heights[i], _sampler.get_height(_sample_indices[i]), filter)
	for i in _deck_indices.size():
		var corner : Vector2 = DECK_SAMPLE_CORNERS[i]
		var corner_world := to_global(Vector3(corner.x, deck_height, corner.y))
		_sampler.set_point(_deck_indices[i], corner_world)
		# Overtopping depth: how far the wave surface sits above the deck at this corner.
		_deck_overtopping[i] = _sampler.get_height(_deck_indices[i]) - corner_world.y

## Wave overtopping depth (m) above the deck at the given ship-local XZ position.
## Bilinearly interpolates the four deck corner samples. 0.0 means the deck is dry;
## a player hitbox can use this to get swept overboard when it exceeds a threshold.
func get_overtopping_at(local_xz: Vector2) -> float:
	if _deck_overtopping.size() != DECK_SAMPLE_CORNERS.size(): return 0.0
	var u := clampf((local_xz.x / DECK_SAMPLE_CORNERS[2].x + 1.0)*0.5, 0.0, 1.0)
	var v := clampf((local_xz.y / DECK_SAMPLE_CORNERS[2].y + 1.0)*0.5, 0.0, 1.0)
	var near := lerpf(_deck_overtopping[0], _deck_overtopping[1], u) # stern corners
	var far := lerpf(_deck_overtopping[3], _deck_overtopping[2], u)  # bow corners
	return lerpf(near, far, v)

## Water actually on the deck, including wash remaining after the crest passes.
func get_deck_water_depth(local_xz: Vector2) -> float:
	return _deck_wash.get_depth_at(local_xz) if _deck_wash != null else 0.0

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if not _sampler or _floaters.is_empty(): return
	var count := _floaters.size()
	var cell_area := waterplane_area / count
	var gravity := -state.total_gravity.normalized() * state.total_gravity.length()
	var weight_share := mass / count
	var com_world := state.transform * center_of_mass
	for i in count:
		var floater_world := _floaters[i].global_position
		var depth : float = _smoothed_heights[i] - floater_world.y
		if depth <= 0.0: continue
		var submerged := minf(depth, hull_depth)
		var center := floater_world + Vector3(0.0, submerged * 0.5, 0.0)
		var velocity_at := state.linear_velocity + state.angular_velocity.cross(center - state.transform.origin)
		# Stiffened buoyancy: the gain multiplies the spring force while a constant
		# preload removes the extra at equilibrium, so draft is unchanged but the
		# hull's response rate scales by sqrt(buoyancy_stiffness).
		var buoyancy_kg := water_density * cell_area * submerged * buoyancy_stiffness - (buoyancy_stiffness - 1.0)*weight_share
		var force := gravity * buoyancy_kg - velocity_at * (weight_share * water_drag * (submerged / hull_depth))
		state.apply_force(force)
		state.apply_torque((center - com_world).cross(force))
	state.apply_torque(-state.angular_velocity * angular_drag * mass)
