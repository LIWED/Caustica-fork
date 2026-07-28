# Frame Generation Video Toggle Design

## Goal

Expose Caustica's existing DLSS Frame Generation enable setting in Minecraft's
vanilla Video Settings screen so players can turn 2x frame generation on or off
without editing `config/caustica.toml`.

The toggle must take effect during the current session without restarting the
game.

## Scope

This change adds one boolean option to the existing Ray Tracing section:

- Caption: `Frame Generation`
- Position: immediately after `DLSS Quality`
- Backing setting: `CausticaConfig.Rt.Fg.ENABLED`
- Persistence: existing `VideoSettingsScreenMixin.removed()` config save
- Runtime behavior: immediate, through the renderer's existing per-frame reads
  of `RtDlssFg.enabled()`

This change does not:

- expose `frame-generation.multi-frame-count`;
- enable multi-frame generation above 2x;
- add a separate Caustica settings screen;
- change DLSS Ray Reconstruction controls;
- implement offline rendering;
- rebuild or release the NGX feature when the toggle is switched off.

## 2x-Only Safety Constraint

Only 2x frame generation is currently supported reliably. Higher multipliers
are known to crash.

Caustica represents 2x mode as one generated frame between real frames:

```toml
[frame-generation]
enabled = true
multi-frame-count = 1
```

The Video Settings UI will expose only `enabled`. It will not display or change
`MULTI_FRAME_COUNT`, so the new control cannot select a known-unsafe higher
multiplier.

Protecting manually edited unsafe values is outside this small UI change. A
later hardening change may clamp the renderer to one generated frame until
higher multipliers are fixed.

## Architecture

`RtVideoOptions` already builds the options shown by
`VideoSettingsScreenMixin`. The implementation will add a
`frameGeneration()` boolean `OptionInstance` using the same `bool(...)` helper
as the existing entity, particle, water, and HDR toggles.

The option will bind directly to:

```java
CausticaConfig.Rt.Fg.ENABLED
```

No additional runtime event is required:

1. The UI callback calls `BooleanSetting.set(...)`.
2. `RtDlssFg.enabled()` reads that setting on every relevant frame.
3. Disabling stops `RtFramePresenter.isActive()` from scheduling generated
   presents on the next frame.
4. Enabling lets the existing client tick probe availability and lets the
   existing render path create or reuse the DLSSG feature.
5. Leaving Video Settings calls the existing `CausticaConfig.save()`.

Keeping a previously created DLSSG feature allocated while disabled avoids the
`vkDeviceWaitIdle` used by feature destruction and makes repeated toggling
cheap.

## Availability and Failure Behavior

The option represents the user's request, not a guarantee that the current GPU
can run DLSS Frame Generation.

When enabled:

- the existing client tick performs the NGX/DLSSG capability probe;
- supported hardware activates the current FG path;
- unsupported hardware or driver failure follows existing logging and failure
  behavior;
- the video option remains enabled in the saved configuration.

This design intentionally avoids adding new hardware-state UI because the
availability probe is asynchronous and currently has no dynamic widget-state
bridge.

## User-Facing Text

Add English and Simplified Chinese translation entries for:

- `caustica.options.rt.frameGeneration`
- `caustica.options.rt.frameGeneration.tooltip`

The tooltip will state:

- the option inserts one generated frame between rendered frames (2x);
- a supported NVIDIA RTX GPU and driver are required;
- higher frame-generation multipliers are not exposed;
- future offline rendering mode cannot be used at the same time.

Only the new Simplified Chinese entries are in scope. Existing encoding damage
elsewhere in `zh_cn.json` will not be repaired as part of this feature.

## Future Offline Rendering Interaction

Offline rendering is a separate feature. When it is implemented, entering
offline mode must disable or bypass both:

- DLSS Ray Reconstruction;
- DLSS Frame Generation.

This frame-generation toggle remains the persisted gameplay preference.
Offline mode should temporarily suppress FG rather than erase that preference,
so leaving offline mode can restore the player's previous setting.

## Testing

Implementation follows test-first development:

1. Add a test that inspects the runtime option specification/order and fails
   because Frame Generation is absent.
2. Add the minimum production change that inserts Frame Generation after DLSS
   Quality and binds it to `CausticaConfig.Rt.Fg.ENABLED`.
3. Verify the focused test passes.
4. Run the complete test task.
5. Run the Gradle build when the required Java, Vulkan, shader, CMake, and DLSS
   SDK environment is available.

Because the current machine's Caustica build environment is not configured,
code can be written and statically reviewed now, but the feature must not be
reported as build-verified until those commands complete successfully.

## Acceptance Criteria

- A `Frame Generation` boolean appears in the Ray Tracing section immediately
  after `DLSS Quality`.
- The initial widget value matches `CausticaConfig.Rt.Fg.ENABLED`.
- Changing the widget updates that setting immediately.
- Disabling prevents generated-frame presentation from the next frame.
- Enabling allows the existing probe/create path to activate FG without a game
  restart.
- Leaving Video Settings persists the value to `caustica.toml`.
- The UI exposes no multiplier control and therefore offers only 2x mode.
- English and Simplified Chinese labels and tooltips exist.
- Offline rendering is not implemented in this change.
