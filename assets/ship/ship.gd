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
##  - Forces act through the center of mass with explicit torques, and drag is
##    tuned near critical damping so rocking cannot build into a feedback loop.

@export var water_surface_sampler : NodePath
@export var water_density := 1000.0      # kg/m^3.
@export var waterplane_area := 17.0      # Effective hull waterplane (m^2). With 28 t this gives ~1.65 m draft.
@export var hull_depth := 5.0            # Column height at which buoyancy saturates (fully submerged hull).
@export var water_drag := 3.0            # Linear damping (scaled by the floater's weight share).
@export var angular_drag := 1.2          # Torque damping factor.
@export var height_smoothing := 0.05     # Seconds of low-pass filtering applied to sampled wave heights.
@export_range(-3.0, 0.0) var ballast_y := -1.8  # Center of mass height (local), deep in the keel.

var _sampler : Node
var _floaters : Array[Marker3D] = []
var _sample_indices : Array[int] = []
var _smoothed_heights : PackedFloat32Array = []

func _ready() -> void:
	_sampler = get_node(water_surface_sampler) if not water_surface_sampler.is_empty() else null
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, ballast_y, 0.0)
	for child in get_children():
		if child is Marker3D and child.name.begins_with('Floater'):
			_floaters.append(child)
			_sample_indices.append(_sampler.register_point(child.global_position) if _sampler else -1)
	_smoothed_heights.resize(_floaters.size())

func _physics_process(delta: float) -> void:
	if not _sampler: return
	var filter := 1.0
	if height_smoothing > 0.0:
		filter = 1.0 - exp(-delta / height_smoothing)
	for i in _floaters.size():
		_sampler.set_point(_sample_indices[i], _floaters[i].global_position)
		_smoothed_heights[i] = lerpf(_smoothed_heights[i], _sampler.get_height(_sample_indices[i]), filter)

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
		var force := gravity * (water_density * cell_area * submerged) - velocity_at * (weight_share * water_drag * (submerged / hull_depth))
		state.apply_force(force)
		state.apply_torque((center - com_world).cross(force))
	state.apply_torque(-state.angular_velocity * angular_drag * mass)
