# HoTF docs — start here

Everything for the HoTF render pipeline + editor integration, in one place.
Read in this order:

1. **`HOTF_SESSION_HANDOFF.md`** — current truth. What's built, what's live on
   prod, the reference IDs/creds, what's left. Start here.
2. **`HOTF_EDITOR_SYNC_PLAN.md`** — the build plan. 3 tracks (editor login UX /
   portal proxy endpoints / agent-box deploy) + the two-machine architecture.
3. **`REEVE_MAILBOX_CONTRACT.md`** — field-level `editor_jobs` contract both repos
   build against (recipe shape, status lifecycle, media manifest).
4. **`HOTF_V2_IMPLEMENTATION_PLAN.md`** — original/broader master plan (historical
   context). Superseded by the handoff where they differ.

## One-line status

Render loop built + compiles on all sides; identity + team-login live on prod;
remaining = editor login UX (this Mac), portal proxy endpoints, agent-box worker
deploy. MCP connector parked.

## The other repos (not in this folder)

- Portal: `~/Documents/Business/HoTF/Client Portal` (branch `v2`, prod = `main`)
- Reeve: `~/Documents/Business/Apps/Trial Reel Engine` (branch `feat/editor-mailbox`)
- Scheduler/MCP: `~/Documents/Business/Apps/Scheduler` (parked)
