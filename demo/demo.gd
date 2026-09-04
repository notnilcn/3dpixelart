extends Node3D
## Demo / test scene for the 3D Pixel Art addon (ProPixelizer port).
##
## Builds a small orthographic scene with pixelized objects of different
## pixel sizes, outlines and a slowly moving object (pixel-creep check),
## plus showcases: palette-LUT grading, sharp-bilinear texture sampling,
## banded cloud shadows + god rays, and a layered pixel-art water pond.
##
## Run with `-- --capture` to save a screenshot to res://demo/screenshot.png
## after a few seconds and quit (used for automated testing). `--plain`
## skips the showcase content and renders the original baseline scene.
##
## The camera orbits `orbit_target` (auto-rotate plus arcball right-drag
## and wheel zoom; see the "Camera Orbit" export group).

@export_group("Camera Orbit")
## Point the camera orbits around and looks at.
@export var orbit_target := Vector3.ZERO
## Whether the camera orbits automatically over time.
@export var auto_orbit := true:
	set(value):
		auto_orbit = value
		set_process(true)
## Orbit angular speed in degrees per second.
@export_range(-360.0, 360.0, 1.0, "suffix:°/s") var orbit_speed := 20.0
## Distance from the orbit target.
@export_range(1.0, 60.0, 0.1) var orbit_radius := 10.4
## Camera height above/below the target, in degrees (-89..89).
@export_range(-89.0, 89.0, 0.5, "suffix:°") var orbit_elevation := 35.3
## Starting angle around the target, in degrees.
@export_range(-180.0, 180.0, 0.5, "suffix:°") var orbit_start_yaw := 45.0
## Allow arcball orbiting: hold the "arcball_camera" action (right mouse
## button by default) and drag. The cursor is captured while dragging and
## jumps back to where the drag started on release.
@export var mouse_orbit := true
## Radians of orbit per pixel of mouse drag.
@export_range(0.001, 0.05, 0.001) var mouse_sensitivity := 0.01
## Elevation clamp while arcball-dragging, in degrees.
@export_range(-89.0, 89.0, 0.5, "suffix:°") var min_elevation := -89.0
@export_range(-89.0, 89.0, 0.5, "suffix:°") var max_elevation := 89.0
## Allow the mouse wheel to zoom (changes orbit radius).
@export var wheel_zoom := true
## Radius multiplier applied per wheel notch.
@export_range(1.01, 2.0, 0.01) var zoom_step := 1.1
@export_range(0.5, 60.0, 0.1) var min_radius := 3.0
@export_range(1.0, 100.0, 0.1) var max_radius := 40.0

const ARCBALL_ACTION := &"arcball_camera"

var _camera: Camera3D
var _pipeline: PixelArtPipeline3D
var _sun: DirectionalLight3D
var _moving: Node3D
var _spinning: Node3D
var _time := 0.0
var _frames := 0
var _plain := false
var _yaw := 0.0
var _arcball_anchor := Vector2.ZERO


func _ready() -> void:
	_plain = "--plain" in OS.get_cmdline_user_args()
	_yaw = deg_to_rad(orbit_start_yaw)
	_ensure_arcball_action()
	_build_environment()
	_build_camera()
	_build_objects()

	if "--capture" in OS.get_cmdline_user_args():
		# Keep the automated screenshot angle deterministic.
		auto_orbit = false
		print("capture mode: will screenshot after 120 frames")


func _process(delta: float) -> void:
	_time += delta
	_frames += 1
	if auto_orbit:
		_yaw += deg_to_rad(orbit_speed) * delta
	_update_camera_transform()
	if _moving != null:
		# Slow sub-pixel drift: the macro-pixel grid must stay glued to the
		# object (no creep) thanks to PixelArtCameraSnap.
		_moving.position.x = 1.5 + 0.4 * sin(_time * 0.35)
		_moving.position.z = -0.5 + 0.3 * sin(_time * 0.22)
	if _spinning != null:
		_spinning.rotation.y += delta * 0.5
	if "--capture" in OS.get_cmdline_user_args() and _frames == 120:
		_capture()
	#if _frames > 600:
	#	get_tree().quit()


