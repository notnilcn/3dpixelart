@tool
class_name PixelDitherPattern
extends Resource
## A 4x4 ordered dither threshold matrix, stored as 16 floats in [0, 1].
##
## Port of ProPixelizer's Tools/DitherPattern.cs.
## Indexing is x-major: order = 4 * (x % 4) + (y % 4).
## Used when baking palette LUTs (see PixelPalette) and by the runtime
## transparency dither. The classic preset is the Bayer 4x4 matrix.

const SIZE := 4

## 16 threshold values, x-major: values[x * 4 + y].
@export var values: PackedFloat32Array = PackedFloat32Array([
	0.0 / 17.0, 8.0 / 17.0, 2.0 / 17.0, 10.0 / 17.0,
	12.0 / 17.0, 4.0 / 17.0, 14.0 / 17.0, 6.0 / 17.0,
	3.0 / 17.0, 11.0 / 17.0, 1.0 / 17.0, 9.0 / 17.0,
	15.0 / 17.0, 7.0 / 17.0, 13.0 / 17.0, 5.0 / 17.0,
]):
	set(v):
		values = v
		if values.size() != 16:
			push_warning("PixelDitherPattern expects exactly 16 values (4x4).")
		emit_changed()


func dither_index(off_x: int, off_y: int) -> int:
	return 4 * (off_x % 4) + (off_y % 4)


## Returns true if color A should be picked for the given mix fraction at
## the given pattern index, i.e. threshold > fraction.
func use_color_a(fraction: float, index: int) -> bool:
	if values.size() != 16:
		return true
	return values[clampi(index, 0, 15)] > fraction


## The classic Bayer 4x4 ordered dither pattern (values n/17).
static func bayer_4x4() -> PixelDitherPattern:
	return PixelDitherPattern.new()
