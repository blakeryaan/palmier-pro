# HoTF Mode D Clip Contract

Non-lossy import/export path for the HoTF Editor. A **Mode D clip job** carries a
full **native editor `Timeline`** that opens losslessly and round-trips back
unchanged — no recipe→timeline mapping, no dropped edits.

This sits beside the existing **Mode C** path (`recipe` → `dialedRecipe()`, a
lossy timing/text/framing dial). The two are distinguished by one field.

## Discriminator

An `editor_jobs` row is a Mode D clip job iff its `recipe` JSON has top-level
`"kind": "clip"`.

- **Mode C** (unchanged): `recipe` has **no** `kind` (or `kind: "modeC"`). Decodes
  as `HoTFRecipe` (`template` / `resolution` / `hookText`).
- **Mode D** (this doc): `recipe.kind == "clip"`. Decodes as `HoTFClipRecipe`.

Detection lives in `HoTFClipRecipe.from(rawRecipe:)`
(`Sources/HoTFEditor/HoTF/HoTFContracts.swift`) and is surfaced on the job as
`HoTFEditorJob.recipeKind` (`.modeC` / `.clip`) and `isClipJob`.

## `editor_jobs` columns

| column | Mode D meaning |
| --- | --- |
| `recipe` (jsonb) | clip recipe — `{ kind:"clip", timeline, fps, width, height }` |
| `media_manifest` (jsonb) | `assetId → { proxyUrl, fullResUrl }` — resolved exactly like Mode C |
| `dialed` (jsonb) | written by the editor on Send for Render — the FULL edited clip recipe (same shape as `recipe`) |
| `status` | `ready` → editor claims to `open` → `approved` on send |
| `name`, `client_slug`, … | unchanged from Mode C |

The render worker reads `dialed` if present, else `recipe` (the editor uses the
same `dialed ?? recipe` precedence via `HoTFEditorJob.workingClipRecipe`).

## Clip recipe shape

```jsonc
{
  "kind": "clip",
  "timeline": { /* native editor Timeline JSON — see below */ },
  "fps":   30,    // Int — must match timeline.fps
  "width": 1080,  // Int — must match timeline.width
  "height":1920   // Int — must match timeline.height
}
```

`timeline` is the editor's **OWN** serialized `Timeline` — byte-for-byte the same
JSON the `.hotf` project package stores at `project.json`, and the same shape
`HeadlessExport.loadProject` consumes. Importing decodes it straight into the
native `Timeline` (`HoTFClipRecipe.decodedTimeline()`), so a producer that emits
matching JSON gets a lossless open.

`fps` / `width` / `height` are a redundant top-level summary for cheap inspection;
the editor trusts `timeline.fps/width/height` on open and re-emits these on
save-back. Keep them in sync with the timeline.

## Native `Timeline` JSON schema

Source of truth: `Sources/HoTFEditor/Models/Timeline.swift`,
`Models/Keyframe.swift`, `Models/TextStyle.swift`. All keys are the Swift property
names (no remapping). Missing keys fall back to the defaults listed — a producer
may omit any field that equals its default.

### `Timeline` (root)

| field | type | default | notes |
| --- | --- | --- | --- |
| `fps` | Int | `30` | |
| `width` | Int | `1920` | canvas px |
| `height` | Int | `1080` | canvas px |
| `settingsConfigured` | Bool | `false` | set `true` for produced jobs |
| `tracks` | `[Track]` | `[]` | render/paint order is array order |

### `Track`

| field | type | default | notes |
| --- | --- | --- | --- |
| `id` | String (UUID) | random UUID | |
| `type` | enum | — **required** | `video` \| `audio` \| `image` \| `text` \| `lottie` |
| `muted` | Bool | `false` | |
| `hidden` | Bool | `false` | |
| `syncLocked` | Bool | `true` | |
| `clips` | `[Clip]` | `[]` | |

(`displayHeight` is view-only and NOT serialized.)

### `Clip`

