# Indirect regularization implementation plan

**Goal:** Deliver an optional, measured ordinary-PBR indirect regularization experiment without changing the reference setting.
**Architecture:** A pure Slang roughness policy, two existing push-flag bits, runtime option plus accumulation signature, and path-local non-delta history. Retain current workspace and prior authorized changes.
**Tech stack:** Java 25, Slang/SPIR-V, Python-generated C++ FP32 numerical tests.
**Constraints:** Default off; offline only; no global material roughening, sample clamp, water/glass rewrite or ABI extension. User authorized implementation following the comparison. No commits or unrelated edits.

- [x] Write policy/state and wiring tests; verify they fail before implementation.
- [x] Add pure policy and path-local history; bind one effective roughness to all ordinary consumers.
- [x] Add three-state setting, flags/signature, locales; record effective log interpretation.
- [x] Run extracted-production two-stage lighting experiment; report variance AND mean shift. Preserve reproducible output.
- [x] Run targeted existing regressions and complete native/Java/shader build. Verify artifact version/resources.
- [x] Update PROJECT/CHANGELOG/BUGS and experiment report, keeping each under 200 lines.
- [x] Deploy verified candidate with old version disabled/preserved and hash comparison.

Independent review found no runtime blocker. Required caveat retained: the grazing baseline is underconverged, so observed variance ratios are not stable efficiency predictions. Artifact SHA256: `db2abdc9cd8f484744bec22f0a2b404efeb57d2920609d1f3fca74b9f7f0e465`. GPU acceptance remains open.
