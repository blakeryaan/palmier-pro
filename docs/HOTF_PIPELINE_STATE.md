# HoTF Editor ⇄ Reeve — Pipeline State & What the App Shows

**Date:** 2026-06-20
**Purpose:** Hand-off so another Claude (on the agent/render box) can verify the pipeline. Blake suspects the data pipeline feeding the editor is **not pointed at the right source**. This documents exactly what is built, what the app displays, where that data comes from, and the open questions. Read the "Suspected issues" section — that's the crux.

---

## TL;DR

- The macOS editor (HoTF Editor, this repo) now signs in with a HoTF account and shows three tabs: **Projects**, **Templates**, **Render Queue**, all read from a **Supabase mirror** on the **Portal** project.
- A Reeve script (`npm run sync-notion`) mirrors the Reeve content-workbench Notion DBs **and** `mode_c_variations` into that Supabase. Meant to run on a cron.
- **The editor only understands Mode C** (`ModeCReel`: template + resolution + b-roll slots). It opens a project by downloading the b-roll/audio from public Drive/Supabase URLs baked into the recipe.
- **The gap Blake noticed:** Projects shows only 16 old Future-Fulfilment Mode C variations. The recent Noah/Blake work is **not Mode C** — it's `TrialReel` and `ClientReel` compositions in `render_jobs`, which the editor can't open. See **§5**.

---

## 1. Machines & data stores

| Store | ID / location | Holds |
|---|---|---|
| **Editor** (this Mac) | `~/Documents/Business/Apps/Video Editor` (Swift) | the app; opens recipes into a timeline |
| **Portal Supabase** | project `xxtuqjtwspjcbwvqdfof` | `editor_jobs` mailbox + all the **mirror** tables the editor reads |
| **Reeve Supabase** | project `ckhemylsxalpiymsrcsp` | `mode_c_variations` (16), `render_jobs` (502), `assets` (1644), `renders` (108), `mode_c_templates` (1) |
| **Notion** | "Reeve Content Workbench" | Format Templates (21), Render Queue (603), Content Library (1288), Ingest Queue (27) |

The editor reads **only** the Portal project (team-gated by RLS). It never touches Reeve Supabase or Notion directly — the sync script bridges them.

---

## 2. What the editor shows right now (per tab)

Auth: email + password → Supabase password grant on the Portal project → token. RLS function `public.is_hotf_team()` (master-admin email OR `staff_capabilities` row) gates every read.

| Tab | Reads (Portal table) | Rows | Notes |
|---|---|---|---|
| **Projects** | `wb_projects` | **16** | Mirror of Reeve `mode_c_variations`. Carries full recipe → **Open** builds a timeline + downloads b-roll; **Send for Render** inserts an `editor_jobs` row (`approved`). |
| **Templates** | `wb_format_templates` | **21** | Mirror of the Notion "Format Templates" catalog (read-only display). |
| **Render Queue** | `wb_render_queue` | **603** | Mirror of the Notion "Render Queue" (read-only status board). |

`wb_content_library` (1288) and `wb_ingest_queue` (27) are mirrored but not yet shown as tabs.

---

## 3. How the data gets there (the sync)

