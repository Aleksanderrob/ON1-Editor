# Architecture and next milestone

## Current flow

```text
Trip photos ──────────────┐
Reference JPEGs ──────────┴→ PhotoLibrary/ImageIO → cached previews + ImageMetrics
                           → StyleEngine(reference median + lighting class)
                           → EditPlan → RendererAdapter → edited preview/JPEG
                           → StyleEngine.evaluate → review status
                                              ↑
                                       saved user corrections
```

The Swift models define image measurements, the reference style profile, renderer-independent plans, consistency results and corrections. `PhotoLibrary` discovers files and reads EXIF. `StyleEngine` has no UI or rendering dependency. `RendererAdapter` is the boundary for the current native renderer. `ON1Automation` copies selected originals to a private run folder, maps each plan to ON1's exposure, contrast, saturation and temperature controls, drives ON1's Edit and Export dialogs through macOS Accessibility, then checks exported dimensions. `ON1Bridge` retains the earlier manual workspace format as a fallback. `TripStore` keeps local copies of imported reference JPEGs and saves their paths, edit selection, export size and corrections. Original trip photos remain untouched.

The profile uses medians to reduce the effect of one unusual reference. The planner prefers references in the same broad lighting class. If there is no matching reference, it limits the requested brightness to retain the character of dark or bright scenes. Exposure, contrast, saturation and warmth are bounded. The evaluator measures the rendered preview again, compares it with the target and identifies large mismatches. These rules are deliberately transparent first-pass heuristics, not a trained visual-language model.

## Next practical milestone

1. Evaluate this prototype on a real trip with edited anchors; collect before/after examples and correction history. Tune confidence and consistency thresholds from those cases.
2. Add a local Facet analysis worker behind a versioned JSON interface, starting with technical metrics, scene categories and duplicate groups. Keep model downloads optional.
3. Validate the basic ImageIO RAW export against actual cameras, then add a higher-bit-depth RAW decode/render path with colour, orientation, metadata and lens corrections.
4. Add a scene-aware reference representation and richer edit vocabulary, then local masks and colour-managed rendering.
5. Prototype AceTone/LUT grading on a small image set and compare it with image-specific corrections before choosing an integration.
6. Resolve ON1 Photo RAW's Home-screen launch hang on the test Mac, then validate the Accessibility path on representative RAW formats. Keep its controls version-specific and fail closed if the interface changes. The current automation does not write undocumented ON1 files.

The [research notes](RESEARCH.md) explain why the external modules are staged this way.
