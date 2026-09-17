shader_type particles;
render_mode disable_velocity;
/**
 * Splash particles emitted along the ship's hull waterline. Particles are
 * distributed along the hull perimeter ring in ship-local space (via
 * EMISSION_TRANSFORM) and activated wherever the sampled wave height rises
 * above the hull's waterline. Splash energy scales with submersion depth and
 * with a CPU-driven crash_intensity for waves that top the deck.
 */

#define MAX_CASCADES      8
#define G                 (vec3(0, -9.81, 0))

// Some definitions for convenience...
#define POSITION          (TRANSFORM[3].xyz)
#define START_POS         (USERDATA1.xyz)
#define START_TIME        (USERDATA1.w)
#define PARTICLE_SCALE    (USERDATA2.xyz)
#define PARTICLE_LIFETIME (USERDATA2.w)
#define RING_DIR          (USERDATA3.xy) // Outward direction on the hull ring, ship-local XZ.
#define SCALE_FACTOR      (USERDATA3.z)
#define HAS_STARTED       (USERDATA3.w)

uniform uint num_particles;
uniform float lifetime = 1.6; // Actual lifetime of a particle.
uniform float lifetime_randomness : hint_range(0.0, 1.0) = 0.5;
uniform vec3 particle_scale = vec3(1.0);
uniform float submersion_gain : hint_range(0.0, 4.0) = 1.5;
uniform float crash_intensity : hint_range(0.0, 1.0) = 0.0;

group_uniforms hull_shape;
uniform sampler2D hull_sdf : filter_linear;                          // Baked top-down hull outline: 0.5 = hull side, >0.5 outside.
uniform vec4 hull_uv_rect = vec4(-2.6251, -8.2, 0.19248, 0.060976);  // xy: silhouette min XZ (ship-local). zw: 1/span XZ.
uniform float sdf_range = 2.0;                                       // Metres encoded between texel values 0.5 and 0.0/1.0.
uniform mat4 ship_transform_inverse = mat4(1.0);                     // World -> ship-local. Updated per-frame by ship.gd.
uniform vec4 ring_heights = vec4(0.1, 1.2, 0.45, 0.0);               // x: waterline (local Y). y: deck height (local Y). z: hull band half-width (m). w unused.
uniform float deck_ring_ratio : hint_range(0.0, 1.0) = 0.35;         // Fraction of particles assigned to the deck (bulwark) ring.

float sample_hull_sdf(vec2 ship_local_xz) {
	vec2 uv = (ship_local_xz - hull_uv_rect.xy)*hull_uv_rect.zw;
	// Strictly bound sampling to the silhouette's bounding box; treat everything
	// outside it as open water so texture state can never create phantom spray.
	if (any(lessThan(uv, vec2(0.001))) || any(greaterThan(uv, vec2(0.999)))) { return sdf_range; }
	return (texture(hull_sdf, uv).r - 0.5)*2.0*sdf_range;
}

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];                  // Scales for displacement maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;            // Each layer represents one wave cascade.

// Source: https://www.shadertoy.com/view/Xt3cDn
vec3 hash32(uvec2 p) {
	p = 1103515245U * ((p >> 1U) ^ p.yx);
	uint h32 = 1103515245U * (p.x ^ (p.y>>3U));
	uint n = h32 ^ (h32 >> 16U);
    uvec3 rz = uvec3(n, n*16807U, n*48271U);
    return vec3((rz >> 1U) & uvec3(0x7FFFFFFFU)) / float(0x7FFFFFFF);
}

void set_scale(inout mat4 transform, in vec3 scale) {
	transform[0].xyz = normalize(transform[0].xyz) * scale.x;
	transform[1].xyz = normalize(transform[1].xyz) * scale.y;
	transform[2].xyz = normalize(transform[2].xyz) * scale.z;
}

// Source: https://iquilezles.org/articles/functions/
float exp_impulse(float x, float k) {
    float h = k*x;
    return h * exp(1.0 - h);
}

