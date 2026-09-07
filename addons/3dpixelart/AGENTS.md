# AGENTS.md — addons/3dpixelart

## What this is

Godot 4.7 addon: an addon that takes inspiration from bunch of public shit
that renders 3D objects in a pixel-art style — per-object macro-pixels,
outlines, no pixel creep, full-res lights/shadows, palette-LUT grading.
Pipeline is implemented and **working**; user docs are in `README.md`.
The hard-won Godot 4.7.1 rendering facts are in the "Architecture
invariants" section below and in the `godot-compositor-testing` skill —
read them before touching the render pipeline. The demo scene is
`demo/demo.tscn` (project root).

## File layout

- `plugin.gd` / `plugin.cfg` — EditorPlugin; all runtime types use
  `class_name`, so the plugin itself does nothing.
- `nodes/pixel_art_pipeline_3d.gd` (`PixelArtPipeline3D`) — pipeline driver, one per scene.
  Creates the metadata SubViewport + camera, owns the shared RD textures,
  attaches the compositor effects, feeds registered materials. Runtime only.
- `nodes/pixel_art_object_3d.gd` (`PixelArtObject3D`) — per-object config
  (pixel size, outline id/color); sets instance uniforms, auto-adds the
  metadata render layer and assigns the material. Its `snap_*` exports are
  intentionally no-ops.
- `nodes/pixel_art_camera_snap.gd` (`PixelArtCameraSnap`) — ortho texel snap
  via camera `h_offset`/`v_offset` (denovodavid port). No transform mutation.
- `core/pixel_palette.gd` (`PixelPalette`, `@tool`) — bakes 256×256 palette
  LUT PNGs via an inspector button. `ColorMethod.NEAREST_LAB` matches in CIE
  Lab (CIE76); bake-time only, LUT format unchanged.
- `core/pixel_dither_pattern.gd` (`PixelDitherPattern`) — 4×4 ordered dither
  matrix (Bayer default).
- `compositor/` — `PixelArtOutlinePass` (PRE_OPAQUE, main),
  `PixelArtGodRayPass` (POST_SKY, main, additive god rays through the cloud
  layer), `PixelArtMacroPixelPass` (POST_SKY, main), and the
  metadata export effect (POST_SKY, SubViewport), plus `PixelArtSharedBuffers`
  (shared RIDs between viewports).
- `shaders/pixel_art_object.gdshader` — one spatial shader serving both
  cameras; branches on `float(CAMERA_VISIBLE_LAYERS) == metadata_cull_mask`.
  Also hosts sharp-bilinear texture sampling (`use_sharp_bilinear`) and the
  per-material cloud-shadow code (uniforms pushed by the pipeline).
- `shaders/*.glsl` — compute passes: `copy_color`, `outline_pass`,
  `anchor_map`, `apply_anchor_map`, `export_metadata`, `god_rays`.
- `demo/water.gdshader` — Pixel Art Oceans layers 1–5 example (transparent;
  renders after the pixelization passes, so not itself pixelated).

## Architecture invariants (do not redesign)

- **One shader, two cameras.** The metadata camera culls only layer 20
  (`1 << 19`); the material branches on `CAMERA_VISIBLE_LAYERS`. Same
  instances render in both viewports — no mirrored geometry.
