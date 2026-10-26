# RiveBox

An original 3D game-console dashboard built with the [Rive CLI](https://rive.app/docs/cli/overview): a glass
core, floating menu panels, energy tubes, cables and particle fields. Every 3D surface is a live Rive artboard
(state machines, data binding, layouts, focus) used as a texture, so the menus you click and scroll in 3D are
ordinary Rive UI.

Try it live: <https://rivebox-pmtq43.uat.rive.to>

The whole project is plain source files: RML markup for the artboards (`scene.rml`), AnimaScript for the 3D
world, and WGSL for the shaders. Edit `scene.rml` by hand, or push it to the Rive Editor, let designers work on
it there, and pull their changes back.

## Run it

1. Install the Rive CLI:

   ```bash
   curl -fsSL https://releases.rive.app/cli/install.sh | sh
   ```

2. From this folder:

   ```bash
   rive . --aot
   ```

   This builds `build/rivebox.riv` and opens the preview window. `--aot` compiles the scripts ahead of time
   (faster at runtime). `rive . --bench=240` times frames headless.

Tested with Rive CLI 1.8.0 and 1.9 previews.

## Controls

| Input | Action |
|---|---|
| Enter / Space / click | start (title screen) |
| ↑ ↓ / W S / d-pad | move focus |
| ← → | switch section while inside one |
| Enter / Space / pad confirm | open section · play game · toggle switch · edit player name |
| Esc / Backspace / pad back | back to hub |
| Mouse | click any 3D menu panel, list row or switch (ray-cast to artboard UVs) |
| Wheel / trackpad | scroll the list on the screen under the pointer |
| Settings › Player name | type a new player name (real TextInput, two-way bound) |

## Embedding

On a web page, load the `.riv` with `@rive-app/webgl2` and `enableGPUCanvas: true` (the 3D is a GPU canvas),
leave `useOffscreenRenderer` off, and set `autoBind: true` so the state machine gets its view model. Keys
reach the scene once the canvas has focus (a click).

## What lives where

- `scene.rml`: every artboard, component, view model, list, state machine, animation, focus rule and listener.
  It is the hand-owned source of truth: edit it in place (or in the Rive Editor).
  - Hub menu and case art.
  - Games, Music, Memory and Settings screens.
  - Game and track rows, used as ArtboardComponentList items.
  - Boot, launch and section transitions.
- `gen.py`: the scaffold generator that first wrote `scene.rml`. Kept for reference; running it would
  overwrite edits made since.
- `brand.rml`: Rive brand marks, icons and the animated brandmark. `logo.rml`: the Rive wordmark.
- `world.as`: the 3D world (the `World 3D` ScriptedLayout): camera, springs, meshes and particles. It
  instances each artboard against the root view model, draws it to a GPU canvas, maps it onto a curved
  surface, and ray-casts pointer events back into it. The geometry is built in time-budgeted slices over the
  first frames and the frames recorded meanwhile are replayed, so the scene lands in the same state as a
  one-shot build without tripping the 200 ms script watchdog. The 3D renders at most 2560x1440 pixels and
  lowers its resolution in steps when frames run slow.
- `geo3.as`: mesh builders, a library module imported by `world.as`.
- `decrypt.as`: the `Decrypt` scripted data converter. Every UI string decrypts in per glyph on arrival and
  encrypts out on the way back to the start screen.
- `fieldguard.as`: the `Field Guard` layout around the player-name TextInput. Enter / Esc / Tab fire
  `fieldDone`, which hands focus back to the dashboard.
- `surf.wgsl`: the surface material (texture with rim and scanlines, energy tube, glass, grid). `post.wgsl`
  (bloom, depth of field, composite), `motion.wgsl` (motion blur), `part.wgsl` (particles), `taa.wgsl`.

## Credits

- **Fonts**, all under the [SIL Open Font License 1.1](https://openfontlicense.org) (license texts in
  `licenses/`):
  [Inter](https://github.com/rsms/inter) by The Inter Project Authors (`fonts/Inter.ttf`),
  [Orbitron](https://github.com/theleagueof/orbitron) by The Orbitron Project Authors (`fonts/Orbitron.ttf`),
  [Iosevka](https://github.com/be5invis/Iosevka) by Renzhi Li (`fonts/Iosevka-*.ttf`, shipped as glyph subsets).
- All game, track and device names are fictitious, except Rocket Squadron, a Rive demo game.

## License

The code is released under the [MIT License](LICENSE). The fonts keep their SIL OFL 1.1 license. The Rive name
and logo are trademarks of Rive Inc.
