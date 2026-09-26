# ON1 Editor

## Project goal

Build a local-first macOS application that helps turn a folder of travel photos into one coherent visual body of work.

The app should not apply one preset blindly to every image.

Instead, it should:

1. Analyse each image.
2. Understand the overall visual style of the trip.
3. Determine what each individual image needs in order to fit that style.
4. Apply or generate image-specific edits.
5. Evaluate consistency across the collection.
6. Allow the user to review and correct results.
7. Learn from those corrections over time.

The first user is me. Do not design this initially as a generic commercial photo editor.

The priority is usefulness for one photographer with relatively modest trip collections, generally tens to a few hundred photos rather than massive professional archives.

---

# Core product principle

The system should learn a visual language, not merely save presets.

A preset says:

"Apply these exact settings."

ON1 Editor should instead reason approximately like:

"This image is warmer than the rest of the trip, the highlights are too harsh, the foliage is too saturated, and the shadows are too cyan relative to the target style."

It should then determine the appropriate corrections for that image.

Different images may receive very different edits while still belonging to the same coherent visual style.

Examples:

- daylight street photo
- beach
- landscape
- restaurant interior
- tungsten interior
- portrait
- food
- night street
- neon
- architecture
- sunset

These scenes should not receive identical edits.

---

# Product workflow

Target workflow:

1. User selects a trip folder.
2. App discovers supported image files.
3. App creates lightweight local previews.
4. App reads basic EXIF and metadata.
5. App analyses image content, technical quality, colour, lighting and scene characteristics.
6. App groups related images where useful.
7. User chooses reference images or approved edits that represent the desired look.
8. App creates a trip-level style profile.
9. App generates an individual edit plan for each image.
10. App applies those edits through the selected rendering path.
11. App evaluates whether the rendered result matches the trip style.
12. Outliers or low-confidence edits are surfaced for review.
13. User corrections are stored as preference data.
14. Future edits gradually become better aligned with the user's taste.

---

# Important architectural decision

Keep the system modular.

Do not tightly couple image analysis, style reasoning or edit planning to ON1 Photo RAW.

ON1 may initially be useful as the renderer/editor layer, but the architecture must allow a native renderer later.

The core product is the analysis + style + edit planning system.

---

# Open-source reuse strategy

Before implementing a subsystem from scratch, check whether a suitable existing open-source project can be reused or adapted.

Prefer reuse where:

- the license permits it
- the dependency is maintained
- the integration cost is lower than rebuilding
- the component fits the local-first architecture

Do not rebuild commodity infrastructure simply for the sake of owning every line of code.

## Priority project: Facet

Investigate Facet first.

Facet is highly relevant because it already contains local photo-analysis functionality such as:

- aesthetic scoring
- composition scoring
- sharpness analysis
- eye sharpness
- face quality
- exposure analysis
- colour analysis
- subject saliency
- dynamic-range analysis
- burst detection
- blink detection
- duplicate / near-duplicate grouping
- scene categorisation
- semantic search
- preference learning from A/B choices

Facet is MIT licensed.

Leverage as much of its implementation as is technically sensible.

Do not merely copy the idea if we can reuse proven code safely.

First determine:

1. Which Facet modules can be imported directly.
2. Which should be adapted.
3. Which should remain external dependencies.
4. Which assumptions in Facet do not fit our product.

Document those findings.

---

# Other projects to investigate

## Photo Sorter

Useful reference or reusable implementation for:

- CLIP embeddings
- image similarity
- clustering
- duplicate detection
- aesthetic scoring
- cached embeddings
- Apple Silicon acceleration
- local image analysis

MIT licensed.

Reuse/adapt useful components where sensible.

---

## AceTone

Investigate as a possible learned colour-grading component.

Relevant for:

- conditional image colour grading
- learned colour transformations
- LUT generation
- visual-language transfer

Do not assume it will be the final solution.

Build a small prototype before committing the architecture around it.

---

## LUT generation projects

Investigate existing text-to-LUT and image-to-LUT projects where licensing permits.

Potential uses:

- trip-level colour baseline
- reference-image-derived grading
- stylistic colour transformation

LUTs should not become the entire editing system.

They may form the global colour treatment, while image-specific corrections are handled separately.

---

## RapidRAW

Use RapidRAW primarily as an architectural reference.

Interesting areas:

- Rust backend
- Tauri desktop architecture
- RAW handling
- GPU rendering
- masks
- non-destructive sidecar editing
- batch workflows
- preview generation
- command-line rendering

RapidRAW is AGPL licensed.

Do not copy AGPL code into this project unless explicitly approved.

Study concepts and architecture only unless licensing has been reviewed.

---

## rawler

Investigate for RAW decoding and metadata handling.

---

## Lensfun

Investigate for lens correction and lens-profile data.

---

# Proposed architecture

Start with these conceptual modules.

## 1. Library

Responsibilities:

- folder selection
- supported image discovery
- file indexing
- metadata
- persistent local records

Avoid building a massive Digital Asset Management system.

This is a trip-oriented application.

---

