extends SceneTree
## Run: Godot --headless --path . --script tools/test_deck_wash.gd
const Wash := preload('res://assets/water/deck_wash.gd')
const RECT := Vector4(-2.6251, -8.2, 0.19248, 0.060976)
var failures := 0

func _init() -> void:
	var start := Time.get_ticks_msec()
	var dry := make_wash()
	run_steps(dry, 120, Vector3(2.0, -9.5, 0.8))
	check(volume(dry) == 0.0, 'Dry deck stays dry even when tilted')
	dry.free()

	var closed := make_wash()
	closed.drainage = 0.0
	# Turn every ocean boundary into a wall to isolate conservation.
	for e in range(closed._edge_a.size() - 1, -1, -1):
		if closed._kind[closed._edge_a[e]] == 0 or closed._kind[closed._edge_b[e]] == 0:
			closed._edge_a.remove_at(e)
			closed._edge_b.remove_at(e)
			closed._edge_axis.remove_at(e)
	for i in Wash.COUNT:
		if closed._kind[i] == 1 and closed._local_xz(i).y > 4.0:
			closed._depth[i] = 0.5
	var initial := volume(closed)
	run_steps(closed, 240, Vector3(1.0, -9.7, 0.0))
	check(absf(volume(closed) - initial) < initial * 0.0001, 'Internal flow conserves water volume')
	check(valid_depths(closed), 'Depths stay finite/nonnegative and cabin stays dry')
	closed.free()

	var small := make_wash()
	var large := make_wash()
	set_boundary(small, 0.15)
	set_boundary(large, 0.8)
	run_steps(small, 180)
	run_steps(large, 180)
	check(volume(large) > volume(small) * 2.0, 'Higher crest produces substantially more spillover')
	check(wet_cells(large) > wet_cells(small), 'Higher crest reaches farther across the deck')
	print('Spill volumes small/large (m3): ', volume(small), ' / ', volume(large))
	print('Wet cell counts small/large: ', wet_cells(small), ' / ', wet_cells(large))
	var flooded := volume(large)
	set_boundary(large, 0.0)
	run_steps(large, 120)
	check(volume(large) > 0.0, 'Wash persists after offshore crest recedes')
	run_steps(large, 840, Vector3(2.0, -9.5, 0.0))
	check(volume(large) < flooded * 0.25, 'Water drains off a rolling deck')
	check(Array(large._wet).max() > 0.1, 'Wet sheen survives drainage')
	check(valid_depths(large), 'Runoff remains stable and respects cabin obstacle')
	small.free()
	large.free()
	print('Deck wash tests finished in ', Time.get_ticks_msec() - start, ' ms; failures: ', failures)
	quit(0 if failures == 0 else 1)

func make_wash() -> Wash:
	var wash := Wash.new()
	wash._rect = RECT
	wash._cell = Vector2(1.0 / RECT.z / Wash.W, 1.0 / RECT.w / Wash.H)
	var outline := load('res://assets/water/hull_sdf.png').get_image() as Image
	if outline.is_compressed(): outline.decompress()
	wash._build_grid(outline)
	return wash

func run_steps(wash, steps: int, gravity := Vector3(0.0, -9.81, 0.0)) -> void:
	for i in steps: wash.simulate_step(Wash.STEP, gravity)

func set_boundary(wash, head: float) -> void:
	for i in wash._ocean_cells:
		wash._depth[i] = head if wash._local_xz(i).x < 0.0 else 0.0

func volume(wash) -> float:
	var result := 0.0
	for i in Wash.COUNT:
		if wash._kind[i] == 1: result += wash._depth[i] * wash._cell.x * wash._cell.y
	return result

func wet_cells(wash) -> int:
	var result := 0
	for i in Wash.COUNT:
		if wash._kind[i] == 1 and wash._depth[i] > 0.01: result += 1
	return result

func valid_depths(wash) -> bool:
	for i in Wash.COUNT:
		if not is_finite(wash._depth[i]) or wash._depth[i] < -0.00001: return false
		if wash._kind[i] == 2 and wash._depth[i] != 0.0: return false
	return true

func check(ok: bool, message: String) -> void:
	print('PASS: ' if ok else 'FAIL: ', message)
	if not ok: failures += 1
