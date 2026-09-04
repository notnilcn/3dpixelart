class_name PixelArtSharedBuffers
extends Object
## Shared state between PixelArtPipeline3D (main thread) and the compositor
## effects (render thread). RIDs written here are never freed mid-frame
## (RenderingDevice.free_rid defers freeing until the frame is done), so the
## worst case on resize is one frame rendered with the previous size.
##
## Only one PixelArtPipeline3D should be active per scene.

## RD texture: exported color of the metadata SubViewport (RGBA16; G packs
## the outline id and pixel size, R/B hold view normals or outline nibbles).
static var metadata_color: RID

## RD texture: exported depth of the metadata SubViewport (R32F).
static var metadata_depth: RID

## When false, consumers bind the scene depth instead of the exported
## metadata depth (fallback mode; the export still runs).
static var use_exported_depth := true

## Size of [member metadata_depth] (and of the metadata viewport).
static var metadata_depth_size: Vector2i

## Incremented by the metadata depth export effect each time it runs;
## used by PixelArtPipeline3D to detect unsupported SubViewport compositors.
static var metadata_depth_frames := 0

## RD texture: outline factor buffer (RGBA8), written by the outline
## detection effect and sampled by pixelized materials.
static var outlines: RID

static var outlines_size: Vector2i


static func reset() -> void:
	metadata_color = RID()
	metadata_depth = RID()
	metadata_depth_size = Vector2i()
	metadata_depth_frames = 0
	use_exported_depth = true
	outlines = RID()
	outlines_size = Vector2i()