| field | type | default | notes |
| --- | --- | --- | --- |
| `id` | String (UUID) | random UUID | |
| `mediaRef` | String | — **required** | the `media_manifest` **assetId**. `""` for text clips |
| `mediaType` | `ClipType` | `video` | `video`/`audio`/`image`/`text`/`lottie` |
| `sourceClipType` | `ClipType` | `video` | original type, for color-coding |
| `startFrame` | Int | — **required** | timeline frame the clip starts on |
| `durationFrames` | Int | — **required** | visible length in frames |
| `trimStartFrame` | Int | `0` | source frames trimmed off the head |
| `trimEndFrame` | Int | `0` | source frames trimmed off the tail |
| `speed` | Double | `1.0` | playback rate |
| `volume` | Double | `1.0` | linear gain (outer) |
| `fadeInFrames` | Int | `0` | |
| `fadeOutFrames` | Int | `0` | |
| `fadeInInterpolation` | enum | `linear` | `linear` \| `hold` \| `smooth` |
| `fadeOutInterpolation` | enum | `linear` | |
| `opacity` | Double | `1.0` | |
| `transform` | `Transform` | identity | see below |
| `crop` | `Crop` | identity | normalized edge insets |
| `linkGroupId` | String? | nil | links a/v clips that move together |
| `captionGroupId` | String? | nil | |
| `textContent` | String? | nil | **text clips**: the rendered string |
| `textStyle` | `TextStyle`? | nil | **text clips**: see below |
| `opacityTrack` | `KeyframeTrack<Double>`? | nil | animation; omit when none |
| `positionTrack` | `KeyframeTrack<AnimPair>`? | nil | normalized topLeft (x,y) |
| `scaleTrack` | `KeyframeTrack<AnimPair>`? | nil | (width,height) |
| `rotationTrack` | `KeyframeTrack<Double>`? | nil | degrees |
| `cropTrack` | `KeyframeTrack<Crop>`? | nil | |
| `volumeTrack` | `KeyframeTrack<Double>`? | nil | dB envelope |

Keyframe `frame` values are **clip-relative** (offset from `startFrame`,
`0…durationFrames`), not absolute timeline frames.

### `Transform`

`{ "centerX":Double, "centerY":Double, "width":Double, "height":Double, "rotation":Double, "flipHorizontal":Bool, "flipVertical":Bool }`
— defaults `centerX/Y=0.5`, `width/height=1`, `rotation=0`, flips `false`. All
positions/sizes are normalized to the canvas (1.0 = full canvas dimension).
`rotation` is degrees, positive = clockwise. (Legacy `x`/`y` keys are accepted on
decode but never emitted — do not produce them.)

### `Crop`

`{ "left":Double, "top":Double, "right":Double, "bottom":Double }` — normalized
(0–1) source edge insets, default all `0` (identity).

### `KeyframeTrack<V>`

`{ "keyframes": [ { "frame":Int, "value":<V>, "interpolationOut":enum } ] }`
where `interpolationOut` is `linear` \| `hold` \| `smooth` (default `smooth`),
and `<V>` is:
- `Double` for opacity/rotation/volume tracks,
- `AnimPair` = `{ "a":Double, "b":Double }` for position (a=x,b=y) and scale (a=width,b=height),
- `Crop` for crop tracks.

### `TextStyle` (text clips)

`{ "fontName":String="Helvetica-Bold", "fontSize":Double=96, "fontScale":Double=1.0,
"color":RGBA, "alignment":"left"|"center"|"right"="center", "shadow":Shadow,
"background":Fill, "border":Fill, "strokeWidth":Double=0, "strokeColor":RGBA }`

- `RGBA` = `{ "r":Double, "g":Double, "b":Double, "a":Double }` (0–1, default white opaque).
- `Shadow` = `{ "enabled":Bool=true, "color":RGBA(0,0,0,0.6), "offsetX":Double=0, "offsetY":Double=-2, "blur":Double=6 }`.
- `Fill` = `{ "enabled":Bool=false, "color":RGBA }`.

## Save-back (Send for Render)

On Send for Render for a clip job (`HoTFJobsView.approve` → `isClipJob`):

1. `HoTFJobImporter.persist(doc)` flushes the local `.hotf`.
2. `HoTFJobImporter.dialedClipRecipe(from:)` serializes the **live edited**
   `editor.timeline` (`JSONEncoder().encode(timeline)`) into a `HoTFClipRecipe`.
3. `HoTFMailbox.saveDialedClip` PATCHes `editor_jobs.dialed` to
   `{ kind:"clip", timeline:<edited native timeline>, fps, width, height }` and
   sets `status = "approved"`.