func _exit_tree() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.18, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.45, 0.5)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-48, -30, 0)
	_sun.shadow_enabled = true
	_sun.light_energy = 1.2
	add_child(_sun)


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.current = true
	add_child(_camera)
	_update_camera_transform()

	_pipeline = PixelArtPipeline3D.new()
	_pipeline.camera = _camera
	if not _plain:
		_pipeline.global_palette_lut = load("res://demo/demo_palette_lut.png")
		# Banded cloud shadows + god rays from a generated Perlin noise.
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.frequency = 0.02
		noise.seed = 7
		_pipeline.cloud_noise = ImageTexture.create_from_image(noise.get_image(256, 256))
		_pipeline.cloud_sun = _sun
		_pipeline.clouds_enabled = true
		_pipeline.god_rays_enabled = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--debug-view="):
			_pipeline.debug_view = int(arg.split("=")[1])
	add_child(_pipeline)
	if not _plain:
		# Showcase tuning; the addon defaults are more subtle.
		var ray_pass := _pipeline.get_god_ray_pass()
		if ray_pass != null:
			ray_pass.ray_intensity = 1.2
			ray_pass.ray_dust_strength = 0.3

	var snap := PixelArtCameraSnap.new()
	snap.camera = _camera
	snap.pixel_size = 0.008
	add_child(snap)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if wheel_zoom and button.pressed:
			if button.button_index == MOUSE_BUTTON_WHEEL_UP:
				orbit_radius = clampf(orbit_radius / zoom_step, min_radius, max_radius)
			elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				orbit_radius = clampf(orbit_radius * zoom_step, min_radius, max_radius)
	if not mouse_orbit:
		return
	# Arcball (hold + drag): yaw + elevation, cursor captured while dragging.
	if event.is_action_pressed(ARCBALL_ACTION):
		_arcball_anchor = get_viewport().get_mouse_position()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_released(ARCBALL_ACTION):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		get_viewport().warp_mouse(_arcball_anchor)
	elif Input.is_action_pressed(ARCBALL_ACTION) and event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		orbit_elevation = clampf(
			orbit_elevation + motion.relative.y * mouse_sensitivity * 180.0 / PI,
			min_elevation, max_elevation)


func _ensure_arcball_action() -> void:
	if InputMap.has_action(ARCBALL_ACTION):
		return
	InputMap.add_action(ARCBALL_ACTION)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	InputMap.action_add_event(ARCBALL_ACTION, ev)


func _update_camera_transform() -> void:
	if _camera == null:
		return
	var elev := deg_to_rad(orbit_elevation)
	var offset := Vector3(
		orbit_radius * cos(elev) * cos(_yaw),
		orbit_radius * sin(elev),
		orbit_radius * cos(elev) * sin(_yaw))
	_camera.look_at_from_position(orbit_target + offset, orbit_target, Vector3.UP)


func _ramp_texture() -> Texture2D:
	# 4-step toon ramp.
	var img := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color(0.25, 0.25, 0.25))
	img.set_pixel(1, 0, Color(0.5, 0.5, 0.5))
	img.set_pixel(2, 0, Color(0.8, 0.8, 0.8))
	img.set_pixel(3, 0, Color(1.0, 1.0, 1.0))
	return ImageTexture.create_from_image(img)


func _pixelized(mesh: Mesh, pos: Vector3, color: Color, p_pixel_size: int, outline: Color, id: int, ramp: Texture2D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)

	var obj := PixelArtObject3D.new()
	obj.pixel_size = p_pixel_size
	obj.outline_id = id
	obj.outline_color = outline
	obj.snap_euler_angles = false
	mi.add_child(obj)

	# Per-object look: tint + toon ramp on the created material.
	var mat := mi.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("base_color", color)
		mat.set_shader_parameter("lighting_ramp", ramp)
	return mi


func _build_objects() -> void:
	var ramp := _ramp_texture()

	if _plain:
		# Non-pixelized ground (layer 1 only).
		var ground := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(12, 12)
		ground.mesh = plane
		ground.position = Vector3(0, -0.5, 0)
		var ground_mat := StandardMaterial3D.new()
		ground_mat.albedo_color = Color(0.35, 0.4, 0.35)
		ground.material_override = ground_mat
		add_child(ground)
	else:
		_build_ground_and_pond(ramp)

	# Pixelized primitives: pixel sizes 1, 2, 3, 5.
	_pixelized(BoxMesh.new(), Vector3(-2.2, 0, 0.5), Color(0.9, 0.35, 0.3), 1, Color(0, 0, 0, 1), 11, ramp)
	_pixelized(SphereMesh.new(), Vector3(-0.6, 0, 0.9), Color(0.3, 0.75, 0.4), 2, Color(0, 0, 0, 1), 12, ramp)
	var cyl := _pixelized(CylinderMesh.new(), Vector3(0.9, 0, 1.1), Color(0.35, 0.5, 0.95), 3, Color(0.05, 0.05, 0.2, 1), 13, ramp)
	_spinning = cyl
	_pixelized(BoxMesh.new(), Vector3(2.3, 0, 0.2), Color(0.95, 0.8, 0.3), 5, Color(0, 0, 0, 1), 14, ramp)

	# The drifting object (pixel creep stress test).
	_moving = _pixelized(SphereMesh.new(), Vector3(1.5, 0.2, -0.5), Color(0.85, 0.4, 0.8), 3, Color(0, 0, 0, 1), 15, ramp)
	_moving.scale = Vector3.ONE * 0.7

	if _plain:
		return

	# Sharp-bilinear showcase: rotated box with a mipmapped 8x8 checker.
	var checker_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 8:
			checker_img.set_pixel(x, y, Color(0.95, 0.9, 0.85) if (x + y) % 2 == 0 else Color(0.15, 0.15, 0.2))
	checker_img.generate_mipmaps()
	var checker := ImageTexture.create_from_image(checker_img)
	var tex_box := _pixelized(BoxMesh.new(), Vector3(-1.0, 0, -1.8), Color(1, 1, 1), 2, Color(0, 0, 0, 1), 16, ramp)
	tex_box.rotation_degrees = Vector3(0, 32, 0)
	var tex_mat := tex_box.material_override as ShaderMaterial
	if tex_mat != null:
		tex_mat.set_shader_parameter("albedo_texture", checker)
		tex_mat.set_shader_parameter("use_sharp_bilinear", true)


