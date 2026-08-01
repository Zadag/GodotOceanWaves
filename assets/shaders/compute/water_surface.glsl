#[compute]
#version 460
/**
 * Samples the water surface height at a batch of world-space positions.
 * Mirrors the displacement accumulation done in water.gdshader:vertex() so
 * that the CPU can read back accurate wave heights for buoyancy.
 *
 * Note: The distance-based displacement falloff (distance_factor) is ignored;
 * positions near the camera are unaffected by it.
 */

#define MAX_CASCADES 8

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform texture2DArray displacement_texture;
layout(set = 0, binding = 1) uniform sampler displacement_sampler;

layout(std140, set = 1, binding = 0) restrict uniform UniformBuffer {
	vec4 map_scales[MAX_CASCADES]; // [uv scale, displacement scale, normal scale] per cascade.
	vec2 water_origin;             // Water mesh local-space origin in world XZ.
	uint num_cascades;
	uint sample_count;
} ub;

layout(std430, set = 2, binding = 0) restrict buffer Positions {
	vec4 positions[]; // xy = world XZ to sample.
} positions;

layout(std430, set = 2, binding = 1) restrict buffer Results {
	vec4 results[]; // w = water height at the corresponding position.
} results;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= ub.sample_count) { return; }

	vec2 local_xz = positions.positions[idx].xy - ub.water_origin;
	float height = 0.0;
	for (uint i = 0U; i < ub.num_cascades; ++i) {
		vec4 scales = ub.map_scales[i];
		vec3 d = texture(sampler2DArray(displacement_texture, displacement_sampler), vec3(local_xz * scales.xy, float(i))).xyz;
		height += d.y * scales.z;
	}
	results.results[idx] = vec4(0.0, 0.0, 0.0, height);
}
