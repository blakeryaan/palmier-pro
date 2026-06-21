# HoTF Editor ⇄ Render Sync — Build Plan

The goal (Blake's words): open the editor on this MacBook → it prompts me to log
in with my HoTF account → I'm signed in → I see the jobs/templates → I click one,
start it, make changes → "Send for Render" → it renders on the agent computer and
does the rest (Frame.io, Notion).

This doc is the handoff for finishing it in VS Code (editor on this Mac; render
worker on the agent computer over SSH).

---

## 1. Architecture — two machines, one queue

The two computers **never talk to each other**. They share one table.

```
THIS Mac (editor)                 Portal Supabase                  AGENT Mac (render box)
──────────────────                ───────────────                  ──────────────────────
login w/ HoTF account             editor_jobs  (the mailbox)       worker daemon (launchd)
see jobs / templates       ─────► row.status lifecycle:    ◄─────  polls status='approved'
open → edit                       ready → open → approved          claims (optimistic lock)
"Send for Render"          ─────►       → rendering → done  ─────►  Remotion render
                                                                    → Frame.io → Notion
                                                                    → status='done'
```

- **editor_jobs** lives on the portal Supabase project `xxtuqjtwspjcbwvqdfof`
  (where `client_id` FKs `clients`). It is the single sync point.
- **Status is the handshake.** Editor writes `approved`; the agent box flips it
  `rendering` → `done`. Optimistic locking (`status=eq.approved` on the claim
  PATCH) stops two boxes grabbing the same job.
- **The portal is the editor's front door.** For team members the editor should
  authenticate as the *user* and let the portal do the privileged Supabase work,
  so no service key ever sits on a team member's laptop (see Track B).

Why a queue and not a direct connection: the render box can be asleep, busy, or
restarted — the job just waits in `approved` until it's claimed. Robust across
two machines with zero coordination.

---

## 2. Current state (built + verified 2026-06-20)

- ✅ Editor compiles (`swift build` clean). HoTF integration present:
  `Sources/PalmierPro/HoTF/` — `HoTFMailbox` (list/claim/saveDialed),
  `HoTFJobImporter` (recipe ⇄ timeline), `HoTFJobsView` (⌘⇧J window),
  `HoTFContracts`, `HoTFConfig`.
- ✅ Reeve side built: `src/engine/editor-jobs.ts` (push/claim/update) +
  `scripts/mode-c-worker.ts` (claims `approved` → renders → Frame.io → done) +
  `scripts/push-to-editor.ts` (seed) + `scripts/install-mode-c-worker-launchd.ts`.
- ✅ `editor_jobs` table live on prod, schema matches the contract.
- ✅ `GET /api/identity/resolve` live on prod (team-gated identity).
- ✅ A real test job is in the mailbox: `da4a1bc3-7add-43d1-b365-15796481e2fd`
  ("TEST - live editor dial (30,000 Orders)", 3 clips + text).

**Gap vs the goal:** the editor's HoTF connect form asks you to paste a token +
the Supabase service key, and it doesn't prompt on launch. We replace that with a
real account login (Track A). Media proxies (real footage preview in-editor) are
a separate, later optimisation — structure/dial/save/render all work without them.

> Note: the editor's *native* `AccountService` is Clerk+Convex — that's Palmier's
> commercial backend for AI credits, **dormant in this fork**. The HoTF login is a
> separate, additional sign-in. Don't touch the Clerk path.

---

## 3. Track A — Editor login + UX  (this Mac, Swift)  ← do first to test

Reuse: `Utilities/KeychainStore.swift` (save/load/delete by account key),
`HoTF/HoTFConfig.swift`, `HoTF/HoTFMailbox.swift`, `App/AppDelegate.swift`.

### A1. HoTF email/password sign-in
Add to `HoTFMailbox` (or a new `HoTFAuth`):
- `signIn(email, password)`:
  `POST {SUPABASE_URL}/auth/v1/token?grant_type=password`
  headers `apikey: <anon key>`, body `{email, password}` →
  `{ access_token, refresh_token }`. Save both to Keychain
  (`hotf_access`, `hotf_refresh`).
- `restore()` (call on launch): load `hotf_refresh` →
  `POST .../token?grant_type=refresh_token` → new access token → save.
- After obtaining a token, call the existing portal `GET /api/identity/resolve`
  with `Authorization: Bearer <access>` → gate on `account.isTeam` (already how
  `HoTFMailbox.connect()` works).
- Constants to embed (both are **public**, safe in the app):
  `SUPABASE_URL = https://xxtuqjtwspjcbwvqdfof.supabase.co`,
  `anon key = NEXT_PUBLIC_SUPABASE_ANON_KEY` (from the portal `.env.local`).
- Token refresh: Supabase access tokens expire (~1h). On any 401 from the portal,
  run `restore()` once and retry.

### A2. Prompt on launch
In `AppDelegate.applicationDidFinishLaunching`, after `HomeWindowController`,
`Task { await HoTFMailbox.shared.restore(); if !HoTFMailbox.shared.isConnected {
HoTFJobsWindowController.shared.show() } }`. So an unsigned launch lands on the
HoTF sign-in immediately.

### A3. Replace the connect form (`HoTFJobsView.connectForm`)
Swap the four paste fields for **email + password + Sign in**. Keep Supabase URL
as an embedded constant (A1). The service key is no longer entered here once
Track B lands; until then it's a one-time advanced setting (persists in
`HoTFConfig`, so you set it once, never per launch).

