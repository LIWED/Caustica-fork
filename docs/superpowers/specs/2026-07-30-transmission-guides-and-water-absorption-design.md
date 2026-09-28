# Transmission Guides and Water Absorption Design

> **Superseded:** Historical design retained for traceability. The current design is
> [Glass Reflection and Stable Water Transmission](2026-07-30-glass-reflection-and-stable-water-transmission-design.md).

## Status

Superseded by the current glass-reflection and stable-water-transmission design. The historical implementation reached automated verification on 2026-07-30; game-level DLSS-RR visual validation remains pending.

## Problem

- Realtime content seen through glass and water is spatially soft and develops stronger temporal smear during camera motion.
- Water remains nearly clear at every depth because the primary water hit loses its entering/exiting state before the continuation updates the active medium.

## Confirmed causes

1. `refractedGuideHit` reuses the module-level radiance payload. The primary water branch calls it before `payloadWaterEntering()`, so the helper's opaque/sky hit overwrites the water-interface flags and prevents `inWater` from becoming true.
2. Glass radiance contains transmitted background content while its RR diffuse albedo and motion guides remain attached to the glass surface.
3. The water guide traces only one interface. A water column therefore commonly stops on another water interface and returns zero albedo with incomplete motion.
4. Surface depth and normal must remain stable for interface reflection and Frame Generation; changing the shared depth/motion identity wholesale to the background is out of scope.

## Design

### Payload preservation

At each primary glass or water interface, copy the full `Payload` before auxiliary guide tracing and restore it immediately afterward. Cache the water entering flag before the helper call. The path continuation must use only the restored primary payload and cached interface state.

### Bounded transmission guide

Replace the one-interface water helper with a bounded helper shared by glass and water:

- Start with straight transmission for glass and Snell refraction for water.
- Follow at most four transparent interfaces.
- Pass through glass without changing the water-medium state.
- At water interfaces, apply the current wave normal, refract according to the current medium, cache the hit's entering flag, then update the guide medium state.
- Stop at the first opaque hit or sky and report its diffuse albedo, specular albedo, hit position, and object motion.
- On total internal reflection or interface-budget exhaustion, retain safe surface fallbacks.

The helper may reuse the global payload internally, but both callers must restore their primary payload.

### RR guide ownership

- Keep primary interface normal, roughness, and depth on the first glass/water surface.
- Attach diffuse/specular albedo and ordinary motion to the transmitted opaque/sky background.
- Preserve the existing reflection-specific motion guide.
- Do not change Frame Generation resource bindings.

## Verification

- A focused transmission-guide contract must fail before production changes and pass afterward.
- All realtime/offline Slang ray-generation variants must compile and pass SPIR-V validation.
- Existing realtime Light-block, offline rendering, bounce-option, Frame Generation, and frame-stat contracts must remain green.
- The full local build succeeded, including the native NGX shim and packaged realtime/offline EXT/NV ray-generation resources.

## Manual validation boundary

Automated verification cannot prove final DLSS-RR image quality. Game validation must compare:

- RR enabled versus native raw tracing.
- Still camera versus camera movement.
- One glass layer, stacked glass, shallow water, and a deep water column.
- Water waves enabled and disabled.
- Frame Generation enabled and disabled.
