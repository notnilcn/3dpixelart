#[compute]
#version 450

// ProPixelizer pixelization map pass (port of SRP/PixelizationMap.shader).
//
// For every screen pixel, search a 5x5 texel neighbourhood for "anchor"
// pixels of macro-blocks that claim this pixel, keep the nearest claimant
// (by raw depth - Godot uses reversed-Z, so larger depth == nearer), and
// store the winning anchor's UV shift packed into an RGBA8 map.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform writeonly image2D anchor_map;
layout(set = 0, binding = 1) uniform sampler2D metadata; // ProPixelizer metadata buffer
layout(set = 0, binding = 2) uniform sampler2D metadata_depth; // R32F raw depth of pixelized objects

const float PIXELMAP_DELTA_MAX = 10.0;

// PackingUtils.hlsl port: id (0-255) and pixel size (0-5) packed into G as
// (id + pixelSize * 256) / 4096. The white background decodes to size 16,
// which is out of range and means "not pixelized".
float metadata_pixel_size(float g) {
	float ps = floor(round(g * 4096.0) / 256.0);
	return ps <= 5.0 ? ps : 0.0;
}

// Clamp a texel coordinate into the image bounds (mimics clamp-to-edge sampling).
ivec2 clamp_texel(ivec2 t, ivec2 size) {
	return clamp(t, ivec2(0), size - 1);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(anchor_map);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	// Godot renders with reversed depth: 1.0 == near plane, 0.0 == far plane.
	// "Nearest" claimant therefore has the LARGEST raw depth value.
	float nearest_depth = 0.0;
	ivec2 nearest_texel = pixel;

	for (int u = -2; u <= 2; u++) {
		for (int v = -2; v <= 2; v++) {
			ivec2 offset = ivec2(u, v);
			ivec2 t = clamp_texel(pixel + offset, size);
			vec4 neighbour = texelFetch(metadata, t, 0);
			float pixel_size = metadata_pixel_size(neighbour.g);
			float pos = floor(pixel_size / 1.99);
			float neg = -floor((pixel_size - 1.0) / 1.99);
			bool pixelate = pixel_size > 0.5
				&& float(u) >= neg && float(v) >= neg
				&& float(u) <= pos && float(v) <= pos;
			float depth = texelFetch(metadata_depth, t, 0).r;
			bool nearer = depth > nearest_depth;
			if (nearer && pixelate) {
				nearest_depth = depth;
				nearest_texel = t;
			}
		}
	}

	// PackPixelMap: integer texel shift in [-5, +5] packed around 0.5.
	vec2 delta = vec2(nearest_texel - pixel);
	vec2 shifts = delta / PIXELMAP_DELTA_MAX + 0.5;
	imageStore(anchor_map, pixel, vec4(shifts, 0.0, 0.0));
}
