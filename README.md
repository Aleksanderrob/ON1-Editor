# ON1 Editor

A local-first macOS prototype for turning a trip folder into a more coherent set of photos. It measures each photo, learns a target look from reference images you select, creates an individual edit plan, shows before/after previews, flags visual outliers, and exports edited JPEGs. The source photos remain untouched.

This is an early working milestone of the [product brief](docs/PRODUCT_BRIEF.md), built for one photographer and modest collections. It can now drive ON1 Photo RAW 2026's own Edit and Export controls for selected photos. It is not an ON1 plugin.

## Run on macOS

Requires macOS 14 or later and a current Swift toolchain (Xcode or Command Line Tools).

```sh
swift run ON1Editor
```

To make a local `.app` bundle:

```sh
sh Scripts/build-app.sh
open .build/ON1Editor.app
```

The bundle is signed locally with an ad hoc signature. It is not notarized for distribution.
After building or unzipping the supplied app, you can open it by double-clicking `ON1Editor.app`; normal use does not require Terminal. A Desktop shortcut can point to that app.
If a synced folder adds Finder metadata to a built app and disrupts signature verification, set `ON1_EDITOR_APP_PATH` to a location outside that folder when running the build script.

## First trip

1. Choose **Open Trip…** and select a folder. Nested folders are included. ImageIO generates cached previews and reads capture dates where available.
2. Mark reference photos with the stars in the trip list, or choose **Add JPEG References…** to select JPEGs from another folder. Five reference JPEGs work as well as one; the app uses their median measurements and prefers matching lighting classes.
3. Mark photos to edit with the checkboxes. **RAW only** selects only RAW files; **All** and **None** reset the selection. JPEG references can remain unselected while RAW files receive edit plans.
4. Review each original and edited preview. The app plans exposure, contrast, saturation and warmth separately for every selected photo, then compares the rendered preview with the target. Images marked **Review** or **Outlier** deserve attention.
5. Move the correction sliders on an image and click **Apply Correction**. The saved correction affects that image and contributes a small preference bias to later plans for photos with similar lighting in this trip.
6. Keep **Original size** checked, or clear it and enter a long edge in pixels. Choose **Export Edited JPEGs…** and pick one output folder. The app writes edited JPEGs and JSON edit plans directly into that folder. Existing exports are skipped rather than overwritten.
7. For an ON1 Photo RAW 2026 export, choose **Run in ON1 and Export…** and an output folder. The app copies only the selected photos to a private run folder, opens each copy in ON1, sets its individual exposure, contrast, saturation and temperature controls, and runs ON1's JPEG export at your chosen long-edge size. It checks that each output exists and that its dimensions match. The first run asks macOS to allow ON1 Editor to control other apps. On this Mac the switch is in **System Settings → Privacy & Security → Device Control and Data Access**; older macOS versions call it **Accessibility**. ON1 must remain open and the Mac unlocked while it works. The run stops if ON1's controls do not match the verified sequence; it does not guess at a changed control.

JPEG, PNG, HEIC/HEIF, TIFF and several RAW formats are accepted when macOS ImageIO can decode the camera file. RAW export renders from the full image, with a size check to avoid silently exporting an embedded low-resolution preview. Camera support varies with macOS; an unsupported RAW yields an error and is not exported. Unreadable files are skipped during import. The current renderer writes 8-bit sRGB JPEGs and does not expose RAW development controls such as demosaicing or white balance.

All previews, trip preferences and ON1 run copies stay in `~/Library/Application Support/ON1Editor/`. The chosen export folder receives the ON1-rendered JPEGs. No image or preference is uploaded. The automation edits copies and does not write ON1 sidecars or presets itself.

## What is implemented

- Local folder discovery, EXIF capture date reading, cached previews and trip persistence.
- Separate reference JPEG import, multi-reference style profiles, selected-photo editing and RAW-only selection.
- Structured image metrics: luminance, contrast, saturation, warmth, and clipped highlight/shadow proportions.
- Median reference style profile with broad lighting classes.
- Per-image, renderer-independent edit plans and a native JPEG renderer.
- Post-render consistency score with review/outlier states.
- Stored corrections and modest preference learning within a trip.
- ON1 Photo RAW 2026 desktop automation: per-photo Edit controls, JPEG export to a selected folder, long-edge resolution, output checks, and a local run report.

## Current limits

The lighting classes are based on luminance. There is no semantic scene understanding, face or skin detection, local masking, advanced RAW development, or lens correction in the native renderer. ON1's RAW pipeline can produce a different result from the native preview. Confidence is a heuristic rather than a calibrated probability. This milestone has not been validated against a representative set of real camera RAW files. ON1 automation targets the verified 2026.5 desktop layout and needs macOS Accessibility access; an ON1 update may require adapting the controls. The app currently checks file existence and dimensions after ON1 export, but does not rescore the ON1-rendered image or automatically refine a second pass. The per-photo edits are exported, and the single-photo session is closed afterward; ON1 sidecars for those staged copies are not retained.

The [architecture and next milestone](docs/ARCHITECTURE.md) and [open-source reuse findings](docs/RESEARCH.md) record the boundaries and remaining investigations.

## Verify

```sh
swift build
sh Scripts/self-test.sh
```

The standalone self-test checks different plans for bright and dark images, conservative learning from a correction, outlier detection, a real JPEG render from a synthetic image, ON1 control mapping, and the ON1 workspace and LUT output. ON1's Edit and Export sequence was also exercised on disposable JPEGs; one test export was verified at 600 × 400 pixels. Full automation needs Accessibility permission and remains unverified until that permission is granted to the installed app. On this development Mac, Swift Package Manager required `--disable-sandbox` and the installed macOS 26.5 SDK because the default SDK and compiler patch levels differ; that is a local toolchain issue.

## Project status

This public repository has no project license yet. No third-party source code or model weights are included. See the [reuse findings](docs/RESEARCH.md) before adding outside code.
