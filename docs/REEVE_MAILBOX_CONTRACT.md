# Editor ↔ Reeve — Supabase mailbox contract

Palmier Pro (this editor) and Reeve (Trial Reel Engine) integrate through ONE Supabase table: `editor_jobs` (project `xxtuqjtwspjcbwvqdfof`, migration applied 2026-06-20). No machine talks to another directly — each reads/writes the row. This is the "mailbox" from the Video Editor scope.

## Table: `editor_jobs`
| column | meaning |
| --- | --- |
| `id` uuid | job id |
| `client_id` / `client_slug` | which client (workspace slug denormalised for the editor) |
| `name` | human label |
| `status` | `ready → open → approved → rendering → done` (`failed` on error) |
| `recipe` jsonb | Mode C `{ template: FormatTemplate, resolution: SlotResolution, hookText }` — see `trial-reel-engine/src/ModeC/types.ts` |
| `media_manifest` jsonb | `assetId → { proxyUrl, fullResUrl }`. Editor pulls `proxyUrl`; render laptop pulls `fullResUrl`. Same id, different file. |
| `dialed` jsonb | the editor's saved-back recipe (timing/text/framing/speed overrides) |
| `output_url` | Frame.io / Drive link after render |
| `notion_render_page_id` | bridge to the existing Mode C Render Queue row (Notion `RenderRow`) |
| `claimed_by` | which machine has it open |

RLS is on with no policies = service-role only (editor + Reeve use the service key; clients never see the mailbox).

## Lifecycle (who does what)
1. **Reeve writes** (`status='ready'`): when a Mode C recipe wants a human pass, insert `{client_id, client_slug, name, recipe, media_manifest(proxies), notion_render_page_id, status:'ready'}`.
2. **Editor (Mac) claims** (`status='open'`, `claimed_by`): poll `ready` for this machine's clients → import `recipe.template.segments` as an editable Timeline (mapping below).
3. **Editor saves** (`status='approved'`, writes `dialed`): the human dials timing/text/framing → serialize the dialed timeline back into `dialed`.
4. **Render worker (laptop)** (`approved → rendering → done`): resolve `fullResUrl` from `media_manifest` → Remotion render (`ModeCRenderProps` from the dialed recipe) → upload Frame.io → set `output_url`, `status='done'`, sync the Notion render row (the `frame-link` skill).

## FormatTemplate ↔ editor Timeline mapping (T3 — the editor work)
- `FormatTemplate.segments[]` → Timeline clips. Each `Segment {id, t0, t1, media, framing, text, speed}` → a clip: in/out = `t0/t1`; media resolved via `SlotResolution.assetRefs`/`brollSlots` + `media_manifest`; `TextOverlay` → editor `TextStyle`/`TextLayout`; `SegmentFraming.fit/objectPosition` → editor transform; `speed`.
- `AudioPlan` → audio track (`voiceover_slot`/`music_slot` via `SlotResolution.audioSlots`).
- `hookText` → the `{{hook}}` literal.
- **Save-back:** serialize dialed timeline → `dialed` recipe (segment timings/text/framing/speed). Richer edits Remotion can't represent (motion/keyframes) are dropped — the "one seam" from the scope. Acceptable for v1 (hand-dial timing/text/framing).

## Editor build (T3) — add to Palmier Pro
- A Supabase client module (service key or a scoped token).
- HoTF login: reuse the shared identity — call the portal `GET /api/identity/resolve` (Bearer), team-gated, surfaced in `Settings/AccountPane.swift`.
- A "HoTF Jobs" panel: list `editor_jobs` `ready`/`open` for the signed-in team member → open → map `recipe` to a `VideoProject`/`Timeline` (`Models/Timeline.swift`, `Project/VideoProject.swift`).
- Save-back: write `dialed` + `status='approved'`.
- `MediaResolver` (`Models/MediaResolver.swift`): wire `media_manifest.proxyUrl` into the existing `cachedRemoteURL` slot.

## Reeve build (T4) — add to Trial Reel Engine
- `pushToEditor(recipe, mediaManifest, { clientSlug, clientId, notionRenderPageId })` → insert an `editor_jobs` row (`status='ready'`) on the shared Supabase.
- Worker step: claim `status='approved'` → render via the existing Remotion Mode C path using `dialed` → set `output_url`/`status='done'` + sync the Notion render row.

## Status
- ✅ `editor_jobs` table created on prod (this contract's substrate).
- ⬜ T3 (editor Swift) + T4 (Reeve TS) implementations — build against this contract.
