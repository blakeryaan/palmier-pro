# HoTF v2 — Full Implementation Plan + Status

_Snapshot 2026-06-20. Legend: ✅ done + verified · 🟡 partly done · ⬜ not started · ⚠️ needs Blake._

## ✅ Autonomous build pass complete (2026-06-20)

The render-loop north star is built, compiles, and is verified at every data/lifecycle seam.
All work is committed + pushed (portal `v2` pushed; scheduler `feat/trial-reel-checkbox`,
Reeve `feat/editor-mailbox`, editor `feat/hotf-mailbox` pushed).

- **T4 Reeve** ✅ `editor-jobs.ts` (pushToEditor/claim/editorJobToVariation) + `mode-c-worker.ts`
  approved→render→Frame.io→done→Notion step. Verified: live `editor_jobs` push→approve→claim
  (optimistic lock)→done; `tsc` clean.
- **T3 Editor** ✅ `Sources/PalmierPro/HoTF/*` (contracts, identity, mailbox, recipe↔timeline, Jobs
  window, ⌘⇧J). Verified: `swift build` + `HoTFContractTests` 3/3 + cross-language dialed→render-props.
- **T2 MCP** ✅ `get_performance` / `ideate` / `draft` / `save_to_library` + portal
  `/api/identity/{performance,save}`. MCP boots (7 tools); portal `tsc` 0 new errors.

### Two residuals — both need Blake (credentials / product decision), not code:
1. **Supabase Auth SMTP + URL config** (T0.1 reset + T1 invite) — needs your SMTP provider creds +
   dashboard. Render loop does not depend on it.
2. **Deploy portal `v2` to prod** — live site still serves the old build (`/api/identity/*` → 307),
   so the MCP's live data + portal login wait on the v2 deploy. v2 carries the unfinished UI rework,
   so this is your call (merge v2→main or point Vercel at v2). The editor↔Reeve render loop talks to
   Supabase directly and is unaffected.

---

_Original plan below._

---

## The system: 5 components, one foundation

One foundation, three products on top, plus the production engine:

- **Foundation — HoTF login + account status** (Supabase Auth, project `xxtuqjtwspjcbwvqdfof`) + **content engine** (Notion + Supabase). One account per person, for clients AND team. The login is the front door; the account carries active/paid status.
- **Dashboard V2** (`clients` repo, `v2`, Next.js 16) — the ecosystem / client front door + team admin + the remote-control surface for production.
- **MCP connector** (`scheduler` repo) — the client's context in their Claude. Paid, gated on active status. No link to the editor.
- **Video Editor** (`palmier-pro` / Palmier Pro, Swift) — internal production surface. Agent drafts ~90%, human dials, render fleet ships.
- **Reeve = Trial Reel Engine** (`trial-reel-generator`, Remotion) — the content automation OS (Mode A/B/C/D, render workers, queues). Produces the Mode C recipes the editor dials.

**Production flow:** Reeve drafts a Mode C recipe → editor opens it as a timeline, human dials → saves back → Reeve's render worker (Remotion, render laptop) ships → Frame.io → portal review. The MCP is separate (client context, not the render loop). The only thing all share is the **login**.

**Constraints:** Next.js 16 is breaking (read `node_modules/next/dist/docs/` before portal code); editor is Swift 6.2 / macOS 26 / `AppTheme` design system; Reeve is Remotion 4.0.451; same Supabase project across all; solo build.

---

## ⚠️ Blake's one action — Supabase dashboard (fixes reset AND add-member)

Password reset (T0.1) and "add emails/people not working" (T1) are the **same Supabase Auth config**, not code (the code is correct):

- **Auth → URL Configuration:** Site URL = `https://clients.thehotf.com`; redirect allowlist += `https://clients.thehotf.com/**`, `/reset-password`, `/signup`.
- **Auth → SMTP:** configure custom SMTP — built-in Supabase email is rate-limited and is the likely reason emails don't arrive.

Do this and both reset and team invites work.

---

## Track 0 — Identity foundation (portal `v2`) ✅ DONE + VERIFIED

The unblocker. Most of it already existed; this was fix + formalize + expose.

- ✅ `src/lib/auth.ts` — **`resolveAccount(token)`**: the one identity shape every product consumes: `{ userId, email, isTeam, isMasterAdmin, capabilities, activeStatus, workspaceSlug, clients[] }`. Team = master-admin or a `staff_capabilities` row (a client "owner" is NOT team). Added `getStaffCapabilities`; threaded `account_status` through `resolveClientContexts`.
- ✅ Dev bypass (`DEV_BYPASS_TOKEN`) removed from `auth.ts`.
- ✅ `src/app/api/identity/resolve/route.ts` — Bearer-token identity endpoint (optional `IDENTITY_SHARED_SECRET` header).
- ✅ `src/app/api/identity/context/route.ts` — Bearer endpoint returning the resolved client's strategy (positioning page text) + content + results; gated on `account_status='active'` (team always allowed). Powers the MCP read tools.
- ✅ `src/middleware.ts` — both identity routes added to the public allowlist (they self-auth via Bearer).
- ✅ Migration `supabase/migrations/202606200001_account_status.sql` — `account_status (active|paused|churned)` on `clients`. **APPLIED TO PROD.**
- ✅ Typechecks clean (3 portal tsc errors are pre-existing `.next/types/… 2.ts` dup artifacts).
- ⚠️ T0.1 password reset = the Supabase dashboard action above (code verified correct).

## Track 1 — Portal v2: team admin + remote control 🟡

