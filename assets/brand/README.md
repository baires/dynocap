# DynoCap logo

An open capsule holds an isometric terminal cube: a portable environment inside a protective shell. Rounded shell contours, an amber prompt, and a bold wordmark draw on the supplied visual reference.

## Files

- `dynocap-logo-{dark,light,mono}.svg`: stacked logo with outlined lettering.
- `dynocap-mark-{dark,light,mono}.svg`: capsule symbol without lettering.
- `dynocap-mark-small.svg`: simplified symbol for small placements.
- `dynocap-logo-{dark,light}.png`: transparent 1600 px wide exports.
- `dynocap-mark-dark.png`: transparent 512 px symbol.
- `dynocap-preview-{dark,light}.{svg,png}`: logo on its intended background.

SVGs have no external images or font dependencies. Logo and mark canvases are transparent; cube faces use the intended background color to preserve opaque geometry. Use the dark assets on `#0B0C0E`, light assets on `#FAF8F3`, and mono assets on white.

Dark colors: ivory `#F5F2EB`, amber `#FFB21A`, background `#0B0C0E`.
Light colors: ink `#16191D`, amber `#D58A00`, background `#FAF8F3`.

## Rebuild

`build.py` requires Python 3, `fonttools`, and the macOS system Avenir Next font. It converts the wordmark to vector paths. The exported SVGs work independently of these build dependencies.

```sh
python3 assets/brand/build.py
rsvg-convert -o assets/brand/dynocap-preview-dark.png assets/brand/dynocap-preview-dark.svg
rsvg-convert -o assets/brand/dynocap-preview-light.png assets/brand/dynocap-preview-light.svg
rsvg-convert -w 1600 -o assets/brand/dynocap-logo-dark.png assets/brand/dynocap-logo-dark.svg
rsvg-convert -w 1600 -o assets/brand/dynocap-logo-light.png assets/brand/dynocap-logo-light.svg
rsvg-convert -w 512 -o assets/brand/dynocap-mark-dark.png assets/brand/dynocap-mark-dark.svg
```

Validation: rendered and visually inspected both background previews and the simplified small symbol; checked all SVGs for valid XML and self-contained paths. No application behavior changed.
