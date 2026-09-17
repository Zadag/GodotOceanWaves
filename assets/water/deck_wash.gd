extends MeshInstance3D
## Ship-local shallow-water sheet. Inertial face fluxes conserve water between
## cells; the ocean is an open boundary and the cabin is a no-flow boundary.
## Separate wetness survives drainage. No ocean readback beyond 20 edge probes.

const W := 28
const H := 88
const COUNT := W * H
const STEP := 1.0 / 120.0
const SHADER := preload('res://assets/shaders/spatial/deck_wash.gdshader')

## Controls incoming water volume and speed; higher crests naturally drive more flow.
@export_range(0.1, 2.0) var spill_strength := 1.0
## Slow loss through deck drains, in addition to runoff over the sides.
@export_range(0.0, 1.0) var drainage := 0.12
@export_range(1.0, 60.0) var drying_time := 18.0
## Cabin footprint, in ship-local XZ (matches the player obstacle).
@export var cabin_rect := Rect2(-1.2, -3.7, 2.4, 6.2)

var _ship: RigidBody3D
var _sampler: Node
var _rect: Vector4
var _deck_height := 1.45
var _cell := Vector2.ONE
var _kind := PackedByteArray() # 0: ocean, 1: deck, 2: solid cabin
var _depth := PackedFloat32Array()
var _foam := PackedFloat32Array()
var _wet := PackedFloat32Array()
var _outgoing := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vz := PackedFloat32Array()
var _edge_a := PackedInt32Array()
var _edge_b := PackedInt32Array()
var _edge_axis := PackedByteArray()
var _velocity := PackedFloat32Array()
var _flux := PackedFloat32Array()
var _points := PackedVector2Array()
var _indices := PackedInt32Array()
var _heads := PackedFloat32Array()
var _ocean_cells := PackedInt32Array()
var _probe_a := PackedInt32Array()
var _probe_b := PackedInt32Array()
var _probe_blend := PackedFloat32Array()
var _state_image: Image
var _wet_image: Image
var _state_texture: ImageTexture
var _wet_texture: ImageTexture
var _accumulator := 0.0
var _upload_time := 0.0

func setup(ship: RigidBody3D, sampler: Node, sdf: Texture2D, rect: Vector4, deck_height: float) -> void:
	_ship = ship
	_sampler = sampler
	_rect = rect
	_deck_height = deck_height
	_cell = Vector2(1.0 / rect.z / W, 1.0 / rect.w / H)
	var outline := sdf.get_image()
	if outline.is_compressed(): outline.decompress()
	_build_grid(outline)
	_build_probes(outline)
	_build_surface(sdf)
	# Run after the ship has submitted its floater/corner positions.
	process_physics_priority = 1

func _local_xz(i: int) -> Vector2:
	return Vector2(_rect.x, _rect.y) + (Vector2(i % W, i / W) + Vector2(0.5, 0.5)) * _cell

func _sdf_at(outline: Image, p: Vector2) -> float:
	var uv := (p - Vector2(_rect.x, _rect.y)) * Vector2(_rect.z, _rect.w)
	return (outline.get_pixel(clampi(int(uv.x * outline.get_width()), 0, outline.get_width() - 1), clampi(int(uv.y * outline.get_height()), 0, outline.get_height() - 1)).r - 0.5) * 4.0

func _build_grid(outline: Image) -> void:
	_kind.resize(COUNT)
	_depth.resize(COUNT)
	_foam.resize(COUNT)
	_wet.resize(COUNT)
	_outgoing.resize(COUNT)
	_vx.resize(COUNT)
	_vz.resize(COUNT)
	for i in COUNT:
		var p := _local_xz(i)
		_kind[i] = 1 if _sdf_at(outline, p) < 0.0 else 0
		if cabin_rect.has_point(p): _kind[i] = 2
		if _kind[i] == 0: _ocean_cells.append(i)
	for i in COUNT:
		if i % W < W - 1: _add_edge(i, i + 1, 0)
		if i / W < H - 1: _add_edge(i, i + W, 1)
	_velocity.resize(_edge_a.size())
	_flux.resize(_edge_a.size())

