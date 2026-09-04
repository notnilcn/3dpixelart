class_name PixelArtObject3D
extends Node3D
## Per-object configuration for pixelization, outlines and render snapping.
## Port of ProPixelizer's ObjectRenderSnapable + OutlineControl.
##
## Note: object render snapping (cache/restore transform around rendering) is
## currently not driven — see PixelArtCameraSnap's docstring for why
## (snap/restore around rendering is racy with a threaded rendering server).
##
## Add as a child of a MeshInstance3D (or set [member target] explicitly).
## The target's render layers get the metadata layer added automatically, and
## the pixel-art material is assigned if it doesn't have one already.

enum RotationSnapMode {
	WORLD_ROTATION, ## Snap world-space euler angles.
	CAMERA_YAW, ## Snap yaw relative to the camera (8-direction-sprite feel).
}

const SHADER_PATH := "res://addons/3dpixelart/shaders/pixel_art_object.gdshader"

## The object to pixelize. Defaults to the parent if it is a
## GeometryInstance3D, otherwise the first GeometryInstance3D child.
@export var target: GeometryInstance3D:
	set(value):
		target = value
		if is_inside_tree():
			_configure_target()

@export_group("Pixelization")
## Macro-pixel size in screen pixels (1-5).
@export_range(1, 5) var pixel_size := 3:
	set(value):
		pixel_size = value
		_apply_instance_parameters()
## Anchor the pixel grid to the object's pivot (recommended) instead of
## [member pixel_grid_origin].
@export var use_object_position := true:
	set(value):
		use_object_position = value
		_apply_instance_parameters()
## World-space pixel grid origin, used when [member use_object_position] is off.
@export var pixel_grid_origin := Vector3.ZERO:
	set(value):
		pixel_grid_origin = value
		_apply_instance_parameters()

@export_group("Outline")
## ID used to differentiate objects for outlines (0-254). Adjacent pixels
## with different IDs produce an outline.
@export_range(0, 254) var outline_id := 1:
	set(value):
		outline_id = value
		_apply_instance_parameters()
## Randomly generate an outline ID at runtime.
@export var use_random_uid := false
## Use the outline ID of the topmost PixelArtObject3D ancestor, so a whole
## hierarchy shares one outline (no internal outlines).
@export var use_root_uid := false:
	set(value):
		use_root_uid = value
		_apply_root_inheritance()
## Outline color. Alpha is the outline opacity.
@export var outline_color := Color(0.0, 0.0, 0.0, 1.0):
	set(value):
		outline_color = value
		_apply_instance_parameters()
## Copy the outline color of the topmost PixelArtObject3D ancestor.
@export var use_root_color := false:
	set(value):
		use_root_color = value
		_apply_root_inheritance()
## Crease edge highlight: values below 0.5 darken, above 0.5 lighten,
## exactly 0.5 disables edge highlighting.
@export var edge_highlight_color := Color(0.5, 0.5, 0.5, 1.0):
	set(value):
		edge_highlight_color = value
		_apply_instance_parameters()

@export_group("Snapping")
## Snap position to pixel centers (orthographic cameras, no pixel creep).
@export var snap_position := true
## Snap euler rotation angles to [member angle_resolution] steps.
@export var snap_euler_angles := true
## Resolution (degrees) to which euler angles are snapped.
@export var angle_resolution := 30.0
## Strategy used for snapping rotation angles.
@export var rotation_snap_mode := RotationSnapMode.WORLD_ROTATION
## Snap this object's pixels into alignment with a reference transform, in
## units of its own pixel size.
@export var align_pixel_grid := false
## Reference transform for [member align_pixel_grid]. If empty, the topmost
## Node3D ancestor is used.
@export var pixel_grid_reference: Node3D

const SNAP_BIAS := 0.5

var transform_depth := 0

var _local_position_pre_snap := Vector3.ZERO
var _local_rotation_pre_snap := Quaternion.IDENTITY
var _world_position_pre_snap := Vector3.ZERO
var _world_rotation_pre_snap := Quaternion.IDENTITY
var _pixel_grid_reference_position := Vector3.ZERO

var _configured_material: Material


func _enter_tree() -> void:
	add_to_group("pixel_art_object")


func _ready() -> void:
	transform_depth = 0
	var iter := get_parent()
	while iter != null and transform_depth < 100:
		transform_depth += 1
		iter = iter.get_parent()

	if use_random_uid:
		outline_id = randi() % 255
	_apply_root_inheritance()

	if target == null:
		var parent := get_parent()
		if parent is GeometryInstance3D:
			target = parent
		else:
			for child in get_children():
				if child is GeometryInstance3D:
					target = child
					break
	if target == null:
		push_warning("PixelArtObject3D '%s': no GeometryInstance3D target found; set 'target' manually." % name)
		return
	_configure_target()