void start() {
	if (RESTART_POSITION) {
		vec3 rand = hash32(uvec2(NUMBER, 1U) + uint(TIME) + RANDOM_SEED);
		vec3 rand2 = hash32(uvec2(NUMBER, 3U) + uint(TIME) + RANDOM_SEED);

		// Particles are split between two rings: the hull waterline (constant spray where
		// waves ride up the hull sides) and the deck bulwark line (bursts only when a wave
		// actually overtops the deck).
		float deck_ring = step(1.0 - deck_ring_ratio, rand2.x);
		float ring_y = mix(ring_heights.x, ring_heights.y, deck_ring);

		// Distribute particles across the silhouette's bounding box; only those landing
		// within the hull band (checked against the SDF at activation time) become spray.
		uint t = uint(sqrt(float(num_particles)));
		vec2 cell = vec2(uvec2(INDEX / t, INDEX % t)) + rand.xy;
		vec2 ship_local_xz = hull_uv_rect.xy + cell / float(t) / hull_uv_rect.zw;

		// Outward direction from the SDF gradient (points away from the hull).
		float e = 0.1; // Gradient step in metres (~1.5 texels of the baked silhouette).
		float gx = sample_hull_sdf(ship_local_xz + vec2(e, 0.0)) - sample_hull_sdf(ship_local_xz - vec2(e, 0.0));
		float gy = sample_hull_sdf(ship_local_xz + vec2(0.0, e)) - sample_hull_sdf(ship_local_xz - vec2(0.0, e));
		vec2 grad = normalize(vec2(gx, gy) + vec2(1e-4));

		// Deck-ring particles spawn just inboard of the outline so the wash lands on deck.
		vec2 spawn_xz = ship_local_xz - grad*mix(0.0, 0.15, deck_ring);
		USERDATA4.xyz = vec3(spawn_xz.x, ring_y, spawn_xz.y);

		TRANSFORM[3].xyz = vec3(spawn_xz.x, ring_y, spawn_xz.y);
		TRANSFORM = EMISSION_TRANSFORM * TRANSFORM;

		RING_DIR = grad;
		CUSTOM.x = deck_ring; // Remember which ring this particle belongs to.
		CUSTOM.z = rand.x;
		PARTICLE_LIFETIME = lifetime - lifetime*lifetime_randomness*rand.y;
		START_POS = POSITION;
		START_TIME = TIME + rand.z*(LIFETIME - PARTICLE_LIFETIME);

		HAS_STARTED = 0.0;
		POSITION = vec3(0,-1e10,0);
		set_scale(TRANSFORM, vec3(1e-3));
		// Rest of initialization starts after the particle's start time has passed...
	}
}

void process() {
	if (TIME > START_TIME + PARTICLE_LIFETIME) {
		ACTIVE = false;
	} else if (TIME >= START_TIME) {
		if (HAS_STARTED == 0.0) { // Particle has just started according to its start time.
			// --- PARTICLE INITIALIZATION ---
			// Follow the moving rail during the random start delay, then launch.
			START_POS = (EMISSION_TRANSFORM * vec4(USERDATA4.xyz, 1.0)).xyz;
			// Same world-space/choppiness inversion as the CPU wave sampler.
			float wave_height = 0.0;
			vec2 source = START_POS.xz;
			for (int iteration = 0; iteration < 4; ++iteration) {
				vec3 displacement = vec3(0.0);
				for (uint i = 0U; i < num_cascades; ++i) {
					vec3 scales = map_scales[i].xyz;
					displacement += texture(displacements, vec3(source*scales.xy, float(i))).xyz * scales.z;
				}
				wave_height = displacement.y;
				source = mix(source, START_POS.xz - displacement.xz, 0.75);
			}
			// START_POS.y is the ship's waterline (or deck) in world space at spawn time.
			float submersion = wave_height - START_POS.y;
			// Only particles hugging the hull outline (within the band) can become spray.
			vec3 spawn_local = (ship_transform_inverse * vec4(START_POS, 1.0)).xyz;
			float band = abs(sample_hull_sdf(spawn_local.xz)) < ring_heights.z ? 1.0 : 0.0;
			ACTIVE = submersion > 0.0 && band > 0.5;

			float energy = min(submersion*submersion_gain, 1.5);
			energy *= mix(1.0, 2.5, crash_intensity); // Waves topping the deck throw harder.
			SCALE_FACTOR = energy*float(ACTIVE);
			PARTICLE_SCALE = min(energy, 1.2)*float(ACTIVE)*particle_scale;
			vec3 out_dir = (EMISSION_TRANSFORM * vec4(RING_DIR.x, 0.0, RING_DIR.y, 0.0)).xyz;
			float speed = 0.8 + 1.6*clamp(SCALE_FACTOR, 0.0, 2.0);
			float rise = 1.5 + 2.0*SCALE_FACTOR + 2.5*crash_intensity;
			VELOCITY = out_dir*speed*mix(1.0, -0.85, CUSTOM.x) + vec3(0, rise*mix(1.0, 0.55, CUSTOM.x), 0);
			HAS_STARTED = 1.0;
		}

		if (ACTIVE) {
			float t = (TIME - START_TIME) / PARTICLE_LIFETIME;
			CUSTOM.a = exp_impulse(t, 10.0); // For use in mesh shader.

			// --- PARTICLE POSITION SHAPING ---
			// Ballistic burst. Hull-ring particles spray outward from the hull sides;
			// deck-ring particles erupt up and wash inboard over the bulwark.
			float deck_ring = CUSTOM.x;
			POSITION = START_POS + VELOCITY*t*PARTICLE_LIFETIME + G*(0.5*t*t*PARTICLE_LIFETIME*PARTICLE_LIFETIME);
			// Water landing on deck becomes surface wash instead of falling through it.
			vec3 local_position = (ship_transform_inverse * vec4(POSITION, 1.0)).xyz;
			if (deck_ring > 0.5 && local_position.y < ring_heights.y && t > 0.1) { ACTIVE = false; }

			// --- PARTICLE SCALE SHAPING ---
			float size = PARTICLE_LIFETIME / lifetime; // Shorter particle lifetime = smaller size.
			vec3 scale_modifier = vec3(size*size);
			scale_modifier *= mix(1.0, 1.4, deck_ring); // Deck wash reads bigger.
			// Some shaping functions to get a splash-like animation.
			scale_modifier.y *= exp_impulse(t, 3.0);
			scale_modifier.xz *= vec2(log(1.0 + t));
			set_scale(TRANSFORM, PARTICLE_SCALE*scale_modifier);
		}
	}
}