**`Trial Reel Engine/scripts/sync-notion-to-supabase.ts`** (`npm run sync-notion`) — idempotent, cron-ready:
1. Reads each Notion workbench DB via `@notionhq/client` (auth: `NOTION_API_KEY` from the **Portal** `.env.local` — Reeve's own `NOTION_TOKEN` is dead/invalid).
2. Flattens every Notion property into a `props` jsonb; lifts out `name` + `status`.
3. Upserts to `wb_format_templates`, `wb_render_queue`, `wb_content_library`, `wb_ingest_queue`.
4. Then mirrors Reeve `mode_c_variations` → `wb_projects` (Supabase→Supabase), carrying `{template, resolution, hookText}` + a media manifest.

Last run: `{ wb_format_templates: 21, wb_render_queue: 603, wb_content_library: 1288, wb_ingest_queue: 27, wb_projects: 16 }`.

There is also `scripts/migrate-templates-to-portal.ts` (earlier iteration, deduped variations → a `templates` table; **largely superseded by `wb_projects`** — see redundancy note in §7).

---

## 4. How "Open" materializes media (answers "how does a new computer get the footage")

Each `wb_projects` row carries a **media_manifest**: `assetId → { proxyUrl, fullResUrl }`. Those URLs are **public**:
- b-roll → Google Drive `/file/d/<id>/view` links
- audio → public Supabase storage (`…/storage/v1/object/public/mode-c-audio/…m4a`)

On **Open**, `Sources/HoTFEditor/HoTF/HoTFJobImporter.swift`:
1. Rewrites Drive `/view` URLs → direct-download (`uc?export=download&id=…`).
2. Downloads each asset over HTTPS into the local project's media folder.
3. Builds the timeline (video/text/audio tracks) from the recipe segments.

So **any** signed-in team Mac materialises the media from the cloud on demand — nothing is pre-staged. Works only because the Drive files are shared "anyone with link."

---

## 5. THE PIPELINE FINDING (why recent work doesn't show)

Reeve `render_jobs` (502 rows = the real render history) splits into **three compositions**:

| `mode` | `composition` | client_slug | count | last | Editor can open? |
|---|---|---|---|---|---|
| (mode-c) | `ModeCReel` | future-fulfilment / blake | 16 (in `mode_c_variations`) | 2026-06-18 | ✅ yes |
| `trial` | `TrialReel` | **blake** | **159** | **2026-06-17** | ❌ no |
| `clip-hooks` | `ClientReel` | **noah** | **343** | **2026-06-01** | ❌ no |

- The editor's importer (`HoTFJobImporter`) only understands the **Mode C** recipe shape (`template` + `resolution` + b-roll `slots`).
- `TrialReel` / `ClientReel` `props_json` do **not** carry `template`/`resolution`/`hookText` — different prop shapes (hook + clip list).
- `mode_c_variations` (the editor's Projects source) has only **16** rows and effectively stopped after May 22 (+ one June 18 Blake test). **The recent Noah + Blake volume is all `render_jobs` under the other two compositions.**

**Conclusion:** the editor is wired to the Mode C variation store, but the recent content is produced by the Trial/Client reel pipelines. To make recent work editable, the editor needs **importers for `TrialReel` and `ClientReel` props → timeline**, and the projects source should likely be **`render_jobs`** (all compositions) rather than `mode_c_variations`.

---

## 6. Supabase objects created this session (Portal project `xxtuqjtwspjcbwvqdfof`)

- Function `public.is_hotf_team()` (security definer) — master-admin emails (`blake@blakeryan.com`, `blake@byblakeryan.com`) OR a `staff_capabilities` row.
- RLS policies (team `select`/`insert`/`update`) on `editor_jobs`; team `select` on `templates`, `wb_format_templates`, `wb_render_queue`, `wb_content_library`, `wb_ingest_queue`, `wb_projects`.
- Tables: `templates` (recipe library, 14 — earlier iteration), `wb_format_templates`, `wb_render_queue`, `wb_content_library`, `wb_ingest_queue`, `wb_projects`.
- `editor_jobs` (pre-existing mailbox) gained an INSERT policy so the editor can push jobs with the user token (no service key on the client).

## Reeve repo changes this session (`~/Documents/Business/Apps/Trial Reel Engine`)

- `scripts/sync-notion-to-supabase.ts` (`npm run sync-notion`) — the cron.
- `scripts/migrate-templates-to-portal.ts` (`npm run migrate-templates`) — earlier, superseded.
- `workbench/` — added a **"Send to HoTF Editor"** action (`/api/push-to-editor` → `pushToEditor`) so a reviewed variation can be pushed to `editor_jobs`.

---

## 7. Suspected issues / open questions (verify these)

1. **Wrong projects source.** `mode_c_variations` (16) is stale. The live render history is `render_jobs` (502, Noah + Blake, recent). **Should `wb_projects` mirror `render_jobs` instead of / in addition to `mode_c_variations`?**
2. **Missing importers.** Editor only opens `ModeCReel`. Need `TrialReel` + `ClientReel` → timeline importers. Their `props_json` shapes need documenting (look at the Remotion compositions in Reeve `src/` — `TrialReel`, `ClientReel`).
3. **Editable vs output.** `render_jobs.props_json` is **render** props (may be render-time-resolved, not the editable source). Confirm whether re-opening a finished render reconstructs an editable timeline, or whether the editable source lives elsewhere (Drive `format-template.json`, hook DB, clip DB).
4. **Redundant tables.** `templates` (14, variation-dedup) vs `wb_projects` (16, variations) overlap. Consolidate.
5. **Media depends on public Drive links.** Portable only while files are "anyone with link." A team member on a different Google account relies on that. Consider proxy staging to a controlled bucket.
6. **Security:** Reeve project has **RLS disabled** on `assets`, `renders`, `clip_feedback`, `mode_c_templates` — anyone with the anon key can read/write. The workbench uses the service key (bypasses RLS), so enabling RLS + policies is a hardening decision, not a fix.
7. **Notion token:** Reeve `.env` `NOTION_TOKEN` is invalid; the sync uses `NOTION_API_KEY` from the Portal `.env.local`. Confirm that's the intended integration with access to the workbench DBs.

---

## 8. Reference IDs

- Portal Supabase: `xxtuqjtwspjcbwvqdfof` · Reeve Supabase: `ckhemylsxalpiymsrcsp`
- Notion data sources: Format Templates `b976a724-976f-404d-aa27-f47349cb1bd3` · Render Queue `90439b2f-b9f5-467f-861c-f2e9ccb5151c` · Content Library `347601f0-fb0d-81fb-879b-000bdf258aed` · Ingest `a0ad3550-c6e4-496f-a4ae-5bc24567e635`
- Client Notion pages: Future Fulfilment `84fcaa49…` · Blake Ryan `358601f0…`
- `render_jobs` editable-recipe key columns: `mode`, `composition`, `props_json`, `template_page_id`, `source_payload`, `output_url`, `thumbnail_url`