### A4. Jobs / "templates" list
The existing `jobsList` already shows `ready`/`open` jobs from the mailbox —
that's the list to "click one and start it". (A true "browse FormatTemplates and
start a brand-new edit" is a richer future feature; v1 = the job list Reeve
pushes / we seed.)

### A5. "Send for Render"
Rename `HoTFJobsView.approve` button "Approve & Send" → **"Send for Render"**
(avoid "Agent" — the editor's AI assistant is already called Agent). It already
calls `saveDialed` → `dialed` + `status='approved'`, which is exactly the signal
the render box waits for. Optional: poll the row and show `rendering`/`done`
badges + the Frame.io link when it returns.

**Done-when:** launch the app → sign in with your HoTF account → see the job list
→ open `da4a1bc3` → change something → Send for Render → the row flips to
`approved` (verify in Supabase).

---

## 4. Track B — Portal proxy endpoints  (prod)  ← before giving team members logins

So a team member's laptop never holds the service key. The editor calls these
with the *user's* access token; the portal checks `isTeam` and does the Supabase
work server-side. Mirror the existing `/api/identity/*` pattern (bearer auth,
middleware allowlist).

- `GET  /api/editor/jobs`            → list `ready`/`open` (team-gated).
- `POST /api/editor/jobs/[id]/claim` → `ready`→`open` (optimistic lock).
- `POST /api/editor/jobs/[id]/save`  → body `{dialed}` → `dialed` + `approved`.

Then point `HoTFMailbox` at these instead of Supabase REST, and delete the
service-key field from the editor entirely. Deploy to `main` (API-only) the same
way the identity endpoints shipped.

---

## 5. Track C — Agent computer (render box)  ← deploy over SSH/VS Code

The worker already exists; this is deploy + configure, not build.

### C1. Code
Pull Reeve's `feat/editor-mailbox` branch on the agent box (the repo with
`scripts/mode-c-worker.ts`).

### C2. Env (on the agent box)
- Editor mailbox creds (the portal project): `EDITOR_JOBS_SUPABASE_URL` +
  `EDITOR_JOBS_SUPABASE_SERVICE_ROLE_KEY` — OR ensure the Client Portal
  `.env.local` is readable at the path `editor-jobs.ts` falls back to.
- Frame.io: account / project / folder ids (the worker's
  `resolveFrameIoDestination`).
- Render deps: Remotion + ffmpeg + fonts; Drive creds for full-res asset pull
  (`materializeVariation`).

### C3. Run
- One-shot test: `npx tsx scripts/mode-c-worker.ts --editor-job <jobId>`
  (add `--dry-run` to build render props without rendering/uploading).
- Daemon: `npx tsx scripts/install-mode-c-worker-launchd.ts` → installs a launchd
  job that polls `approved` continuously.

### C4. Verify end-to-end
Approve a job in the editor (this Mac) → within the poll interval the agent box
claims it (`rendering`) → renders → uploads to Frame.io → `done` + `output_url`
+ Notion render row synced. Check the row in Supabase + the Frame.io link.

---

## 6. Status lifecycle (the contract)

```
ready ─(editor opens)→ open ─(editor "Send for Render")→ approved
      ─(agent claims, optimistic lock)→ rendering ─(render+upload ok)→ done
                                                   ─(error)→ failed (error_notes)
```

Full field-level contract: `docs/REEVE_MAILBOX_CONTRACT.md`.

---

## 7. What deploys where

| Piece | Lives on | How |
|---|---|---|
| Editor app + HoTF login (Track A) | this Mac | `swift build` / VS Code |
| Portal proxy endpoints (Track B) | prod (Vercel `main`) | API-only push |
| Worker daemon + creds (Track C) | agent computer | SSH / launchd |

## 8. Suggested order

1. **Track A** — login + Send for Render (this Mac). Test the editor half against
   the seeded job; confirm the row hits `approved`.
2. **Track C** — stand up the worker on the agent box; confirm `approved` → `done`.
   Now the full loop runs end to end for you.
3. **Track B** — proxy endpoints, then onboard team members (portal "Add team
   member" already exists: `POST /api/admin/team-invite` creates the login + grants
   team in one call).
