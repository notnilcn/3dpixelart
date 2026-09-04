shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

// Pixel Perfect "Pixel Art Oceans" water, layers 1-5: quantized depth fade,
// refraction, A x B vertex waves, shoreline foam and whitecaps, banded for
// the pixel-art look. Layer 6 (planar reflections) is intentionally skipped
// (most expensive, optional per the video).
//
// Limitations (demo/example shader, not part of the pixel-art pipeline):
// transparent objects render AFTER the POST_SKY pixelization passes, so the
// water itself is not macro-pixelated and writes no metadata (no outlines),
// and pixelized objects only write depth at anchor fragments, so the depth
// fade and foam read dotty right against them.

uniform vec4 shallow_color : source_color = vec4(0.35, 0.75, 0.80, 1.0);
uniform vec4 deep_color : source_color = vec4(0.08, 0.25, 0.45, 1.0);
uniform vec4 foam_color : source_color = vec4(0.90, 0.97, 1.0, 1.0);
uniform sampler2D water_noise : filter_nearest, repeat_enable;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_nearest;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_nearest;

uniform float depth_fade_distance = 0.8;
uniform float color_bands = 4.0; // quantize the depth fade (pixel look)
uniform float water_tint : hint_range(0.0, 1.0) = 0.75;
uniform float water_alpha : hint_range(0.0, 1.0) = 0.85;

uniform float refraction_strength = 0.04;
uniform vec2 refraction_scroll = vec2(0.03, 0.02);

uniform float wave_height = 0.03;
uniform float wave_frequency = 3.0;
uniform float wave_speed = 1.2;

uniform float foam_threshold = 0.30;
uniform float foam_noise_scale = 2.0;
uniform vec2 foam_scroll = vec2(0.05, 0.03);

uniform float cap_threshold = 0.85;
uniform float cap_noise_scale = 1.5;
uniform vec2 cap_scroll = vec2(0.06, -0.04);

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Layer 3: two sine waves 90 degrees apart, multiplied (A x B).
	float wave_a = sin(world_pos.x * wave_frequency + TIME * wave_speed);
	float wave_b = sin(world_pos.z * wave_frequency * 1.3 + TIME * wave_speed * 0.8);
	VERTEX.y += wave_a * wave_b * wave_height;
}

void fragment() {
	// View-space depth difference between the scene behind and the surface.
	float depth_raw = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	vec4 upos = INV_PROJECTION_MATRIX * vec4(vec3(SCREEN_UV * 2.0 - 1.0, depth_raw), 1.0);
	float scene_z = -(upos.xyz / upos.w).z;
	float depth_diff = max(scene_z - (-VERTEX.z), 0.0);

	// Layer 1: depth fade, quantized to bands.
	float fade = clamp(depth_diff / depth_fade_distance, 0.0, 1.0);
	fade = floor(fade * color_bands) / color_bands;
	vec3 water = mix(shallow_color.rgb, deep_color.rgb, fade);

	// Layer 2: refraction of the (already pixelized) scene behind, calmer
	// in the shallows.
	vec2 wuv = world_pos.xz;
	vec2 refr_n = texture(water_noise, wuv * 0.5 + refraction_scroll * TIME).rg - 0.5;
	vec3 behind = texture(SCREEN_TEXTURE, SCREEN_UV + refr_n * refraction_strength * fade).rgb;
	vec3 col = mix(behind, water, water_tint);

	// Layer 4: shoreline foam band, deliberately broken up by noise.
	float foam_n = texture(water_noise, wuv * foam_noise_scale + foam_scroll * TIME).r;
	float foam = step(depth_diff, foam_threshold * (0.4 + foam_n));
	col = mix(col, foam_color.rgb, foam);

	// Layer 5: whitecaps, a hard threshold on scrolling noise, deeper water
	// only.
	float cap_n = texture(water_noise, wuv * cap_noise_scale + cap_scroll * TIME).r;
	float caps = step(cap_threshold, cap_n) * smoothstep(0.2, 0.6, fade);
	col = mix(col, foam_color.rgb, caps);

	ALBEDO = col;
	ALPHA = max(water_alpha, foam);
}
