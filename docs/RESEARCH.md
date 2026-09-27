# Open-source reuse and ON1 investigation

Checked 27 September 2026. These are integration decisions for the first milestone, not a claim that every candidate has been benchmarked. No third-party code, dependencies or model weights have been copied into this repository.

## Facet first

[Facet](https://github.com/ncoevoet/facet) is MIT licensed and has a substantial local photo-analysis pipeline. Its [package definition](https://github.com/ncoevoet/facet/blob/master/pyproject.toml) exposes Python command-line tools and depends on OpenCV, Pillow, rawpy, PyTorch-based models and a database/web application stack. It is a strong source for the next analysis milestone, but it is not a Swift library or a renderer.

| Facet area | Decision | Reason |
| --- | --- | --- |
| [`analyzers/color_facet.py`](https://github.com/ncoevoet/facet/blob/master/analyzers/color_facet.py) | Direct import in a future local Python worker | Small, guarded colour classifier using PIL and NumPy. Keep its output in a versioned analysis schema. |
| [`analyzers/image_cache.py`](https://github.com/ncoevoet/facet/blob/master/analyzers/image_cache.py) and [`analyzers/technical.py`](https://github.com/ncoevoet/facet/blob/master/analyzers/technical.py) | Import or adapt inside that worker | Useful cached grayscale/HSV calculations, sharpness, histogram and exposure metrics; they assume OpenCV BGR arrays and Facet utility modules. |
| Composition, face and aesthetic analyzers in [`analyzers/`](https://github.com/ncoevoet/facet/tree/master/analyzers) | Keep as optional external analysis modules | Model weight, runtime and device costs are larger than this prototype needs. Measure latency on Apple Silicon before making them default. |
| Burst/duplicate and personal ranker code in [`processing/`](https://github.com/ncoevoet/facet/tree/master/processing) and [`optimization/`](https://github.com/ncoevoet/facet/tree/master/optimization) | Adapt after evaluation | Facet optimizes culling choices and A/B photo rankings; ON1 Editor needs preferences over *edits* and style consistency. The learning target differs. |
| Facet's gallery, archive database, XMP export and watcher | Leave external | A trip folder of tens to hundreds of photos does not need a second archive or web UI. |

No Facet module can be imported directly into the native Swift process. “Direct import” above means using the original Python module inside an optional, separately installed local worker; this still needs dependency, output-schema, license-notice and performance work. Facet's models and culling scores should not be mistaken for edit instructions. The current app uses Apple ImageIO for discovery and a small native metric analyzer so it can run without a Python/ML environment. The existing `ImageMetrics` model is the seam for richer outputs.

## Other projects

| Project | Findings and current decision |
| --- | --- |
| [Photo Sorter](https://github.com/rickkeller/photo-sorter) | Its README states MIT. [`embeddings.py`](https://github.com/rickkeller/photo-sorter/blob/master/embeddings.py) provides cached CLIP ViT-L/14 embeddings with MPS support; deduplication and aesthetic scoring share those embeddings. It is a useful optional Python worker candidate. The roughly 3 GB model footprint and culling-first workflow make it secondary to Facet. Verify licensing of each downloaded model before bundling. |
| [AceTone](https://github.com/martian422/AceTone) | The repository is [Apache-2.0](https://github.com/martian422/AceTone/blob/open-source-ready/LICENSE) and releases a LUT tokenizer and conditional grading code. Its README describes a 3B preview model and a multi-GPU evaluation command. Prototype a small, local image set and check model-weight terms before embedding it. Do not make the edit planner depend on it yet. |
| [lut_generation](https://github.com/jonathangranskog/lut_generation) | MIT code for text-to-LUT experiments. The README warns that Gemma and DeepFloyd have separate licenses. Candidate for a small grading benchmark, not the whole editing pipeline. |
| [Image-Adaptive-3DLUT](https://github.com/HuiZeng/Image-Adaptive-3DLUT) | Image-adaptive LUT research code. Review its repository license and model/data rights before reuse. Its image-adaptive idea is relevant, but it does not itself supply trip reference understanding or local corrections. |
| [RapidRAW](https://github.com/CyberTimon/RapidRAW) | Rust/Tauri, RAW, GPU and non-destructive editing are useful architectural references. It is AGPL-3.0; no RapidRAW source is copied. Its CLI export path is a design reference for an isolated renderer adapter. |
| [rawler / DNGLab](https://github.com/dnglab/dnglab) | Rust RAW parsing and metadata candidate. The repository states LGPL-2.1 and warns that the rawler API is unstable and malformed inputs can panic or abort. Test camera coverage and process isolation before choosing it for RAW export. |
| [Lensfun](https://github.com/lensfun/lensfun) | Lens correction library for distortion, chromatic aberration and vignetting. Its [README](https://github.com/lensfun/lensfun/blob/master/README.md) states LGPL-3.0 for libraries and CC BY-SA 3.0 for lens data. Defer until a RAW/high-quality rendering path exists. |

## ON1 Photo RAW

The installed Mac has ON1 Photo RAW 2026, but this milestone does not modify its files. ON1's [current user guide](https://www.on1.com/bookshelf/on1-photo-raw-2026-user-guide/) covers non-destructive edits and batch workflows. ON1 also documents [LUT import and use](https://www.on1.com/videos/how-to-use-luts/). An [ON1 explanation of sidecars](https://www.on1.com/blog/in-sync-with-on1-photo-raw/) says the app can save edit instructions beside photos; that article is old and does not specify a supported write API or stable format for the installed version.

| Question from the brief | Finding |
| --- | --- |
| Write ON1 sidecars or presets programmatically? | Unverified. Sidecars and presets exist in ON1 workflows, but a stable schema and safe external write contract have not been established. Do not generate them yet. |
| Batch apply/export? | Supported as an ON1 user workflow according to the user guide and [feature list](https://www.on1.com/products/photo-studio/features/). Per-image automated parameter control still needs a supported integration path. |
| Watched folders? | No supported edit-trigger mechanism verified. |
| LUTs? | Import/use is documented; per-image application and iterative export automation still need testing. |
| Public API or CLI? | None verified in the material reviewed. Treat UI automation as a last resort. |

The installed version is ON1 Photo RAW 2026.5 (bundle version 20.5.0). Its macOS app declares support for opening folders and common RAW formats, but its bundle has no AppleScript scripting dictionary. ON1 documents importing and applying [LUTs](https://www.on1.com/videos/how-to-use-luts/) and [batch workflows](https://www.on1.com/bookshelf/on1-photo-raw-2026-user-guide/). ON1 describes watched [Folder Actions](https://www.on1.com/blog/introducing-on1-photo-raw-2027-a-new-raw-processing-engine-improved-nonoise-ai-an-ai-culling-assistant-and-more/) as new in the forthcoming 2027 release, so they are unavailable in the installed 2026 version.

The first bridge uses these supported boundaries: copy only selected photos into a disposable ON1 workspace, include references and per-photo `.cube` looks, launch ON1, and reveal the workspace in Finder. The macOS folder-open request launched ON1 in a local test, but ON1 stayed on its Home or previous Browse folder. The user must choose Browse Folder in ON1. This avoids writing undocumented sidecars. The LUT carries global tone and colour changes approximately; the user must apply the matching LUT per photo and export from ON1. The handoff has been checked with synthetic files, but visual equivalence inside ON1 and actual camera RAW workflows still need validation.

For deeper automation, create a disposable copy of a few camera files, save a manual ON1 edit, inspect the resulting sidecar/preset, test batch export, and compare ON1 output against the editor preview. Only use an ON1-specific writer after a reliable, supported contract is established. Avoid testing against the user's original travel photos.
