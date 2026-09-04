#[compute]
#version 450

// God rays through a banded cloud layer (Pixel Perfect "Volumetric Lighting"
// pattern): for each pixel, march from the camera toward the reconstructed
// world position and accumulate the gaps in the cloud coverage along the
// ray, projected onto the cloud plane. Runs before the macro-pixel pass so
// the rays get pixelated with the rest of the scene.
//
// Endpoint-lerp optimization: the camera and the surface point are projected
// onto the cloud plane once, then each step lerps between the two plane UVs
// — no per-step plane intersections.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_layer;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D cloud_noise;

layout(set = 0, binding = 3) uniform Params {
	mat4 inv_view_proj;
	vec4 camera_pos;      // xyz = world camera position
	vec4 sun_dir;         // xyz = world direction the light travels (downward)
	vec4 cloud_params;    // x = noise scale, y = threshold, z = bands, w = plane height
	vec4 cloud_wind_time; // xy = wind dir*speed, z = time
	vec4 ray_params;      // x = max distance, y = intensity, z = decay, w = quantize bands
	vec4 ray_params2;     // x = dust strength, y = steps
};

vec2 cloud_project(vec3 p) {
	// sun_dir.y < 0 (light travels down), so t is negative and p + sun_dir * t
	// walks toward the sun up to the cloud plane.
	float t = (cloud_params.w - p.y) / min(sun_dir.y, -0.02);
	return (p + sun_dir.xyz * t).xz;
}

float cloud_gap(vec2 plane_uv) {
	float n = textureLod(cloud_noise, plane_uv * cloud_params.x + cloud_wind_time.xy * cloud_wind_time.z, 0.0).r;
	float bands = max(cloud_params.z, 2.0);
	float banded = floor(n * bands) / (bands - 1.0);
	return 1.0 - step(cloud_params.y, banded);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(color_layer);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
	float depth = textureLod(scene_depth, uv, 0.0).r;

	// Reversed-Z reconstruction (near = 1, far = 0); the inverse matrix
	// handles the Z mapping, sky reconstructs at the far plane.
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world4 = inv_view_proj * ndc;
	vec3 world = world4.xyz / world4.w;

	vec3 origin = camera_pos.xyz;
	vec3 ray = world - origin;
	float ray_len = length(ray);
	vec3 ray_dir = ray / max(ray_len, 1e-5);
	float march_len = min(ray_len, ray_params.x);

	int steps = int(ray_params2.y);
	vec2 uv0 = cloud_project(origin);
	vec2 uv1 = cloud_project(origin + ray_dir * march_len);

	float dust = 1.0;
	if (ray_params2.x > 0.0) {
		// Slow, high-threshold noise modulates the whole shaft (dustiness).
		float d = textureLod(cloud_noise, uv1 * cloud_params.x * 0.35 + cloud_wind_time.xy * cloud_wind_time.z * 0.3, 0.0).r;
		dust = mix(1.0, smoothstep(0.55, 0.9, d), ray_params2.x);
	}

	float accum = 0.0;
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + 0.5) / float(steps);
		float gap = cloud_gap(mix(uv0, uv1, t));
		accum += gap * exp(-ray_params.z * t);
	}
	accum /= float(steps);

	float bands_q = ray_params.w;
	if (bands_q > 1.0) {
		accum = floor(accum * bands_q + 0.5) / bands_q;
	}

	vec3 ray_color = vec3(1.0, 0.96, 0.85) * ray_params.y * accum * dust;
	imageStore(color_layer, pixel, imageLoad(color_layer, pixel) + vec4(ray_color, 0.0));
}
