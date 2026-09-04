#[compute]
#version 450

// ProPixelizer "apply pixelization map" pass (port of SRP/ApplyPixelizationMap.shader).
//
// Samples the original scene color at the snapped anchor UV and writes it to
// the scene color buffer. Occlusion fix: if the original scene depth at this
// pixel is in front of the snapped sample, keep the original color so
// non-pixelized geometry overlapping pixelized objects is not smeared.
//
// Optionally applies palette-LUT color grading (port of SRP/ColorGrading.hlsl)
// to pixelized pixels, dithered per macro-block.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_color_copy;
layout(set = 0, binding = 2) uniform sampler2D anchor_map;
layout(set = 0, binding = 3) uniform sampler2D scene_depth;
layout(set = 0, binding = 4) uniform sampler2D metadata_depth;
layout(set = 0, binding = 5) uniform sampler2D metadata;
layout(set = 0, binding = 6) uniform sampler2D palette_lut;

layout(push_constant, std430) uniform Params {
	vec4 grading; // x: grading enabled (0/1), yzw: unused
	vec4 debug; // x: debug view (0=off, 1=map, 2=metadata, 3=metadata depth)
} params;

const float PIXELMAP_DELTA_MAX = 10.0;
const float MAXCOLOR = 16.0;
const float RES = 16.0;
const float DITHER_SIZE = 16.0;

// PackingUtils.hlsl port: id (0-255) and pixel size (0-5) packed into G as
// (id + pixelSize * 256) / 4096. The white background decodes to size 16,
// which is out of range and means "not pixelized".
float metadata_pixel_size(float g) {
	float ps = floor(round(g * 4096.0) / 256.0);
	return ps <= 5.0 ? ps : 0.0;
}

// UnpackPixelMap: exact integer texel shift.
ivec2 unpack_pixel_map(ivec2 pixel, vec2 packed_shift, ivec2 size) {
	vec2 shift = round((packed_shift - 0.5) * PIXELMAP_DELTA_MAX);
	return clamp(pixel + ivec2(shift), ivec2(0), size - 1);
}

// ColorGrading.hlsl
vec3 color_grade(vec3 color, vec2 macro_pixel) {
	// Grade in gamma space (the LUT stores sRGB colors).
	vec3 orig = pow(clamp(color, vec3(0.0), vec3(64.0)), vec3(1.0 / 2.2));
	orig = clamp(orig, vec3(0.0), vec3(0.9999));

	float u = (clamp(orig.r * RES, 0.0, RES - 1.0) + 0.5) / (RES * RES);
	float v = (clamp(orig.g * RES, 0.0, RES - 1.0) + 0.5) / (RES * DITHER_SIZE);
	float cell = floor(clamp(orig.b * MAXCOLOR, 0.0, RES - 1.0) + 0.5);
	u += cell / RES;

	// Dither band from the macro-pixel grid (Bayer 4x4, x-major).
	float band = (mod(macro_pixel.x, 4.0) * 4.0 + mod(macro_pixel.y, 4.0)) / DITHER_SIZE;
	v += band;

	vec3 graded = textureLod(palette_lut, vec2(u, v), 0.0).rgb;
	// Back to linear; the viewport's own tonemapping/sRGB encode happens later.
	return pow(graded, vec3(2.2));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_image);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec4 packed = texelFetch(anchor_map, pixel, 0);
	ivec2 anchor = unpack_pixel_map(pixel, packed.rg, size);

	if (params.debug.x > 2.5) {
		imageStore(color_image, pixel, vec4(texelFetch(metadata_depth, pixel, 0).rrr, 1.0));
		return;
	} else if (params.debug.x > 1.5) {
		imageStore(color_image, pixel, texelFetch(metadata, pixel, 0));
		return;
	} else if (params.debug.x > 0.5) {
		imageStore(color_image, pixel, vec4(packed.rg, 0.0, 1.0));
		return;
	}

	vec4 color = texelFetch(scene_color_copy, anchor, 0);
	float original_depth = texelFetch(scene_depth, pixel, 0).r;
	float pixelated_depth = texelFetch(metadata_depth, anchor, 0).r;

	// Reversed-Z: larger values are nearer. If the original scene depth is in
	// front of the snapped sample, keep the original (unpixelated) color.
	bool keep_original = (original_depth - pixelated_depth) > 0.0;
	bool pixelized = !keep_original && (anchor != pixel || metadata_pixel_size(texelFetch(metadata, pixel, 0).g) > 0.5);

	if (keep_original) {
		color = texelFetch(scene_color_copy, pixel, 0);
	} else if (params.grading.x > 0.5 && pixelized) {
		float pixel_size = max(1.0, metadata_pixel_size(texelFetch(metadata, anchor, 0).g));
		vec2 macro_pixel = floor(vec2(anchor) / pixel_size);
		color.rgb = color_grade(color.rgb, macro_pixel);
	}

	imageStore(color_image, pixel, color);
}
