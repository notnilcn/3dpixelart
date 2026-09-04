@tool
class_name PixelArtMetadataExportPass
extends CompositorEffect
## Runs inside the metadata SubViewport (PRE_TRANSPARENT) and exports its
## color layer (packed metadata) and depth layer into the shared textures,
## so the main viewport's effects can consume them. Replaces the metadata
## color/depth render targets from ProPixelizer's OutlineDetectionPass.

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY
	rd = RenderingServer.get_rendering_device()
	if rd != null:
		RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# free_rid is thread-safe; freeing the shader frees the pipeline too.
		if sampler.is_valid():
			rd.free_rid(sampler)
		if shader.is_valid():
			rd.free_rid(shader)


func _initialize_compute() -> void:
	var shader_file: RDShaderFile = load("res://addons/3dpixelart/shaders/export_metadata.glsl")
	var spirv := shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(state)


func _render_callback(p_callback_type: int, p_render_data: RenderData) -> void:
	if p_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
		return
	var dest_color := PixelArtSharedBuffers.metadata_color
	var dest_depth := PixelArtSharedBuffers.metadata_depth
	if not dest_color.is_valid() or not dest_depth.is_valid():
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	# Never write outside the destination textures.
	size = size.min(PixelArtSharedBuffers.metadata_depth_size)
	if size.x <= 0 or size.y <= 0:
		return

	var color_layer := buffers.get_color_layer(0)
	var depth_layer := buffers.get_depth_layer(0)
	if not color_layer.is_valid() or not depth_layer.is_valid():
		return

	var u_color_out := RDUniform.new()
	u_color_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color_out.binding = 0
	u_color_out.add_id(dest_color)
	var u_depth_out := RDUniform.new()
	u_depth_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_depth_out.binding = 1
	u_depth_out.add_id(dest_depth)
	var u_color_in := RDUniform.new()
	u_color_in.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_color_in.binding = 2
	u_color_in.add_id(color_layer)
	var u_depth_in := RDUniform.new()
	u_depth_in.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth_in.binding = 3
	u_depth_in.add_id(sampler)
	u_depth_in.add_id(depth_layer)
	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [u_color_out, u_depth_out, u_color_in, u_depth_in])

	var x_groups := (size.x - 1) / 8 + 1
	var y_groups := (size.y - 1) / 8 + 1
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()
	PixelArtSharedBuffers.metadata_depth_frames += 1
