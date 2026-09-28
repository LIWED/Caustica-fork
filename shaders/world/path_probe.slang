module path_probe;

// Version 1 readback ABI. Keep every lane 16-byte aligned (host decoder is explicit).
public typealias ProbePtr<T> = Ptr<T, Access.ReadWrite, AddressSpace.Device, Std430DataLayout>;
public struct PathProbeStep {
    public float4 position_hitT;
    public float4 incoming_inWater;
    public float4 geometricNormal_material;
    public float4 throughputBefore_protected;
    public float4 albedo_perceptualRoughness;
    public float4 F0_metal;
    public float4 effectiveNormal_rouletteProbability;
    public float4 throughputAfter_survived;
    public float4 outgoing_event;
    public float4 maxContribution_category;
};
public struct PathProbeRecord {
    public uint4 pixel_sample;
    public uint4 source;
    public float4 peak_rgb;
    public uint4 state;
    public PathProbeStep steps[33];
};