func _exit_tree() -> void:
	var pipeline := _get_pipeline()
	if pipeline != null and _configured_material != null:
		pipeline.unregister_material(_configured_material)
	_configured_material = null


func _get_pipeline() -> PixelArtPipeline3D:
	var node := get_tree().get_first_node_in_group("pixel_art_pipeline")
	return node as PixelArtPipeline3D


func _configure_target() -> void:
	if target == null or not is_inside_tree():
		return

	var pipeline := _get_pipeline()
	var metadata_mask: int = pipeline._metadata_mask if pipeline != null else (1 << 19)

	# Pixelized objects must be visible to the metadata camera.
	if (target.layers & metadata_mask) == 0:
		target.layers |= metadata_mask
		print("PixelArtObject3D '%s': added metadata render layer (mask 0x%X) to target '%s'." % [name, metadata_mask, target.name])

	# Assign the pixel-art material when the target doesn't have one.
	var shader: Shader = load(SHADER_PATH)
	var active: Material = target.get_active_material(0)
	var material: ShaderMaterial = null
	if active is ShaderMaterial and active.shader == shader:
		material = active
	elif target.material_override is ShaderMaterial and target.material_override.shader == shader:
		material = target.material_override
	else:
		material = ShaderMaterial.new()
		material.shader = shader
		target.material_override = material

	if _configured_material != null and _configured_material != material and pipeline != null:
		pipeline.unregister_material(_configured_material)
	_configured_material = material
	if pipeline != null:
		pipeline.register_material(material)

	_apply_instance_parameters()


func _apply_instance_parameters() -> void:
	if target == null or not is_inside_tree():
		return
	target.set_instance_shader_parameter("pixel_size", float(pixel_size))
	target.set_instance_shader_parameter("outline_id", float(outline_id))
	target.set_instance_shader_parameter("outline_color", outline_color)
	target.set_instance_shader_parameter("edge_highlight_color", edge_highlight_color)
	target.set_instance_shader_parameter("use_object_position", use_object_position)
	target.set_instance_shader_parameter("pixel_grid_origin", pixel_grid_origin)


func _apply_root_inheritance() -> void:
	if not is_inside_tree():
		return
	if not use_root_uid and not use_root_color:
		return
	var root := _get_root_pixel_art_object()
	if root == null or root == self:
		if use_root_uid or use_root_color:
			push_warning("PixelArtObject3D '%s': root outline ID/color requested, but no PixelArtObject3D ancestor exists." % name)
		return
	if use_root_uid:
		outline_id = root.outline_id
	if use_root_color:
		outline_color = root.outline_color
	_apply_instance_parameters()


func _get_root_pixel_art_object() -> PixelArtObject3D:
	var root: PixelArtObject3D = null
	var iter := get_parent()
	while iter != null:
		if iter is PixelArtObject3D:
			root = iter
		iter = iter.get_parent()
	return root


# -----------------------------------------------------------------------------
# Snap support (driven by PixelArtCameraSnap)
# -----------------------------------------------------------------------------

func cache_transform() -> void:
	_local_position_pre_snap = position
	_local_rotation_pre_snap = quaternion
	_world_position_pre_snap = global_position
	_world_rotation_pre_snap = global_transform.basis.get_rotation_quaternion()
	if pixel_grid_reference != null:
		_pixel_grid_reference_position = pixel_grid_reference.global_position
	else:
		var root: Node = self
		while root.get_parent() is Node3D:
			root = root.get_parent()
		_pixel_grid_reference_position = (root as Node3D).global_position


func restore_cached_transform() -> void:
	position = _local_position_pre_snap
	quaternion = _local_rotation_pre_snap


func get_cached_world_position() -> Vector3:
	return _world_position_pre_snap


func get_pixel_grid_reference_position() -> Vector3:
	return _pixel_grid_reference_position


## Snap euler angles to angle_resolution steps (called before position snap).
func snap_rotation_angles(camera: Camera3D) -> void:
	if not snap_euler_angles:
		return
	var angles := _world_rotation_pre_snap.get_euler()
	var resolution := deg_to_rad(angle_resolution)
	if resolution <= 0.0:
		return
	match rotation_snap_mode:
		RotationSnapMode.WORLD_ROTATION:
			angles = Vector3(
				roundf(angles.x / resolution) * resolution,
				roundf(angles.y / resolution) * resolution,
				roundf(angles.z / resolution) * resolution)
		RotationSnapMode.CAMERA_YAW:
			var camera_y := camera.global_transform.basis.get_euler().y
			angles.y -= camera_y
			angles = Vector3(
				roundf(angles.x / resolution) * resolution,
				roundf(angles.y / resolution) * resolution,
				roundf(angles.z / resolution) * resolution)
			angles.y += camera_y
	var t := global_transform
	var scale := t.basis.get_scale()
	t.basis = Basis.from_euler(angles).scaled(scale)
	global_transform = t