func _ground_piece(center: Vector3, size: Vector2, ramp: Texture2D) -> void:
	# Pixelized ground (no outline) so cloud shadows show on it.
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	mi.mesh = plane
	mi.position = center
	add_child(mi)

	var obj := PixelArtObject3D.new()
	obj.pixel_size = 2
	obj.outline_id = 10
	obj.outline_color = Color(0, 0, 0, 0)
	mi.add_child(obj)

	var mat := mi.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("base_color", Color(0.35, 0.4, 0.35))
		mat.set_shader_parameter("lighting_ramp", ramp)


func _build_ground_and_pond(ramp: Texture2D) -> void:
	# Ground frame (pixelized) around a 3x3 pond hole at (3.0, -2.5);
	# ground level is y = -0.5, spans x/z in [-6, 6].
	_ground_piece(Vector3(-2.25, -0.5, 0.0), Vector2(7.5, 12), ramp)
	_ground_piece(Vector3(5.25, -0.5, 0.0), Vector2(1.5, 12), ramp)
	_ground_piece(Vector3(3.0, -0.5, 2.5), Vector2(3, 7), ramp)
	_ground_piece(Vector3(3.0, -0.5, -5.0), Vector2(3, 2), ramp)

	# Recessed, non-pixelized basin (clean depth for the fade/foam).
	var basin_mat := StandardMaterial3D.new()
	basin_mat.albedo_color = Color(0.14, 0.28, 0.38)
	var bottom := MeshInstance3D.new()
	var bottom_plane := PlaneMesh.new()
	bottom_plane.size = Vector2(3, 3)
	bottom.mesh = bottom_plane
	bottom.position = Vector3(3.0, -1.6, -2.5)
	bottom.material_override = basin_mat
	add_child(bottom)
	var wall_specs := [
		[Vector3(1.55, -1.05, -2.5), Vector3(0.1, 1.1, 3.0)],
		[Vector3(4.45, -1.05, -2.5), Vector3(0.1, 1.1, 3.0)],
		[Vector3(3.0, -1.05, -1.05), Vector3(3.0, 1.1, 0.1)],
		[Vector3(3.0, -1.05, -3.95), Vector3(3.0, 1.1, 0.1)],
	]
	for spec in wall_specs:
		var wall := MeshInstance3D.new()
		var wall_box := BoxMesh.new()
		wall_box.size = spec[1]
		wall.mesh = wall_box
		wall.position = spec[0]
		wall.material_override = basin_mat
		add_child(wall)

	# Water surface (layers 1-5 from the Pixel Art Oceans note).
	var water_noise_src := FastNoiseLite.new()
	water_noise_src.noise_type = FastNoiseLite.TYPE_PERLIN
	water_noise_src.frequency = 0.08
	water_noise_src.seed = 3
	var water := MeshInstance3D.new()
	var water_plane := PlaneMesh.new()
	water_plane.size = Vector2(3, 3)
	water_plane.subdivide_width = 32
	water_plane.subdivide_depth = 32
	water.mesh = water_plane
	water.position = Vector3(3.0, -0.75, -2.5)
	var water_mat := ShaderMaterial.new()
	water_mat.shader = load("res://demo/water.gdshader")
	water_mat.set_shader_parameter("water_noise",
		ImageTexture.create_from_image(water_noise_src.get_image(128, 128)))
	water.material_override = water_mat
	add_child(water)

	# Foam-interaction stress case: half-submerged pixelized box at the edge.
	var box := _pixelized(BoxMesh.new(), Vector3(2.1, -0.75, -1.7), Color(0.8, 0.5, 0.3), 2, Color(0, 0, 0, 1), 17, ramp)
	box.scale = Vector3.ONE * 0.6


func _capture() -> void:
	print("metadata export frames: ", PixelArtSharedBuffers.metadata_depth_frames)
	var pipeline := get_tree().get_first_node_in_group("pixel_art_pipeline") as PixelArtPipeline3D
	if pipeline != null:
		pipeline.save_shared_textures_debug("res://demo/shared_metadata_color.png", "res://demo/shared_metadata_depth.png")
		var sv := pipeline.get_node_or_null("PixelArtMetadataViewport") as SubViewport
		if sv != null:
			var sv_img := sv.get_texture().get_image()
			print("metadata viewport texture saved: ", sv_img.save_png("res://demo/metadata_viewport.png"))
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png("res://demo/screenshot.png")
	print("screenshot saved: ", err)
	get_tree().quit()
