#[compute]
#version 450

// Exports the metadata viewport's color and depth into shared textures.
//
// Runs inside the metadata SubViewport's compositor. The color layer holds
// the exact packed metadata values (linear, pre-tonemap), and the depth
// layer gives the pixelized-objects-only depth. The color export is RGBA16
// because the G channel packs id (8 bits) + pixel size (3 bits).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16, set = 0, binding = 0) uniform writeonly image2D color_out;
layout(r32f, set = 0, binding = 1) uniform writeonly image2D depth_out;
layout(rgba16f, set = 0, binding = 2) uniform readonly image2D color_in;
layout(set = 0, binding = 3) uniform sampler2D depth_in;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_out);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	imageStore(color_out, pixel, imageLoad(color_in, pixel));
	imageStore(depth_out, pixel, vec4(texelFetch(depth_in, pixel, 0).r, 0.0, 0.0, 0.0));
}