## 2. Preview pipeline

Responsibilities:

- generate lightweight previews
- cache previews
- support fast image browsing
- avoid repeatedly decoding large RAW files

---

## 3. Image analysis

Use Facet and other existing components where practical.

Potential outputs:

- exposure
- white balance characteristics
- contrast
- dynamic range
- clipping
- sharpness
- faces
- eyes
- subjects
- saliency
- scene category
- lighting type
- dominant colours
- colour distribution
- saturation
- semantic embedding
- aesthetic score
- duplicate / burst relationships

Use structured machine-readable outputs.

---

## 4. Trip structure

The app should understand that a folder may represent a trip rather than an unordered photo archive.

Potential grouping signals:

- EXIF timestamp
- capture sequence
- scene similarity
- visual similarity
- location metadata if available

Possible hierarchy:

Trip
- Day
- Location or scene
- Sequence
- Individual image

Do not over-engineer this initially.

---

## 5. Style engine

The style engine represents the desired visual language.

A style profile may eventually describe:

- preferred exposure range
- white balance character
- contrast
- black point
- highlight behaviour
- shadow behaviour
- tone curve
- saturation
- skin treatment
- foliage treatment
- blue treatment
- shadow colour
- highlight colour
- grain
- local contrast
- night-scene behaviour

The profile should describe visual intent rather than only fixed slider values.

---

## 6. Reference images

The user should be able to define the look using:

- selected images from the current trip
- previous edited trips
- manually edited anchor images
- reference JPEGs

The system should infer a style target from these.

---

## 7. Edit planner

This is a key differentiating component.

Input:

- image analysis
- trip style profile
- image category
- reference images
- previous user preferences

Output:

structured edit instructions.

Example:

image_id: IMG_1043

scene:
night_street

analysis:
exposure: underexposed
white_balance: warm
highlights: neon_clipping
skin_detected: true
shadow_cast: cyan

edit_plan:
exposure: +0.35
temperature: -250K
highlights: -28
shadows: +8
black_point: -5
orange_saturation: -6
blue_saturation: +4
skin_luminance: +0.15EV

confidence:
0.83

The exact parameter system will depend on the renderer.

Keep the conceptual edit plan renderer-independent.

---

## 8. Global colour treatment

Investigate whether LUT-based or learned grading can provide the base visual language.

Potential architecture:

Reference images
→ style representation
→ global colour transform / LUT
→ image-specific corrections
→ local masking
→ final render

Do not rely on a single LUT to solve all images.

---

## 9. Local corrections and masks

Eventually support adjustments such as:

- subject
- face / skin
- sky
- foreground
- background
- depth-based regions

Investigate reusable segmentation and masking models before creating our own.

---

## 10. Renderer adapter

Create an abstraction layer.

Example conceptual interface:

render(image, edit_plan)

Possible implementations:

- ON1 renderer adapter
- native renderer
- experimental LUT renderer

Do not let upstream systems depend directly on ON1-specific fields.

---

# ON1 Photo RAW integration

Investigate ON1 before relying on it.

Determine:

1. Whether ON1 edit metadata or sidecar files can be safely generated or manipulated.
2. Whether preset files are writable and sufficiently expressive.
3. Whether ON1 can apply edits through batch workflows.
4. Whether watched folders can help automate processing.
5. Whether LUTs can be integrated.
6. Whether UI automation would be required.
7. Whether ON1 preview/export workflows can support iterative evaluation.

Do not assume a public API exists.

Do not build fragile UI automation unless all cleaner options fail.

Document discoveries before implementing deep ON1 integration.

---

# Native rendering possibility

Keep open the possibility that ON1 eventually becomes optional.

A future native rendering pipeline could include:

- RAW decoding
- exposure
- white balance
- curves
- HSL
- colour grading
- local masks
- lens correction
- sharpening
- noise reduction
- grain

Do not attempt to build all of this in the first milestone.

---

# Consistency evaluator

After rendering, the system should compare outputs against the trip's visual target.

Potential checks:

- exposure consistency
- white balance consistency
- colour distribution
- skin luminance
- green treatment
- blues
- highlight behaviour
- shadow colour
- contrast
- semantic/visual similarity to references

Output:

- pass
- uncertain
- outlier

Also produce a confidence score.

The user should review uncertain or outlier images rather than every image.

---

# Preference learning

Record user corrections.

Examples:

AI:
shadows +20

User:
shadows +8

Or:

AI chooses edit A.

User prefers edit B.

The system should gradually learn recurring preferences.

Potential learned tendencies:

- prefers restrained shadow recovery
- dislikes orange skin
- prefers slightly muted foliage
- accepts deeper blacks in night scenes
- prefers restrained HDR appearance
- keeps skies relatively natural

Do not hard-code these assumptions.

Learn them from behaviour.

---

# Culling

Culling is useful but secondary.

Since the expected libraries are not enormous, do not make bulk culling the first priority.

Still leverage Facet functionality where easily available.

Useful features:

- duplicate grouping
- burst grouping
- blink detection
- sharpness ranking
- face quality