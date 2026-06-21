# HoTF v2 — Session Handoff (2026-06-20)

Single source of truth for continuing in VS Code. Captures what was done this
session, the **verified** state of every repo, what's live on prod, the reference
IDs/creds, and exactly what's left. Where this doc and the older
`HOTF_V2_IMPLEMENTATION_PLAN.md` disagree, **this doc wins** (it's newer).

---

## TL;DR

- The Reeve ⇄ editor **render loop is fully built and compiles** on all sides. The
  one missing thing for a polished demo is media proxies (real footage preview).
- **Identity + team-login backend is live on prod.** A team member can be created
  with a working login + team status in one API call.
- **Next work = 3 tracks** (editor login UX / portal proxy endpoints / agent-box
  deploy) in `HOTF_EDITOR_SYNC_PLAN.md`.
- The MCP connector was extended but **parked** by Blake — not a priority.

---

## What we did this session

1. **MCP connector (scheduler repo) — extended, then PARKED.**
   - Added master/team workspace targeting to `src/mcp/server.ts`: `use_client`,
     `list_clients`, a `client` arg on every tool, `HOTF_WORKSPACE` env, per-client
     cache. Rewrote `src/mcp/SETUP.md`. Typechecks + boots clean.
   - Root cause it fixed: Blake has 4 client memberships, so the MCP was silently
     serving `clients[0]` (blake-ryan) and couldn't reach Noah/Sam/Jayden.
   - **Status: working but deprioritised. Don't spend time here unless asked.**

2. **Portal identity / team-login — BUILT + DEPLOYED TO PROD.**
   - `GET /api/identity/workspaces` — team-only client directory (name→slug) so the
     MCP can target any client. Live.
   - `POST /api/admin/team-invite` — master-admin: **creates the Supabase login AND
     grants `staff_capabilities` (team) in one call.** Password mode (admin-create +
     `email_confirm`) works with no SMTP; `sendEmail:true` uses the Supabase invite.
     This closed the real gap: the old invite flow made *client owners* (not team),
     so invited people couldn't use the editor.
   - Shipped to prod `main` via commit `f697280` (cherry-picked off `v2` in a
     detached worktree so the uncommitted v2 UI rework was never touched).
     Both endpoints verified live.
   - **SMTP is now configured** (Blake) → email invites also work.

3. **Render loop — VERIFIED (read every seam, built it).**
   - Editor `swift build` → clean. Full HoTF integration real:
     `HoTFMailbox` (connect/list/claim/saveDialed), `HoTFJobImporter`
     (recipe ⇄ timeline, round-trips timing/text/framing), `HoTFJobsView` (⌘⇧J).
   - Reeve `editor-jobs.ts` + `scripts/mode-c-worker.ts` (claims `approved` →
     Remotion render → Frame.io → `done` → Notion) + `scripts/push-to-editor.ts`.
   - `editor_jobs` table live on prod, schema matches the contract.
   - Seeded a **real** test job into the prod mailbox (below).
   - Launched the editor (`swift run PalmierPro`) for live testing.

4. **Wrote the build plan** → `HOTF_EDITOR_SYNC_PLAN.md` (the 3 tracks).

---

## Verified state per repo

| Repo | Path | Branch | State |
|---|---|---|---|
| Portal | `~/Documents/Business/HoTF/Client Portal` | `v2` (prod = `main`) | identity + team-invite live on prod; v2 has uncommitted UI rework (Blake's) |
| Editor | `~/Documents/Business/Apps/Video Editor` | `feat/hotf-mailbox` | compiles; HoTF integration done; manual connect form (Track A replaces it) |
| Reeve | `~/Documents/Business/Apps/Trial Reel Engine` | `feat/editor-mailbox` | push + worker built; **Blake to pull onto the agent box** |
| Scheduler (MCP) | `~/Documents/Business/Apps/Scheduler` | — | MCP workspace targeting done; **parked** |

---

## Live on prod (`clients.thehotf.com`)

All identity endpoints (bearer/self-auth) + the admin team-invite:

- `GET /api/identity/resolve` — account + isTeam + capabilities
- `GET /api/identity/context` — a client's strategy/content (MCP), `?workspace=` for team
- `GET /api/identity/performance` · `POST /api/identity/save` — MCP perf + save
- `GET /api/identity/workspaces` — team client directory (NEW)
- `POST /api/admin/team-invite` — create login + grant team (NEW, cookie-authed)

DB migrations applied to prod: `account_status` (on clients), `editor_jobs`,
`staff_capabilities`. **Note: 0 `staff_capabilities` rows exist — only the two
master-admin emails are currently "team".** Real team members need `team-invite`.

---

## Reference

- **Portal Supabase project:** `xxtuqjtwspjcbwvqdfof` → `https://xxtuqjtwspjcbwvqdfof.supabase.co`
- **Reeve Supabase project:** `ckhemylsxalpiymsrcsp` (Mode C variations: `mode_c_variations`)
- **Vercel:** project `client-portal` `prj_slRDAC0Qd7iMFChyBN1Tj0Uei7G7`, team `team_20ss5AXnY99RRkCSDintE4TT`
- **Master-admin emails:** `blake@blakeryan.com`, `blake@byblakeryan.com`
- **Blake's user id:** `c8809a54-6e0c-477e-b0da-723dbdc4ecaf` (4 memberships: blake-ryan, chent-thambiah, mike-rahimi, richard-lipp)
- **Portal client slugs:** `blake-ryan`, `chent-thambiah`, `jayden-editing`, `mike-rahimi`, `noah-hunter-dorsey`, `richard-lipp`, `sam-grigg`
- **Test job in mailbox:** `da4a1bc3-7add-43d1-b365-15796481e2fd`
  ("TEST - live editor dial (30,000 Orders)", 3 segments + 3 media, 1080×1920@30).
  Stub (no media): `a4509a66-6f5b-4f1e-ac56-309c861b37c7`.
- **Editor login constants (both public, safe to embed):**
  `SUPABASE_URL=https://xxtuqjtwspjcbwvqdfof.supabase.co`,
  anon key = `NEXT_PUBLIC_SUPABASE_ANON_KEY` (portal `.env.local`).
- **Service key (server-side only):** `SUPABASE_SERVICE_ROLE_KEY` (portal `.env.local`).

---

## Test the loop right now (editor half — no agent box needed)

1. App is running (`swift run PalmierPro`). **⌘⇧J** → HoTF Jobs.
2. Connect: Portal `https://clients.thehotf.com` · Supabase
   `https://xxtuqjtwspjcbwvqdfof.supabase.co` · service key (portal `.env.local`) ·
   token = your `cp_at` cookie value. → resolves you as TEAM.
3. Open **"TEST - live editor dial (30,000 Orders)"** → 3-clip timeline.
4. Change something → **Approve & Send** → row flips to `approved`.
   (Media may render as placeholder — proxy gap, see below.)
5. The render half needs the agent box (Track C).

---

## What's left

- **Track A — editor login UX (this Mac, Swift):** email/password login →
  prompt on launch → "Send for Render". Replaces the manual connect form.
- **Track B — portal proxy endpoints (prod):** `/api/editor/jobs` list/claim/save
  (user-token authed) so team laptops never hold the service key. Plus a portal
  **UI form** for `team-invite` on the admin staff page (~20 lines).
- **Track C — agent computer (SSH/VS Code):** pull Reeve `feat/editor-mailbox`,
  set creds, run `scripts/install-mode-c-worker-launchd.ts` (worker daemon).
- **Media proxies (later):** generate direct-download proxy media so the editor
  previews real footage. Separate, bigger job. Loop works without it.
- **MCP connector:** parked.

Full track detail + the status lifecycle: `HOTF_EDITOR_SYNC_PLAN.md`.
Field-level mailbox contract: `REEVE_MAILBOX_CONTRACT.md`.
