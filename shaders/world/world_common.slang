// Shared definitions for all ray-tracing stages. The generateShaderRecords task generates typed Java
// records and serializers from Slang reflection.
module world_common;

// Read-only device pointer with explicit std430 layout. The layout parameter is LOAD-BEARING: a bare
// Ptr<T> gets Slang's "natural" layout (no vec4 16-byte alignment → e.g. WorldPush.sunDir lands at 200
// instead of the Java writer's 208, silently reading garbage) and additionally requires the
// scalarBlockLayout device feature. Keep std430 unless RtDeviceBringup explicitly enables that feature;
// this alias is the single layout switch and generated Java serialization stays in lock-step.
public typealias ConstPtr<T> = Ptr<T, Access.Read, AddressSpace.Device, Std430DataLayout>;

// Push constant block. Only the first 8 bytes (worldPushAddr) are meaningful to rgen/rchit/rmiss;
// the hot inline lanes (tableAddr/entityTableAddr/frameIndex) exist so world.rahit's per-hit
// Section/EntityGeom fetch skips the extra global-memory load of dereferencing WorldPush first.
public struct PushAddr {
    public uint64_t worldPushAddr;
    public uint64_t tableAddr;
    public uint64_t entityTableAddr;
    public uint frameIndex;
};

// Block-breaking overlay entry: xyz = breaking block position (rebased, same space as gl_WorldRay*),
// w = bindless entityTex slot of the destroy-stage texture.
public struct BreakEntry {
    public int4 posSlot;
};

// Per-frame world data, read through a 64-bit device address. WorldPushData.java is generated from this
// reflected type, including its serializer, byte size, vector/matrix types, and fixed-array capacities.
public struct WorldPush {
    public float4x4 invViewProj;
    public float3   camOffset;
    public uint64_t tableAddr;        // section table
    public uint64_t staticLightAddr;  // weighted offline static-light records
    public uint     staticLightCount;
    public float    staticLightTotalWeight;
    public uint64_t realtimeLightBlockAddr;
    public uint     realtimeLightBlockCount;
    public float    realtimeLightBlockTotalWeight;
    public uint64_t localDirectoryAddr;
    public uint64_t localReferenceAddr;
    public uint     localDirectoryCount;
    public uint     localReferenceCount;
    public uint     debugView;
    public uint     frameIndex;
    public float4x4 prevViewProj;
    public float3   camDelta;
    public uint     spp;
    public uint64_t offlineSampleBase;
    public float2   jitter;
    public uint64_t entityTableAddr;  // entity geometry table
    public uint     flags;            // bit0 submerged, bit1 PBR, bit4 waves, bit5 offline NEE, bit6 realtime Light NEE, bits7-8 offline regularization
    public uint     maxBounces;
    public float4   sunDir;           // xyz true sun direction, w dayFactor 0..1
    public float4   lightDir;         // xyz active NEE light dir, w square half-angle (rad)
    public float4   lightRadiance;    // xyz integrated angular celestial strength (offline Le = xyz * direction PDF), w stars
    public float4   moonDir;          // xyz moon direction, w moonPhase (0 full .. 4 new)
    public float4   celestial;        // xyz celestial rotation axis, w star angle (rad)
    public float4   sunUv;            // vanilla sun sprite atlas rect (u0,v0,u1,v1)
    public float4   moonUv;           // vanilla current-moon-phase sprite atlas rect
    public float4   waterParams;      // xyz camera-biome water tint, w wave time (s)
    public float4   waterAnchor;      // xy world-stable wave-domain anchor
    public float4x4 curViewProj;      // forward camera-relative view-projection
    public uint     breakCount;
    public BreakEntry breaking[8];    // Java capacity and breakCount serialization are generated from this
    public uint64_t pathProbeAddr;
    public float pathProbeThreshold;
};

// Radiance-ray payload (location 0). Member order and types are a cross-stage ABI.
public struct Payload {
    public float3 albedo;      // hit: block albedo. miss: sky radiance.
    public float3 normal;      // hit: geometric normal, viewer-oriented.
    public float  hitT;        // >= 0 on hit, < 0 on miss.
    public float3 motionPrev;  // per-vertex world displacement since last frame.
    public float3 f0;          // specular F0.
    public uint   flags;       // bits 0..1 material, bit 2 celestial miss, bit 3 water-entering hit, bit 4 offline glass LOD0 (trace-only).
    public uint   roughMetal;  // packHalf2x16(roughness, metalness)
    public uint   emissionSss; // packHalf2x16(emission, sss)
    public uint   rayCone;     // packHalf2x16(width, spread)
    public uint   staticLightIndex; // global area-light index, or 0xFFFFFFFF
    public uint   sectionSlot; // terrain receiver slot, or 0xFFFFFFFF for entity/particle/miss
};