The team-admin code already exists and is correct.

- ✅ Already built: `src/lib/members.ts` (roles owner/account_manager/fulfillment/editor/viewer), `staff_capabilities` table + flags, `/api/team`, `/api/members`, `/api/admin/invite`, the team page + admin/staff page, `src/lib/notion/teamDirectory.ts`.
- 🟡 The "add emails/people not working" bug = the **same Supabase dashboard config** as reset (`/api/admin/invite` → `inviteOrFindUser` uses `/auth/v1/invite` with `redirect_to=.../signup`). Fix it in the dashboard (above).
- ⬜ T1.2 (optional): surface the Notion members directory (`teamDirectory.ts`) in the portal team view.

## Track 2 — MCP context connector v1 (scheduler repo) ✅ read-spine DONE

- ✅ `src/mcp/server.ts` — `habits-of-the-few` MCP server (stdio) with read tools `get_strategy`, `get_content`, `get_results`, calling the portal `/api/identity/context`. Membrane lives in the portal; the server only relays.
- ✅ `src/mcp/SETUP.md`, `package.json` (+ `@modelcontextprotocol/sdk`, `zod`, `@types/node`), `tsconfig` now includes `src/`. Server typechecks clean.
- ⬜ Left: `get_performance` (IG analytics DB), `draft`/`ideate` (always voice), `save_to_library`; OAuth instead of a pasted token; remote HTTP transport + Railway deploy (so clients add a URL, not run a process).

## Track 3 — Editor: integrate Palmier Pro 🟡 (contract done; Swift impl left)

Palmier Pro is a full Swift AI editor that already exposes an MCP server + has Timeline/MediaManifest/MediaResolver/agent-tools. The work is HoTF-specific wiring.

- ✅ Integration substrate done (see Track 3+4 below).
- ⬜ Build against `Video Editor/docs/REEVE_MAILBOX_CONTRACT.md`:
  - Supabase client module (service key / scoped token).
  - HoTF login: reuse the shared identity — call portal `GET /api/identity/resolve`, team-gated, in `Settings/AccountPane.swift`.
  - "HoTF Jobs" panel: list `editor_jobs` `ready`/`open` → open → map `recipe` to a `VideoProject`/`Timeline` (`Models/Timeline.swift`, `Project/VideoProject.swift`).
  - Save-back: write `dialed` + `status='approved'`.
  - `MediaResolver`: wire `media_manifest.proxyUrl` into the existing `cachedRemoteURL` slot.
  - Needs a `swift build`-capable session (macOS 26).

## Track 4 — Reeve / Trial Reel Engine wiring 🟡 (contract done; impl left)

- ✅ Integration substrate done (below).
- ⬜ Build against the contract:
  - `pushToEditor(recipe, mediaManifest, { clientSlug, clientId, notionRenderPageId })` → insert an `editor_jobs` row (`status='ready'`).
  - Worker step: claim `status='approved'` → render via the existing Remotion Mode C path using `dialed` → set `output_url`/`status='done'` + sync the Notion render row (the `frame-link` skill).

## Track 3+4 integration point ✅ DONE

- ✅ **`editor_jobs`** Supabase mailbox table (`status` ready→open→approved→rendering→done, `recipe` jsonb, `media_manifest`, `dialed`, `output_url`, `notion_render_page_id`). Migration `202606200002_editor_jobs.sql` + `touch_updated_at()`. **APPLIED TO PROD.** RLS on, no policies = service-role only (clients never see the mailbox).
- ✅ `Video Editor/docs/REEVE_MAILBOX_CONTRACT.md` — full protocol + lifecycle + the `FormatTemplate` ↔ editor `Timeline` mapping both repos build against.

---

## Verify (after portal redeploy)

- **Identity:** `curl -H "Authorization: Bearer <supabase access token>" https://clients.thehotf.com/api/identity/resolve` → account + status + capabilities.
- **MCP:** set `HOTF_ACCESS_TOKEN` (+ `IDENTITY_SHARED_SECRET` if the portal sets one), `claude mcp add habits-of-the-few -- npx tsx src/mcp/server.ts` (from the scheduler repo), then in Claude ask "what's my positioning" → `get_strategy` returns that client's real strategy. Try a second client → isolation holds.
- **Editor↔Reeve:** once T3/T4 land — Reeve writes an `editor_jobs` row → editor opens it on the Mac → dial timing/text → save → render laptop ships the full-res cut to Frame.io.

## Uncommitted changes (for the final commit)

- **Client Portal (`v2`):** `src/lib/auth.ts`, `src/middleware.ts`, `src/app/api/identity/resolve/route.ts`, `src/app/api/identity/context/route.ts`, `supabase/migrations/202606200001_account_status.sql`, `supabase/migrations/202606200002_editor_jobs.sql`, `docs/IDENTITY_BUILD_PLAN.md`, `HANDOFF_2026-06-20.md`.
- **Scheduler:** `src/mcp/server.ts`, `src/mcp/SETUP.md`, `package.json`, `tsconfig.json`.
- **Video Editor:** `docs/REEVE_MAILBOX_CONTRACT.md`.
- **Prod DB (already applied):** `account_status`, `editor_jobs` (+ `touch_updated_at()`).

## Sequence to finish

1. Supabase dashboard fix (reset + invite).
2. `swift build` session: T3 editor + T4 Reeve against the mailbox contract.
3. T2 stretch (OAuth + remote deploy) when ready to put the MCP in clients' Claude.
4. Commit everything together.
