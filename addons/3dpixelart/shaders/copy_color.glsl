#[compute]
#version 450

// Copies one RGBA16F image into another (image -> image).
//
// Used to snapshot the scene color before the pixelization apply pass: the
// engine's color layer cannot be bound as a texture_copy source, so the
// copy is done as a compute dispatch instead.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform writeonly image2D color_out;
layout(rgba16f, set = 0, binding = 1) uniform readonly image2D color_in;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_out);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	imageStore(color_out, pixel, imageLoad(color_in, pixel));
}
