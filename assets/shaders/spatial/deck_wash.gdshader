shader_type spatial;
render_mode cull_disabled, depth_draw_never;

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;
uniform sampler2D wash_state : filter_linear, repeat_disable; // depth, velocity XZ, foam
uniform sampler2D wetness_map : filter_linear, repeat_disable;
uniform sampler2D hull_sdf : filter_linear, repeat_disable;
uniform sampler2D scene_color : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D scene_depth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 hull_uv_rect;
uniform vec4 cabin_rect;
uniform vec2 cell_size;

varying vec2 local_xz;
varying vec2 state_uv;
varying mat3 wash_to_view;

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(dot(i, vec2(127.1, 311.7)), dot(i + vec2(1, 0), vec2(127.1, 311.7)), dot(i + vec2(0, 1), vec2(127.1, 311.7)), dot(i + vec2(1, 1), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

void vertex() {
	wash_to_view = mat3(MODELVIEW_MATRIX);
	// Derive UV from geometry, independent of PlaneMesh's texture orientation.
	local_xz = VERTEX.xz + hull_uv_rect.xy + 0.5 / hull_uv_rect.zw;
	state_uv = (local_xz - hull_uv_rect.xy) * hull_uv_rect.zw;
	vec4 state = textureLod(wash_state, state_uv, 0.0);
	float ripple = sin(local_xz.x * 13.0 + local_xz.y * 8.0 - TIME * 7.0) * sin(local_xz.y * 17.0 + TIME * 4.0);
	VERTEX.y += state.r + ripple * min(state.r * 0.15, 0.018);
}

void fragment() {
	float sdf = (texture(hull_sdf, state_uv).r - 0.5) * 4.0;
	if (sdf > 0.02) { discard; }
	if (all(greaterThan(local_xz, cabin_rect.xy)) && all(lessThan(local_xz, cabin_rect.zw))) { discard; }
	vec4 state = texture(wash_state, state_uv);
	float depth = max(state.r, 0.0);
	float wet = texture(wetness_map, state_uv).r;
	if (depth < 0.0005 && wet < 0.015) { discard; }
	vec2 texel = 1.0 / vec2(textureSize(wash_state, 0));
	float hx = texture(wash_state, state_uv + vec2(texel.x, 0)).r - texture(wash_state, state_uv - vec2(texel.x, 0)).r;
	float hz = texture(wash_state, state_uv + vec2(0, texel.y)).r - texture(wash_state, state_uv - vec2(0, texel.y)).r;
	vec2 flow = state.gb;
	// Blend two wrapping flow phases to avoid periodic snapping of foam/ripples.
	float phase = fract(TIME * 0.35);
	float phase2 = fract(TIME * 0.35 + 0.5);
	float blend = abs(phase * 2.0 - 1.0);
	vec2 p = local_xz * 5.0;
	float n = mix(noise(p - flow * phase * 2.0), noise(p - flow * phase2 * 2.0), blend);
	float fine = noise(local_xz * 23.0 + vec2(TIME * 0.7, -TIME * 0.9));
	float broken_foam = smoothstep(0.26, 0.72, n + fine * 0.18);
	float front = (1.0 - smoothstep(0.04, 0.22, depth)) * smoothstep(0.004, 0.035, depth);
	float foam = clamp((state.a * 0.9 + front * min(length(flow) * 0.24, 0.55)) * broken_foam, 0.0, 0.92);
	vec2 slope = vec2(hx, hz) / (2.0 * cell_size);
	slope += vec2(sin(local_xz.x * 21.0 + n * 5.0 - TIME * 4.0), cos(local_xz.y * 19.0 + n * 4.0 - TIME * 3.0)) * 0.065 * smoothstep(0.002, 0.05, depth);
	NORMAL = normalize(wash_to_view * vec3(-slope.x, 1.0, -slope.y));
	float fresnel = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 5.0);
	vec2 refracted_uv = clamp(SCREEN_UV + NORMAL.xy * min(depth, 0.5) * 0.035, vec2(0.001), vec2(0.999));
	// Reject foreground samples so rails and the cabin cannot smear onto the wash.
	float background_depth = texture(scene_depth, refracted_uv).r;
	vec4 background_view = INV_PROJECTION_MATRIX * vec4(refracted_uv * 2.0 - 1.0, background_depth, 1.0);
	if (-background_view.z / background_view.w < -VERTEX.z) { refracted_uv = SCREEN_UV; }
	vec3 transmission = exp(-vec3(3.4, 1.6, 1.1) * depth);
	EMISSION = texture(scene_color, refracted_uv).rgb * transmission * (1.0 - foam) * 0.88;
	ALBEDO = mix(water_color.rgb * 0.4, foam_color.rgb, foam);
	METALLIC = 0.0;
	SPECULAR = 0.25; // Approximately 2% reflectance for the air/water interface.
	ROUGHNESS = mix(0.2 + n * 0.12, 0.72, foam);
	// Thin edges reveal the deck; deeper green water and foam become opaque.
	float water_alpha = smoothstep(0.001, 0.07, depth) * 0.9;
	ALPHA = clamp(max(wet * 0.24, water_alpha) + fresnel * wet * 0.12 + foam * 0.35, 0.0, 0.98);
	ALPHA *= 1.0 - smoothstep(-0.09, 0.02, sdf);
}