This is byte-lossless and does **not** route through `dialedRecipe()`.

## Minimal example `recipe`

A clip job with two video clips (one with a scale keyframe + trim + speed), a
text overlay, and a voiceover audio clip. The `timeline` value is exactly what
`JSONEncoder` emits for the native `Timeline`; a TS producer should match it
(field presence beyond non-defaults is optional).

```json
{
  "kind": "clip",
  "fps": 30,
  "width": 1080,
  "height": 1920,
  "timeline": {
    "fps": 30,
    "width": 1080,
    "height": 1920,
    "settingsConfigured": true,
    "tracks": [
      {
        "id": "vid",
        "type": "video",
        "muted": false,
        "hidden": false,
        "syncLocked": true,
        "clips": [
          {
            "id": "clip-a",
            "mediaRef": "asset-a",
            "mediaType": "video",
            "sourceClipType": "video",
            "startFrame": 0,
            "durationFrames": 60,
            "trimStartFrame": 15,
            "trimEndFrame": 0,
            "speed": 1.5,
            "volume": 1,
            "fadeInFrames": 0,
            "fadeOutFrames": 0,
            "fadeInInterpolation": "linear",
            "fadeOutInterpolation": "linear",
            "opacity": 1,
            "transform": { "centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false },
            "crop": { "left": 0, "top": 0, "right": 0, "bottom": 0 },
            "scaleTrack": {
              "keyframes": [
                { "frame": 0,  "value": { "a": 1,   "b": 1   }, "interpolationOut": "smooth" },
                { "frame": 30, "value": { "a": 1.2, "b": 1.2 }, "interpolationOut": "smooth" }
              ]
            }
          },
          {
            "id": "clip-b",
            "mediaRef": "asset-b",
            "mediaType": "video",
            "sourceClipType": "video",
            "startFrame": 60,
            "durationFrames": 45,
            "trimStartFrame": 0,
            "trimEndFrame": 0,
            "speed": 1,
            "volume": 1,
            "opacity": 1,
            "transform": { "centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false },
            "crop": { "left": 0, "top": 0, "right": 0, "bottom": 0 }
          }
        ]
      },
      {
        "id": "txt",
        "type": "text",
        "muted": false,
        "hidden": false,
        "syncLocked": true,
        "clips": [
          {
            "id": "clip-t",
            "mediaRef": "",
            "mediaType": "text",
            "sourceClipType": "text",
            "startFrame": 0,
            "durationFrames": 40,
            "speed": 1,
            "volume": 1,
            "opacity": 1,
            "textContent": "I quit my job at 18",
            "transform": { "centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false },
            "crop": { "left": 0, "top": 0, "right": 0, "bottom": 0 }
          }
        ]
      },
      {
        "id": "aud",
        "type": "audio",
        "muted": false,
        "hidden": false,
        "syncLocked": true,
        "clips": [
          {
            "id": "clip-v",
            "mediaRef": "vo-1",
            "mediaType": "audio",
            "sourceClipType": "audio",
            "startFrame": 0,
            "durationFrames": 105,
            "speed": 1,
            "volume": 1,
            "opacity": 1,
            "transform": { "centerX": 0.5, "centerY": 0.5, "width": 1, "height": 1, "rotation": 0, "flipHorizontal": false, "flipVertical": false },
            "crop": { "left": 0, "top": 0, "right": 0, "bottom": 0 }
          }
        ]
      }
    ]
  }
}
```

Matching `media_manifest`:

```json
{
  "asset-a": { "proxyUrl": "https://drive.google.com/file/d/AAA/view", "fullResUrl": "https://.../a.mp4" },
  "asset-b": { "proxyUrl": "https://.../b-proxy.mp4",                    "fullResUrl": "https://.../b.mp4" },
  "vo-1":    { "proxyUrl": "https://.../vo-proxy.mp3",                   "fullResUrl": "https://.../vo.mp3" }
}
```

Every distinct non-empty `clip.mediaRef` must have a `media_manifest` entry. The
editor downloads each `proxyUrl` (falling back to `fullResUrl`) into the project,
rewriting Google Drive `/file/d/<id>/view` and `open?id=` links to the
direct-download endpoint automatically.