func _add_edge(a: int, b: int, axis: int) -> void:
	if _kind[a] == 2 or _kind[b] == 2: return
	if _kind[a] == 0 and _kind[b] == 0: return
	_edge_a.append(a)
	_edge_b.append(b)
	_edge_axis.append(axis)

func _build_probes(outline: Image) -> void:
	# Approximately uniform coverage along the two long sides, plus bow/stern.
	for row in 9:
		var z := lerpf(-7.1, 7.1, float(row) / 8.0)
		for side in [-1.0, 1.0]:
			var x := 0.0
			while x < 2.6 and _sdf_at(outline, Vector2(x * side, z)) < 0.0:
				x += 0.04
			_points.append(Vector2(x * side, z))
	_points.append(Vector2(0.0, -7.95))
	_points.append(Vector2(0.0, 7.95))
	for p in _points:
		_indices.append(_sampler.register_point(_ship.to_global(Vector3(p.x, _deck_height, p.y))) if _sampler else -1)
	_heads.resize(_points.size())
	# Cache interpolation so no perimeter search is needed during simulation.
	for i in _ocean_cells:
		var p := _local_xz(i)
		var a := 0
		var b := 0
		var da := INF
		var db := INF
		for j in _points.size():
			var d := p.distance_squared_to(_points[j])
			if d < da:
				b = a
				db = da
				a = j
				da = d
			elif d < db:
				b = j
				db = d
		_probe_a.append(a)
		_probe_b.append(b)
		_probe_blend.append(da / maxf(da + db, 0.0001))

func _build_surface(sdf: Texture2D) -> void:
	_state_image = Image.create(W, H, false, Image.FORMAT_RGBAF)
	_wet_image = Image.create(W, H, false, Image.FORMAT_RF)
	_state_texture = ImageTexture.create_from_image(_state_image)
	_wet_texture = ImageTexture.create_from_image(_wet_image)
	var plane := PlaneMesh.new()
	plane.size = Vector2(1.0 / _rect.z, 1.0 / _rect.w)
	plane.subdivide_width = W * 2
	plane.subdivide_depth = H * 2
	mesh = plane
	position = Vector3(_rect.x + plane.size.x * 0.5, _deck_height + 0.012, _rect.y + plane.size.y * 0.5)
	custom_aabb = AABB(Vector3(-plane.size.x * 0.5, -0.1, -plane.size.y * 0.5), Vector3(plane.size.x, 5.0, plane.size.y))
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter(&'wash_state', _state_texture)
	mat.set_shader_parameter(&'wetness_map', _wet_texture)
	mat.set_shader_parameter(&'hull_sdf', sdf)
	mat.set_shader_parameter(&'hull_uv_rect', _rect)
	mat.set_shader_parameter(&'cell_size', _cell)
	mat.set_shader_parameter(&'cabin_rect', Vector4(cabin_rect.position.x, cabin_rect.position.y, cabin_rect.end.x, cabin_rect.end.y))
	material_override = mat

func _physics_process(delta: float) -> void:
	if _ship == null or _sampler == null: return
	for j in _points.size():
		var p := _points[j]
		var world := _ship.to_global(Vector3(p.x, _deck_height, p.y))
		_sampler.set_point(_indices[j], world)
		# Keep signed heights while interpolating: a dry neighbour must not inject water.
		_heads[j] = (_sampler.get_height(_indices[j]) - world.y) / maxf(_ship.global_basis.y.y, 0.35)
	for j in _ocean_cells.size():
		_depth[_ocean_cells[j]] = clampf(lerpf(_heads[_probe_a[j]], _heads[_probe_b[j]], _probe_blend[j]) * spill_strength, 0.0, 3.0)
	var gravity_local := _ship.global_basis.inverse() * Vector3(0.0, -9.81, 0.0)
	_accumulator = minf(_accumulator + delta, STEP * 8.0)
	while _accumulator >= STEP:
		simulate_step(STEP, gravity_local)
		_accumulator -= STEP
	_upload_time += delta
	if _upload_time >= 1.0 / 30.0:
		_upload_time = 0.0
		_upload_surface()