public static const uint PAYLOAD_SHOW_CELESTIAL = 4u;
// Set only by offline raygen before tracing; closest-hit caches it before writing material flags.
public static const uint PAYLOAD_OFFLINE_GLASS_LOD0 = 16u;
// Set by world.rchit on a MATERIAL_WATER hit: true when the incoming ray travels against the prim's
// outward face normal (entering the water volume), false when it exits (water -> air). Bit 2
// (PAYLOAD_SHOW_CELESTIAL) is only meaningful on a miss and this bit only on a hit, so they never need
// to be read together, but they get distinct bits anyway to keep the two concerns unambiguous.
public static const uint PAYLOAD_WATER_ENTERING = 8u;

// Terrain per-triangle record (48 B, stride must match RtTerrain's upload).
// mat = {roughness, metalness, hasS, hasN} for solid/cutout; TRANSLUCENT-bucket prims repurpose it as
// a precomputed whole-sprite average color {r,g,b,a} (RtTerrain.emit()/translucentAvgColor).
public struct Prim {
    public float4 normal;
    public float4 tint;
    public float4 mat;
};

// Per-section geometry record: packed buffer addresses + per-bucket triangle offsets
// (gl_PrimitiveID restarts at 0 per geometry, so hit shaders re-add triBase[geometryIndex]).
public struct Section {
    public uint64_t primAddr;
    public uint64_t uvAddr;
    public uint64_t lightIndexAddr;
    public uint triBase[4]; // fixed bucket order: solid/cutout/translucent/water
};

// Offline static-light record (128 B). p0_kind.w: 0 area, 1 point. edge1_weight.w is the
// cumulative selection weight; uv2_emission.w is this record's individual selection weight.
public struct StaticLight {
    public float4 p0_kind;
    public float4 edge1_weight;
    public float4 edge2_area;
    public float4 uv01;
    public float4 uv2_emission;
    public float4 tint_hasS;
    public float4 pointData;
    public float4 reserved;
};

// Realtime minecraft:light point source (32 B). Position is relative to the terrain base; the two W
// lanes carry the cumulative and individual selection weights of the source CDF.
public struct RealtimeLightBlock
{
    public float4 positionCdf;
    public float4 radianceWeight;
};

// Per-terrain-slot local static-light CDF directory (16 B, std430).
public struct LocalLightDirectory {
    public uint referenceOffset;
    public uint referenceCount;
    public float totalWeight;
    public float reserved;
};

// One local CDF entry (8 B), sorted by globalLightIndex within each directory.
public struct LocalLightReference {
    public uint globalLightIndex;
    public float cumulativeWeight;
};

// Entity geometry record: {prim, index, uv} buffer addresses (same per-prim layout as terrain) + a
// per-vertex world-space displacement buffer for motion vectors (dispAddr == 0 ⇒ rigidDisp.xyz).
public struct EntityGeom {
    public uint64_t primAddr;
    public uint64_t idxAddr;
    public uint64_t uvAddr;
    public uint64_t dispAddr;
    public float4 rigidDisp;
};

// TLAS instance-custom-index encoding + terrain geometry buckets (shared by rahit/rchit).
public static const uint ENTITY_BIT = 0x800000u;
public static const uint PARTICLE_BIT = 0x400000u; // particles share the entity cutout path
public static const uint IDX_MASK = 0x3FFFFFu;     // low 22 bits = geom-table index
public static const uint BUCKET_CUTOUT = 1u;
public static const uint BUCKET_TRANSLUCENT = 2u;
public static const uint BUCKET_WATER = 3u;

// packHalf2x16 equivalent (Slang core module has no GLSL pack builtin; f32tof16 returns the half
// bit-pattern in the low 16 bits).
public uint packHalf2(float2 v) {
    return (f32tof16(v.y) << 16) | (f32tof16(v.x) & 0xFFFFu);
}

public float2 unpackHalf2(uint p) {
    return float2(f16tof32(p & 0xFFFFu), f16tof32(p >> 16));
}

// Vanilla's block/entity atlases are ordinary sRGB-encoded PNGs sampled through a plain UNORM view (no
// hardware sRGB decode), so the raw texel is gamma-encoded. The path tracer's BRDF math (Lambertian/GGX,
// Beer-Lambert, NEE) is only correct on linear radiance/albedo, so every COLOR texture sample (not the
// LabPBR _s/_n data maps, which are already linear data channels) must go through this before it's used
// in any lighting calculation.
public float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4, 2.4, 2.4));
    float3 isHi = step(float3(0.04045, 0.04045, 0.04045), c);
    return lerp(lo, hi, isHi);
}
