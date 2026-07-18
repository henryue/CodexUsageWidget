# App icon source geometry

These SVGs reconstruct the user-selected concept as deterministic 1024 × 1024 vector geometry.

## Icon Composer layers

Import in filename order, each on the full 1024 × 1024 canvas:

1. `01-OuterC.svg`
2. `02-InnerC.svg`
3. `03-StatusDot.svg`

The system mask, shadow, specular highlight, translucency, refraction, and other Liquid Glass effects are intentionally absent from the SVG source.

## Appearance fills

| Element | Default | Dark | Mono |
|---|---|---|---|
| Canvas | `#FDF8F4` | `#050F25` | system-appropriate neutral |
| Outer C | `#042249` | `#D6E8FB` | white / strongest tone |
| Inner C | `#026CEF` | `#0296FF` | secondary gray |
| Status dot | `#00DCFF` | `#64D2FF` | white at `82%` opacity |

The canvas hex values above are design-reference colors for the flat QA previews. The production Icon Composer document intentionally uses Apple's adaptive `System Light` and `System Dark` canvas fills instead of baking either background color into a source layer.

The Default status dot remains unchanged. Dark and Mono use Icon Composer fill specializations for the light-blue color and intermediate dot opacity; their geometry is identical to Default.

`Preview-Light.svg`, `Preview-Dark.svg`, and `Preview-Mono.svg` are flat visual QA composites only. They are not Icon Composer input layers. `Variants/Dark` and `Variants/Mono` contain appearance-specific SVG image variants when an exact fill cannot be represented through a Composer color override.

## Geometry

- Optical center: `(512, 512)`
- Outer C: nominal centerline radius `306`, width `100`, lower terminal `+20°`, upper terminal `-37°`; both terminal neighborhoods receive measured inward optical correction.
- Inner C: nominal centerline radius `180`, width `72`, lower terminal `+90°`, upper terminal `-41°`; the upper terminal tapers inward by `7pt`.
- Status dot: center `(784, 454)`, radius `40`

The unequal arc spans are deliberate: the outer C is an original usage-ring motif, while the shorter inner C suggests a second usage window without encoding a live percentage.

Run `node Design/AppIcon/generate_vectors.mjs` to deterministically regenerate every design layer and preview. Add `--sync-composer` to intentionally update the three matching assets inside `App/IconSource/AppIcon.icon` before reopening and saving the document in Icon Composer.
