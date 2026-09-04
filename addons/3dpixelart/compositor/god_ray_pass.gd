@tool
class_name PixelArtGodRayPass
extends CompositorEffect
## God rays through the banded cloud layer (Pixel Perfect "Volumetric
## Lighting" pattern). Runs POST_SKY and writes additively into the scene
## color layer. The pipeline inserts this pass *before* the macro-pixel
## pass so the rays get anchor-replicated into macro-pixels like the rest
## of the scene.
##
## The cloud parameters mirror the pipeline's Clouds export group and are
## pushed by PixelArtPipeline3D; [member rays_enabled] is set separately so
## cloud shadows can be on without rays.

## Master toggle; the pass early-outs when disabled.
@export var rays_enabled := false
@export var ray_steps := 16
@export var ray_max_distance := 40.0
@export var ray_intensity := 0.45
## Exponential decay of the accumulation along the march.
@export var ray_decay := 2.0
## Quantize the ray intensity to this many bands (<= 1 disables). Crisp
## bands match the cloud-shadow banding.
@export var ray_quantize_bands := 4.0
## How strongly a second, slower high-threshold noise modulates the shafts.
@export_range(0.0, 1.0) var ray_dust_strength := 0.5

# Pushed by PixelArtPipeline3D (mirrors of its Clouds export group).
var cloud_noise: Texture2D:
	set(value):
		cloud_noise = value
		_noise_dirty = true
var cloud_sun_dir := Vector3(0.0, -1.0, 0.0)
var cloud_height := 10.0
var cloud_noise_scale := 0.05
var cloud_threshold := 0.5
var cloud_bands := 3.0
var cloud_wind := Vector2(0.02, 0.0)

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var depth_sampler: RID
var noise_sampler: RID
var params_buffer: RID

var _noise_dirty := false
var _noise_rd: RID
var _warned_no_noise := false

const PARAMS_SIZE := 160 # 10 vec4s: mat4 + 6 vec4


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY
	rd = RenderingServer.get_rendering_device()
	if rd != null:
		RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if params_buffer.is_valid():
			rd.free_rid(params_buffer)
		if depth_sampler.is_valid():
			rd.free_rid(depth_sampler)
		if noise_sampler.is_valid():
			rd.free_rid(noise_sampler)
		if shader.is_valid():
			rd.free_rid(shader)


func _initialize_compute() -> void:
	var shader_file: RDShaderFile = load("res://addons/3dpixelart/shaders/god_rays.glsl")
	shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	pipeline = rd.compute_pipeline_create(shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	depth_sampler = rd.sampler_create(state)
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	noise_sampler = rd.sampler_create(state)
	params_buffer = rd.uniform_buffer_create(PARAMS_SIZE)


func _make_sampler_uniform(p_binding: int, p_sampler: RID, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = p_binding
	uniform.add_id(p_sampler)
	uniform.add_id(texture)
	return uniform


func _render_callback(p_callback_type: int, p_render_data: RenderData) -> void:
	if p_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
		return
	if not rays_enabled:
		return
	if cloud_noise == null:
		if not _warned_no_noise:
			_warned_no_noise = true
			push_warning("PixelArtGodRayPass: rays_enabled but no cloud_noise assigned; pass is inert.")
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := p_render_data.get_render_scene_data()
	if buffers == null or scene_data == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	if _noise_dirty:
		_noise_dirty = false
		_noise_rd = RenderingServer.texture_get_rd_texture(cloud_noise.get_rid(), false)
	if not _noise_rd.is_valid():
		return

	# Fill the per-frame uniform buffer (10 vec4s, matches the GLSL Params block).
	var cam_xform := scene_data.get_cam_transform()
	var inv_vp: Projection = (scene_data.get_cam_projection() * Projection(cam_xform.affine_inverse())).inverse()
	var values := PackedFloat32Array()
	values.resize(40)
	var cols := [inv_vp.x, inv_vp.y, inv_vp.z, inv_vp.w]
	for c in 4:
		values[c * 4 + 0] = cols[c].x
		values[c * 4 + 1] = cols[c].y
		values[c * 4 + 2] = cols[c].z
		values[c * 4 + 3] = cols[c].w
	var i := 16
	values[i] = cam_xform.origin.x; values[i + 1] = cam_xform.origin.y; values[i + 2] = cam_xform.origin.z; i += 4
	values[i] = cloud_sun_dir.x; values[i + 1] = cloud_sun_dir.y; values[i + 2] = cloud_sun_dir.z; i += 4
	values[i] = cloud_noise_scale; values[i + 1] = cloud_threshold; values[i + 2] = cloud_bands; values[i + 3] = cloud_height; i += 4
	values[i] = cloud_wind.x; values[i + 1] = cloud_wind.y; values[i + 2] = Time.get_ticks_msec() / 1000.0; i += 4
	values[i] = ray_max_distance; values[i + 1] = ray_intensity; values[i + 2] = ray_decay; values[i + 3] = ray_quantize_bands; i += 4
	values[i] = ray_dust_strength; values[i + 1] = float(ray_steps)
	rd.buffer_update(params_buffer, 0, PARAMS_SIZE, values.to_byte_array())

	var x_groups := (size.x - 1) / 8 + 1
	var y_groups := (size.y - 1) / 8 + 1

	for view in buffers.get_view_count():
		var color_layer := buffers.get_color_layer(view)
		var depth_layer := buffers.get_depth_layer(view)
		if not color_layer.is_valid() or not depth_layer.is_valid():
			continue

		var u_color := RDUniform.new()
		u_color.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u_color.binding = 0
		u_color.add_id(color_layer)
		var u_params := RDUniform.new()
		u_params.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		u_params.binding = 3
		u_params.add_id(params_buffer)
		var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [
			u_color,
			_make_sampler_uniform(1, depth_sampler, depth_layer),
			_make_sampler_uniform(2, noise_sampler, _noise_rd),
			u_params,
		])
		if not uniform_set.is_valid():
			continue

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()
