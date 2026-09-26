# ON1 Editor

A local-first macOS prototype for turning a trip folder into a more coherent set of photos. It measures each photo, learns a target look from reference images you select, creates an individual edit plan, shows before/after previews, flags visual outliers, and exports edited JPEGs. The source photos remain untouched.

This is the first working milestone of the [product brief](docs/PRODUCT_BRIEF.md), built for one photographer and modest collections. It is an early editor, not a finished RAW workflow or an ON1 Photo RAW plugin.

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

## First trip

1. Choose **Open Trip…** and select a folder. Nested folders are included. ImageIO generates cached previews and reads capture dates where available.
2. Select one or more photos and click **Use as Reference**. Their measured colour, tone and contrast define the trip target. References from matching lighting classes are preferred when planning edits.
3. Review each original and edited preview. The app plans exposure, contrast, saturation and warmth separately for every photo, then compares the rendered preview with the target. Images marked **Review** or **Outlier** deserve attention.
4. Move the correction sliders on an image and click **Apply Correction**. The saved correction affects that image and contributes a small preference bias to later plans for photos with similar lighting in this trip.
5. Choose **Export Edited JPEGs…**. The app writes full-resolution JPEGs and a JSON edit plan alongside each export, preserving the source folder structure. Existing exports are skipped rather than overwritten.

JPEG, PNG, HEIC/HEIF and TIFF are supported for export when macOS ImageIO can decode them. Several RAW extensions are discovered for preview, but RAW export is intentionally skipped in this milestone. Unreadable files are skipped during import.

All previews and trip preferences stay in `~/Library/Application Support/ON1Editor/`. No image or preference is uploaded. The app does not modify ON1 sidecars or presets.

## What is implemented

- Local folder discovery, EXIF capture date reading, cached previews and trip persistence.
- Structured image metrics: luminance, contrast, saturation, warmth, and clipped highlight/shadow proportions.
- Median reference style profile with broad lighting classes.
- Per-image, renderer-independent edit plans and a native JPEG renderer.
- Post-render consistency score with review/outlier states.
- Stored corrections and modest preference learning within a trip.

## Current limits

The lighting classes are based on luminance. There is no semantic scene understanding, face or skin detection, local masking, RAW development, lens correction, LUT generation, or direct ON1 automation yet. The simple renderer works in 8-bit sRGB and applies global adjustments; colour-critical use should wait for a colour-managed, higher-bit-depth renderer. Confidence is a heuristic rather than a calibrated probability. The review list is shown by status in the photo sidebar, with no review-only filter yet.

The [architecture and next milestone](docs/ARCHITECTURE.md) and [open-source reuse findings](docs/RESEARCH.md) record the boundaries and remaining investigations.

## Verify

```sh
swift build
sh Scripts/self-test.sh
```

The standalone self-test checks different plans for bright and dark images, conservative learning from a correction, outlier detection, and a real JPEG render from a synthetic image. On this development Mac, Swift Package Manager required `--disable-sandbox` and the installed macOS 26.5 SDK because the default SDK and compiler patch levels differ; that is a local toolchain issue.

## Project status

This public repository has no project license yet. No third-party source code or model weights are included. See the [reuse findings](docs/RESEARCH.md) before adding outside code.
