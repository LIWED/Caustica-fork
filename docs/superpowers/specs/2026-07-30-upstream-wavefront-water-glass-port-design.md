# Upstream Wavefront Water/Glass Port Design

## Status

- Approved direction: create a new upstream-based working directory and replay only selected fork behavior.
- Phase 1 scope: glass/water stability fixes only.
- Upstream baseline: `ComfyFluffy/Caustica` main snapshot at `5d6bf6222807bc9d09065190ed036c836134af90`.
- No Git operations.

## Goal

Create `F:\mygit\test\Caustica_n\Caustica-upstream-port` from the downloaded official snapshot, preserve its wavefront renderer and port only the fork's missing glass/water stability behavior.

## Included

1. Apply current-medium Beer-Lambert attenuation in upstream Pass B before the hit/miss split:
   - finite hit uses `payload.hitT`;
   - miss uses the `10000.0` trace horizon;
   - attenuation occurs exactly once.
2. Add per-segment medium attenuation to `guides.resolveTransmissionGuide`:
   - use `medium.current.extinction`;
   - attenuate before miss/opaque publication and before medium push/pop;
   - remove interface tint filtering that would double-count upstream volume extinction.
3. Stabilize water transmission in all three locations:
   - `world_primary.rgen.slang`;
   - `world.rgen.slang`;
   - `guides.slang`.
4. Animated wave normals continue to control water Fresnel, reflection, reflection guides and caustics.
5. Geometric normals control water refraction and transmitted guide direction.
6. Geometric refraction TIR forces reflection and does not update `MediumStack`.
7. Add focused RED/GREEN shader contracts, compile all shader variants, run upstream tests and complete a local build.

## Excluded

- `minecraft:light` source capture, point-light tables, RIS point-light integration and glass Light highlights.
- Offline accumulation, freeze ownership, offline UI/options and FP32 payload/continuation work.
- Fork static-light/CDF infrastructure.
- Fork monolithic `world.rgen.slang`.
- Per-interface square-root glass tint; upstream volume extinction remains authoritative.
- Changes to the upstream material, RIS, wavefront queue or 48-byte continuation ABI.
- Copying a JAR into a game instance.

## Architecture

Keep upstream modules and ownership unchanged:

- Pass A owns primary visibility, guides and the first dielectric split.
- Pass B owns radiance, NEE/RIS, SPP and later dielectric transport.
- `MediumStack` remains the only radiance/guide medium state.
- `SpecSurface` remains the first-interface reflection identity.
- Ordinary transmission guides remain a coherent destination tuple.

Only the missing attenuation ordering and water transmission-normal policy are changed.

## Verification

- First build the unmodified upstream snapshot to establish a baseline.
- Write focused contracts before production shader edits and observe expected RED failures.
- After implementation, require focused contracts, upstream Java tests, shader compilation and the full local build to exit 0.
- Record that game-level RR/FG visual validation remains pending.

## Documentation

After code changes, update the new port directory's `docs/PROJECT.md`, `docs/CHANGELOG.md` and `docs/BUGS.md`, keeping each below 200 lines.
