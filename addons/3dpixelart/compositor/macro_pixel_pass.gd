@tool
class_name PixelArtMacroPixelPass
extends CompositorEffect
## The pixelization blit chain (port of SRP/ProPixelizerPixelizationPass.cs).
## Runs PRE_TRANSPARENT: copies the scene color, builds the anchor map
## from the metadata buffer, then applies it so every macro-block shows its
## anchor pixel's color.
##
## Note: unlike the Unity original, pixelated depth is not written back into
## the main depth buffer, so transparent objects composite against the
## un-pixelated depth.

## Optional palette LUT (baked by PixelPalette) applied to pixelized pixels
## after lighting - the faithful ProPixelizer grading look. One LUT for the
## whole frame; use TONE_MAPPER_LINEAR in your environment for exact colors.
@export var global_palette_lut: Texture2D:
	set(value):
		global_palette_lut = value
		_lut_dirty = true

## Debug view for development: 0 = off, 1 = anchor map,
## 2 = metadata buffer, 3 = metadata depth.
@export var debug_view := 0

var rd: RenderingDevice
var copy_shader: RID
var copy_pipeline: RID
var map_shader: RID
var map_pipeline: RID
var apply_shader: RID
var apply_pipeline: RID
var sampler: RID

var _lut_dirty := false
var _lut_rd: RID
var _warned_invalid_set := false
var _printed_apply := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY
	rd = RenderingServer.get_rendering_device()
	if rd != null:
		RenderingServer.call_on_render_thread(_initialize_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if sampler.is_valid():
			rd.free_rid(sampler)
		if copy_shader.is_valid():
			rd.free_rid(copy_shader)
		if map_shader.is_valid():
			rd.free_rid(map_shader)
		if apply_shader.is_valid():
			rd.free_rid(apply_shader)


func _initialize_compute() -> void:
	var copy_file: RDShaderFile = load("res://addons/3dpixelart/shaders/copy_color.glsl")
	copy_shader = rd.shader_create_from_spirv(copy_file.get_spirv())
	copy_pipeline = rd.compute_pipeline_create(copy_shader)
	var map_file: RDShaderFile = load("res://addons/3dpixelart/shaders/anchor_map.glsl")
	map_shader = rd.shader_create_from_spirv(map_file.get_spirv())
	map_pipeline = rd.compute_pipeline_create(map_shader)
	var apply_file: RDShaderFile = load("res://addons/3dpixelart/shaders/apply_anchor_map.glsl")
	apply_shader = rd.shader_create_from_spirv(apply_file.get_spirv())
	apply_pipeline = rd.compute_pipeline_create(apply_shader)
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler = rd.sampler_create(state)


func _make_sampler_uniform(p_binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = p_binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


func _make_image_uniform(p_binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = p_binding
	uniform.add_id(texture)
	return uniform


func _render_callback(p_callback_type: int, p_render_data: RenderData) -> void:
	if p_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
		return
	var metadata := PixelArtSharedBuffers.metadata_color
	if not metadata.is_valid():
		return
	var buffers := p_render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return

	# Resolve the LUT on the render thread when it changed.
	if _lut_dirty:
		_lut_dirty = false
		_lut_rd = RID()
		if global_palette_lut != null:
			_lut_rd = RenderingServer.texture_get_rd_texture(global_palette_lut.get_rid(), false)

	var usage: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT \
		| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT

	var x_groups := (size.x - 1) / 8 + 1
	var y_groups := (size.y - 1) / 8 + 1

	for view in buffers.get_view_count():
		var color_layer := buffers.get_color_layer(view)
		var depth_layer := buffers.get_depth_layer(view)
		if not color_layer.is_valid() or not depth_layer.is_valid():
			continue

		var suffix := "_v%d" % view
		var scene_color_copy := buffers.create_texture("pixel_art", "scene_color_copy" + suffix,
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, false, true)
		var anchor_map := buffers.create_texture("pixel_art", "anchor_map" + suffix,
			RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, usage,
			RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, false, true)

		# Metadata-only depth, or the scene depth as fallback.
		var metadata_depth := PixelArtSharedBuffers.metadata_depth
		if not PixelArtSharedBuffers.use_exported_depth or not metadata_depth.is_valid():
			metadata_depth = depth_layer

		# 1. Copy scene color so the apply pass has an unmodified source.
		var copy_set := UniformSetCacheRD.get_cache(copy_shader, 0, [
			_make_image_uniform(0, scene_color_copy),
			_make_image_uniform(1, color_layer),
		])
		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, copy_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, copy_set, 0)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

		# 2. Anchor map: 5x5 nearest-anchor search over the metadata.
		var map_set := UniformSetCacheRD.get_cache(map_shader, 0, [
			_make_image_uniform(0, anchor_map),
			_make_sampler_uniform(1, metadata),
			_make_sampler_uniform(2, metadata_depth),
		])
		compute_list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, map_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, map_set, 0)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

		# 3. Apply the map: replicate anchor colors, keep occluders intact.
		var lut := _lut_rd if _lut_rd.is_valid() else scene_color_copy
		var apply_set := UniformSetCacheRD.get_cache(apply_shader, 0, [
			_make_image_uniform(0, color_layer),
			_make_sampler_uniform(1, scene_color_copy),
			_make_sampler_uniform(2, anchor_map),
			_make_sampler_uniform(3, depth_layer),
			_make_sampler_uniform(4, metadata_depth),
			_make_sampler_uniform(5, metadata),
			_make_sampler_uniform(6, lut),
		])
		if not apply_set.is_valid():
			if not _warned_invalid_set:
				_warned_invalid_set = true
				print("PixelArtMacroPixelPass: apply uniform set INVALID (metadata_color valid: %s)" % metadata.is_valid())
		elif not _printed_apply:
			_printed_apply = true
			print("PixelArtMacroPixelPass: apply dispatching OK")
		if apply_set.is_valid():
			var push_constants := PackedFloat32Array([
				1.0 if _lut_rd.is_valid() else 0.0, 0.0, 0.0, 0.0,
				float(debug_view), 0.0, 0.0, 0.0,
			])
			compute_list = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(compute_list, apply_pipeline)
			rd.compute_list_bind_uniform_set(compute_list, apply_set, 0)
			rd.compute_list_set_push_constant(compute_list, push_constants.to_byte_array(), push_constants.size() * 4)
			rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
			rd.compute_list_end()
