# Glass Reflection and Stable Water Transmission Design

## Problem

- Realtime `minecraft:light` point sources have no geometry, so a glass reflection ray cannot hit them.
- Glass is an ideal stochastic dielectric; at normal incidence only about 4.26% of realtime 1-SPP samples choose reflection.
- Glass/water `gSpecAlbedo` currently describes the transmitted endpoint while `gSpecMotion` describes the first-interface reflection.
- Animated water normals move the refracted image without a matching previous-frame refracted motion vector.
- Stained-glass tint is applied once per interface and is absent from the transmitted diffuse guide.

## Approved conservative design

1. Add realtime Light direct sampling to the glass branch with zero diffuse albedo, dielectric F0, and the existing smooth glass guide roughness. Do not change Fresnel probability and do not add ordinary emissive or celestial NEE here.
2. Keep first-interface normal, roughness, depth, specular albedo, and reflection motion together. Glass and water `gSpecAlbedo` use view-dependent dielectric reflectivity.
3. Keep only ordinary albedo and ordinary motion on the transmitted endpoint. Accumulate square-root stained-glass tint per crossed glass interface and Beer-Lambert attenuation per traced water segment into transmitted diffuse albedo.
4. Apply square-root stained-glass tint to radiance at each transmitted glass interface, so a normal front/back pane pair applies the authored tint once.
5. Let animated water normals affect reflection, Fresnel, highlights, and caustics. Use the geometric water normal for primary and auxiliary transmission refraction until dedicated refracted optical flow exists.

## Boundaries

- Ordinary opaque, emissive, particle, and water direct-light behavior stays unchanged.
- Realtime Light sampling and offline static-light sampling remain mutually exclusive through their existing flags.
- The four-transparent-interface guide cap and full primary-payload restore remain intact.
- No DLSS transparency-layer integration is included.
- Automated shader/build verification is required; game-level visual validation remains separate.

## Visual validation matrix

- RR on/off; Frame Generation on/off.
- Still camera and lateral movement.
- Clear glass, stained glass, water, glass plus water column, and stacked stained glass plus water.
- Front-facing and grazing-angle strong `minecraft:light`.
- Verify no glass-tinted reflection, no raised diffuse transmission, stable water transmission, retained wave reflections, and depth-dependent water absorption.
