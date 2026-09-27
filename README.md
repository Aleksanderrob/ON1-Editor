# ON1 Editor

A local-first macOS prototype for turning a trip folder into a more coherent set of photos. It measures each photo, learns a target look from reference images you select, creates an individual edit plan, shows before/after previews, flags visual outliers, and exports edited JPEGs. The source photos remain untouched.

This is an early working milestone of the [product brief](docs/PRODUCT_BRIEF.md), built for one photographer and modest collections. It is not a finished RAW workflow or an ON1 Photo RAW plugin.

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
7. To continue in ON1 Photo RAW 2026, choose **Prepare for ON1…** and a location outside the trip folder. The app copies only selected photos into a new workspace, adds the style references and an individual `.cube` look and JSON plan for each photo, then launches ON1 and shows the copy folder in Finder. In ON1, choose **Browse Folder** and select **Photos to Edit** from the workspace. The workspace includes edited previews and instructions. Apply the matching LUT in ON1, refine the RAW edit, and export there at the size shown in the handoff. This handoff does not automatically navigate ON1 to the folder, set its sliders, or run its export command.

JPEG, PNG, HEIC/HEIF, TIFF and several RAW formats are accepted when macOS ImageIO can decode the camera file. RAW export renders from the full image, with a size check to avoid silently exporting an embedded low-resolution preview. Camera support varies with macOS; an unsupported RAW yields an error and is not exported. Unreadable files are skipped during import. The current renderer writes 8-bit sRGB JPEGs and does not expose RAW development controls such as demosaicing or white balance.

All previews and trip preferences stay in `~/Library/Application Support/ON1Editor/`. ON1 handoffs are placed only in the destination you choose. No image or preference is uploaded. The app does not modify ON1 sidecars or presets.

## What is implemented

- Local folder discovery, EXIF capture date reading, cached previews and trip persistence.
- Separate reference JPEG import, multi-reference style profiles, selected-photo editing and RAW-only selection.
- Structured image metrics: luminance, contrast, saturation, warmth, and clipped highlight/shadow proportions.
- Median reference style profile with broad lighting classes.
- Per-image, renderer-independent edit plans and a native JPEG renderer.
- Post-render consistency score with review/outlier states.
- Stored corrections and modest preference learning within a trip.
- ON1 Photo RAW 2026 handoff with selected copies, separate references, per-photo `.cube` looks, edit plans, previews, and automatic opening of the copy folder.

## Current limits

The lighting classes are based on luminance. There is no semantic scene understanding, face or skin detection, local masking, advanced RAW development, or lens correction. The simple renderer and generated LUTs use global 8-bit sRGB-like adjustments; colour-critical use should wait for a colour-managed, higher-bit-depth renderer. ON1's RAW pipeline and LUT stage can produce a different result from the native preview. Confidence is a heuristic rather than a calibrated probability. The review list is shown by status in the photo sidebar, with no review-only filter yet. This milestone has not been validated against a representative set of real camera RAW files. ON1 handoff is automated, but applying each photo's look and exporting from ON1 remain manual because no supported per-photo edit API has been verified.

The [architecture and next milestone](docs/ARCHITECTURE.md) and [open-source reuse findings](docs/RESEARCH.md) record the boundaries and remaining investigations.

## Verify

```sh
swift build
sh Scripts/self-test.sh
```

The standalone self-test checks different plans for bright and dark images, conservative learning from a correction, outlier detection, a real JPEG render from a synthetic image, and the ON1 workspace and LUT output. On this development Mac, Swift Package Manager required `--disable-sandbox` and the installed macOS 26.5 SDK because the default SDK and compiler patch levels differ; that is a local toolchain issue.

## Project status

This public repository has no project license yet. No third-party source code or model weights are included. See the [reuse findings](docs/RESEARCH.md) before adding outside code.
