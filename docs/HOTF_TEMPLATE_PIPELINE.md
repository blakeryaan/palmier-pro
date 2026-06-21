# Mode C Templates — pipeline state (2026-06-21)

Plain status of the template side: where templates live, what's wired, what's left.

## The two stores (the confusion)

- **Notion "Format Templates" DB (21 rows)** — the template *catalog* + the
  Draft→Active lifecycle. Each row holds the notes (segments, duration, locked
  constraints, source IG URL) but only a **path** to the actual body
  (`Template JSON Path` → a `tmp/` file).
- **Reeve `mode_c_templates` (Supabase `ckhemylsxalpiymsrcsp`)** — the store the
  **render machine actually reads** (`mode-c-from-template` → `loadTemplate`).

These were never connected: the agent wrote templates to Notion, the machine read
from `mode_c_templates`, and nothing copied between them. That's why the 21 looked
"in use" but produced nothing.

## What's now working

- **4 templates migrated into `mode_c_templates`** (the 4 whose body still existed
  on disk): `only-for-the-brave` (8 segs), `be-that-guy` (6), `lost-to-find-yourself`
  (5), `your-next-opponent-is-you` (4). All `client_slug=null` (global). Confirmed
  readable by the machine's `loadTemplate`.
  Script: `Trial Reel Engine/scripts/migrate-surviving-templates.ts`.
- **"Promote to Template" button** in the editor's Projects tab
  (`HoTFProjectsView`). Takes a project (its live edit if open, else its stored
  recipe) → writes to portal `editor_templates`.
- **Sync pipe** `editor_templates` (portal) → `mode_c_templates` (Reeve):
  `Trial Reel Engine/scripts/sync-editor-templates.ts`. Run manually for now;
  fold into the agent later.

So the loop is: edit a project → Promote → (run sync) → machine can reuse it.

## The 17 missing bodies

The other 17 Notion templates (incl. both "Active": *Trust The Process*,
*We Own A Business*) had their body in `tmp/mode-c-ingest/…` which is **gitignored
and auto-deleted** — gone from this Mac. Notion still has each one's **source IG
URL** + locked constraints + required tags.

**Recovery = re-ingest from the source URL.** The agent's ingest pipeline
(`src/ModeC/analyze.ts` → annotate → `saveTemplate`) regenerates the body from the
reel; the preserved Notion constraints/tags re-apply the editorial intent. This is
the same change as Blake's planned step: **deploy the agent update that re-ingests +
pushes to `mode_c_templates`** — it both recovers the 17 and automates the pipe so
the manual `sync-editor-templates.ts` step goes away.

## Status / next

- ✅ Supabase side working + confirmed manually (4 templates readable; promote +
  sync pipes built and run).
- ⏳ Blake: deploy the agent update to auto-push templates to `mode_c_templates`
  (recovers the 17 + removes the manual sync step).
- ⏳ Test the editor button: open a project → Promote → run `sync-editor-templates.ts`
  → confirm it lands in `mode_c_templates`.

Uncommitted: editor Promote button (`HoTFWorkbenchViews.swift`); Reeve
`migrate-surviving-templates.ts` + `sync-editor-templates.ts`.