- **Never write ALPHA in the metadata branch.** Writing ALPHA sorts the
  material into the transparent pass, which renders after the POST_SKY
  compositor effects (the original "all zeros" bug). Pixel size + outline id
  are packed into G instead: `G = (id + pixelSize * 256) / 4096`, white
  background decodes to size 16 = "not pixelized". Metadata color texture is
  `R16G16B16A16_UNORM` (11 payload bits don't survive 8-bit).
- **Never snap/restore transforms around rendering.**
  `RenderingServer.frame_pre_draw/post_draw` do not bracket GPU rendering
  with a threaded rendering server — the two viewports see different
  transforms (measured 1px anchor-grid phase mismatch). Use persistent
  projection offsets (`PixelArtCameraSnap`) instead. Object render snapping
  is deliberately not ported for the same reason.
- **Reversed-Z**: near = 1.0, far = 0.0, "nearest" = largest raw depth. The
  pixelization map kernel depends on this.
- The engine color layer (`RGBA16F`) cannot be a `texture_copy` source —
  copy it via compute (`copy_color.glsl`).

## Gotchas

- RenderingDevice is not main-thread-safe: create/free RD textures via
  `RenderingServer.call_on_render_thread(...)` (see
  `PixelArtPipeline3D._create_textures_rt`). On viewport resize the shared
  RIDs in `PixelArtSharedBuffers` are invalidated BEFORE the old textures are
  freed, so compositor passes early-return instead of building uniform sets
  with just-freed RIDs ("Texture (binding: N) is not a valid texture" spam) —
  keep that ordering.
- **The god-ray pass must precede the macro-pixel pass in the compositor
  effects array** — same-callback-type (POST_SKY) effects run in array order,
  and the rays must be in the color layer before `copy_color` so they get
  pixelated. If that ordering ever breaks (rays visible un-pixelated in a
  capture), dispatch the ray compute inside
  `PixelArtMacroPixelPass._render_callback` between the copy and apply
  dispatches instead.
- **The pipeline pushes cloud uniforms to registered materials** (on export
  change and on `register_material`) and pushes `cloud_sun_dir` to materials
  + the god-ray pass every frame in `_process` when clouds are enabled. Keep
  these pushes in sync when adding cloud uniforms. Non-pixelized materials
  (terrain, water) register via `register_cloud_material` (the
  `_cloud_materials` list) to receive ONLY the cloud uniforms — their shaders
  must implement the coverage themselves under the same uniform names
  (`mst_terrain.gdshaderinc` and the game's `water.gdshader` are the
  reference implementations).
- **Cloud-shadow coverage is the fraction of sun blocked** (0 = clear, 1 =
  overcast): `smoothstep(threshold - softness, threshold, n)` over the raw
  noise, quantized into `cloud_shadow_levels` when
  `cloud_shadow_banding_enabled` (hard contour rings vs smooth penumbra).
  Materials darken by `1 - coverage * cloud_shadow_strength`. (The pre-fix
  code did `mix(1.0, coverage, strength)` on a binary step — that darkened
  the cloud GAPS, inverted from the god-ray/sky convention.) `cloud_bands`
  now feeds only the sky sheet / god-ray gap quantization.
- **Editing a `.glsl` compute shader requires a reimport** or stale SPIR-V is
  used. `.gdshader` changes are picked up on game start.
- Requires Forward+ or Mobile; MSAA off; `scaling_3d_scale` 1.0.
- `PixelArtPipeline3D` must see the camera before `_setup()`; it retries lazily in
  `_process` — keep that.

## Testing

Use the `godot-compositor-testing` skill. Binary:
`Godot/Godot-stable_mono_win64_console.exe` (4.7.1 mono, Forward+).

- Parse/import check: `godot --headless --editor --quit --path code_examples/3dpixelart`
- Run demo + auto-screenshot: `cd code_examples/3dpixelart && godot --path . -- --capture`
  (writes `demo/screenshot.png` + metadata debug dumps, quits at frame 120);
  `--debug-view=N` selects the pixelization debug view (1=map, 2=metadata,
  3=metadata depth). `--plain` skips the showcase content (LUT grading,
  clouds/god rays, textured box, pond) and renders the original baseline
  scene — use it as the pixel-creep/outline regression capture.

Verify pixelization visually via the screenshot; `debug_view = 2` shows the
packed metadata buffer.

## Known loose ends

- `PixelArtPipeline3D` syncs the metadata camera in `_process` at default
  process priority 0 — if something updates the main camera later in the frame
  (e.g. a camera host at process_priority 300), the metadata render runs one
  frame behind and moving objects dissolve into their anchor-dot grid. Raise
  the pipeline node's `process_priority` above whatever drives the camera.
- Transparent pixelized objects composite against un-pixelated depth
  (pixelated depth write-back not ported). Corollary: pixelized objects write
  depth only at anchor fragments, so ANY transparent surface between the
  camera and a pixelized object draws over it (the object "dissolves" into
  anchor dots) — keep such surfaces opaque/alpha-scissor.
- `save_shared_textures_debug` depth row-length guard is approximate.
