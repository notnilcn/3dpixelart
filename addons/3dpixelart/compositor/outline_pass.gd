@tool
class_name PixelArtOutlinePass
extends CompositorEffect
## Fullscreen outline detection over the metadata buffer
## (port of SRP/OutlineDetection.shader). Runs PRE_OPAQUE on the main
## viewport so the outline texture is ready when opaque objects draw.

## Suppresses outlines where objects intersect.
@export var depth_test_intersections := true
## Depth compare threshold for the intersection test.
@export var depth_test_threshold := 0.0001
## Detect creases from view-space normals stored in the metadata buffer.
## Materials must have write_view_normals enabled (the default).
@export var use_normal_edge_detection := true
## Higher values make crease detection less sensitive.
@export var normal_edge_detection_sensitivity := 3.5

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var sampler: RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	rd = RenderingServer.get_rendering_device()
	if rd != null:
		RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if sampler.is_valid():
			rd.free_rid(sampler)
		if shader.is_valid():
			rd.free_rid(shader)


func _initialize_compute() -> void:
	var shader_file: RDShaderFile = load("res://addons/3dpixelart/shaders/outline_pass.glsl")
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
	if p_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
		return
	var outlines := PixelArtSharedBuffers.outlines
	var metadata := PixelArtSharedBuffers.metadata_color
	if not outlines.is_valid() or not metadata.is_valid():
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var depth := PixelArtSharedBuffers.metadata_depth
	if not PixelArtSharedBuffers.use_exported_depth or not depth.is_valid():
		# Scene-depth fallback: the main viewport's depth is bound instead.
		depth = buffers.get_depth_layer(0)
		if not depth.is_valid():
			return

	var u_metadata := RDUniform.new()
	u_metadata.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_metadata.binding = 1
	u_metadata.add_id(sampler)
	u_metadata.add_id(metadata)
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 2
	u_depth.add_id(sampler)
	u_depth.add_id(depth)
	var u_outlines := RDUniform.new()
	u_outlines.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_outlines.binding = 0
	u_outlines.add_id(outlines)
	var uniform_set := UniformSetCacheRD.get_cache(shader, 0, [u_outlines, u_metadata, u_depth])

	var push_constants := PackedFloat32Array([
		depth_test_threshold,
		1.0 / maxf(normal_edge_detection_sensitivity, 0.001),
		1.0 if depth_test_intersections else 0.0,
		1.0 if use_normal_edge_detection else 0.0,
	])

	var size := PixelArtSharedBuffers.outlines_size
	var x_groups := (size.x - 1) / 8 + 1
	var y_groups := (size.y - 1) / 8 + 1
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
	rd.compute_list_end()