## Kept independent of rendering/sampling so conservation and drainage can be tested.
func simulate_step(dt: float, gravity_local: Vector3) -> void:
	_outgoing.fill(0.0)
	_vx.fill(0.0)
	_vz.fill(0.0)
	var gravity_normal := maxf(-gravity_local.y, 0.5)
	for e in _edge_a.size():
		var a := _edge_a[e]
		var b := _edge_b[e]
		var axis := _edge_axis[e]
		var spacing := _cell.x if axis == 0 else _cell.y
		var slope_force := gravity_local.x if axis == 0 else gravity_local.z
		var acceleration := gravity_normal * (_depth[a] - _depth[b]) / spacing + slope_force
		var v := (_velocity[e] + acceleration * dt) / (1.0 + dt * (1.8 + absf(_velocity[e]) * 0.5))
		v = clampf(v, -5.0, 5.0)
		var donor := a if v > 0.0 else b
		if _depth[donor] < 0.0001: v = 0.0
		_velocity[e] = v
		var transfer := v * _depth[donor] * dt / spacing
		_flux[e] = transfer
		_outgoing[donor] += absf(transfer)
	# Limit the TOTAL outflow from each donor, then apply the same flux at both
	# ends. Clamping each receiver independently would manufacture water.
	for e in _edge_a.size():
		var a := _edge_a[e]
		var b := _edge_b[e]
		var donor := a if _flux[e] > 0.0 else b
		var limit := minf(1.0, _depth[donor] / maxf(_outgoing[donor], 0.000001)) if _kind[donor] == 1 else 1.0
		_flux[e] *= limit
		_velocity[e] *= limit
	for e in _edge_a.size():
		var a := _edge_a[e]
		var b := _edge_b[e]
		if _kind[a] == 1: _depth[a] -= _flux[e]
		if _kind[b] == 1: _depth[b] += _flux[e]
		if _edge_axis[e] == 0:
			_vx[a] += _velocity[e] * 0.5
			_vx[b] += _velocity[e] * 0.5
		else:
			_vz[a] += _velocity[e] * 0.5
			_vz[b] += _velocity[e] * 0.5
	for i in COUNT:
		if _kind[i] != 1: continue
		_depth[i] = maxf(0.0, _depth[i]) * exp(-drainage * dt)
		var speed := Vector2(_vx[i], _vz[i]).length()
		var front := smoothstep(0.006, 0.06, _depth[i]) * (1.0 - smoothstep(0.12, 0.6, _depth[i]))
		var churn := clampf(speed * 0.32, 0.0, 1.0) * front
		_foam[i] = clampf(_foam[i] * exp(-dt * 0.65) + churn * dt * 1.6, 0.0, 1.0)
		_wet[i] = maxf(_wet[i] * exp(-dt / drying_time), smoothstep(0.001, 0.025, _depth[i]))

func _upload_surface() -> void:
	for i in COUNT:
		var h := _depth[i] if _kind[i] != 2 else 0.0
		_state_image.set_pixel(i % W, i / W, Color(h, _vx[i], _vz[i], _foam[i]))
		_wet_image.set_pixel(i % W, i / W, Color(_wet[i], 0.0, 0.0, 1.0))
	_state_texture.update(_state_image)
	_wet_texture.update(_wet_image)

## Actual retained water depth, independent of the current offshore crest.
func get_depth_at(local_xz: Vector2) -> float:
	var grid := (local_xz - Vector2(_rect.x, _rect.y)) / _cell
	if grid.x < 0.0 or grid.y < 0.0 or grid.x >= W or grid.y >= H: return 0.0
	var i := int(grid.y) * W + int(grid.x)
	return _depth[i] if _kind[i] == 1 else 0.0
