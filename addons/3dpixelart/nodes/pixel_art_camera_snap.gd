class_name PixelArtCameraSnap
extends Node
## Snaps the camera's PROJECTION to the world-space texel grid so pixelized
## objects don't creep when the camera moves (orthographic cameras only).
##
## Port of denovodavid's Camera3DTexelSnapped (3d-pixel-art-in-godot): the
## snap error is applied through the camera's h_offset/v_offset projection
## offsets, so the camera transform is never touched and nothing has to be
## restored after rendering.
##
## NOTE: ProPixelizer's original design (and the previous implementation
## here) snapped the camera + object transforms in RenderingServer's
## frame_pre_draw and restored them in frame_post_draw. With a threaded
## rendering server that does NOT work: the root viewport and the metadata
## SubViewport render at different times relative to those signals, so the
## two passes saw different transforms and the anchor grids ended up ~1px
## out of phase (measured: metadata pass rendered the snapped camera, the
## main pass the restored one). Persistent projection offsets are immune to
## that race and are also copied to the metadata camera by
## PixelArtPipeline3D.sync_metadata_camera.
##
## Object snapping (ProPixelizer's render snapables) is intentionally not
## ported for the same reason; the anchor grid already follows the object's
## projected pivot smoothly, so sub-pixel object motion does not creep.

enum PixelSizeMode {
	FIXED_PIXEL_SIZE, ## Camera ortho size follows a fixed world-units-per-pixel.
	FROM_CAMERA_SIZE, ## World-units-per-pixel follows the camera ortho size.
}

@export var camera: Camera3D

@export var mode := PixelSizeMode.FIXED_PIXEL_SIZE

## Size of a screen pixel in world units.
@export var pixel_size := 0.032

var _prev_rotation := Vector3.INF
var _snap_space := Transform3D.IDENTITY
var _warned := false


func _process(_delta: float) -> void:
	if camera == null:
		camera = get_viewport().get_camera_3d()
		if camera == null:
			return
	if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		if not _warned:
			_warned = true
			push_warning("PixelArtCameraSnap: camera snap is designed to prevent pixel creep in orthographic projection; it cannot fix creep in perspective projection.")
		camera.h_offset = 0.0
		camera.v_offset = 0.0
		return
	var viewport_pixel_height := get_viewport().get_visible_rect().size.y
	if viewport_pixel_height <= 0.0:
		return
	if mode == PixelSizeMode.FIXED_PIXEL_SIZE:
		camera.size = viewport_pixel_height * pixel_size
	else:
		pixel_size = camera.size / viewport_pixel_height

	# Rotation changes the snap space (port of Camera3DTexelSnapped).
	if camera.global_rotation != _prev_rotation:
		_prev_rotation = camera.global_rotation
		_snap_space = camera.global_transform

	var snap_space_position := camera.global_position * _snap_space
	var snapped_position := snap_space_position.snapped(Vector3.ONE * pixel_size)
	var snap_error := snapped_position - snap_space_position
	camera.h_offset = snap_error.x
	camera.v_offset = snap_error.y
