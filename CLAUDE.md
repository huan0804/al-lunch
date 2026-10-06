# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"Cơm trưa team" — a team lunch-ordering app for splitting a shared lunch order and collecting payment (cash or VietQR bank transfer). It runs as a static site on **Vercel + Supabase** (no build step, no bundler, no framework — plain HTML/CSS/JS served as-is), deployed at https://al-lunch.vercel.app/. Repo: https://github.com/huan0804/al-lunch.

Read both of these before making non-trivial changes — they are the authoritative specs and disagree with each other in places (see below):
- [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) — original product/business spec (Vietnamese), written for the old Claude Artifact version. Pricing formula, "đặt hộ" (order-on-behalf-of) flow, and VietQR payload details are still accurate. Its "Mô hình dữ liệu" (§4) and "Vai trò" (§2) sections are **obsolete** — permissions and data model were redesigned for Supabase (see below).
- `C:\Users\Huan\.claude\projects\d--1--Personal-Working-7--AL-Lunch\memory\al-lunch-migration.md` (auto-memory) — current permissions architecture, decisions made and rejected during the migration, fixed bugs, and pending tasks. This is the up-to-date source for anything PROJECT_HANDOFF.md's old sections contradict.
- [WORK_LOG.md](WORK_LOG.md) — per-session changelog (newest first) of pilot feedback fixes and why each change was made. Check it for recent context before assuming a behavior is unhandled.

Files:
- `index.html` — the live app (HTML + CSS + vanilla JS in one file). This is what to edit.
- `supabase-adapter.js` — shim that reimplements the old Claude-Artifact-style `db`/`user`/`sample` API (`doc()`, `collection()`, `onSnapshot`, `mutateOrder`) on top of Supabase, so `index.html`'s event/render logic barely changed during migration.
- `supabase-config.js` — `window.SUPABASE_URL` / `SUPABASE_ANON_KEY` (anon/publishable key, safe to expose — see security notes in `supabase-schema.sql`) and the share-link origin.
- `supabase-schema.sql` — full schema, RLS policies, and RPCs. Idempotent (`IF NOT EXISTS` / `CREATE OR REPLACE` throughout) — safe to re-run wholesale in the Supabase SQL Editor after edits.
- `split.html` + `split-schema.sql` — the standalone "Chia tiền nhóm" (split bill) feature; see the Split bill section below. `split-bill-feature.md` is the original change spec for it (historical).
- `com-trua.html` + `mock-runtime.js` — the **old Claude Artifact version**, kept only as historical reference. `mock-runtime.js` fakes `window.claude.use(...)` and only works against `com-trua.html`, not `index.html`. Not actively maintained; do not edit them expecting user-visible effect.

## Running / testing locally

There is no build or test command — it's static files.

- To run the live app: serve the directory root (`index.html` + the two `supabase-*.js` files) with any static file server, or just open `index.html` directly — it loads `@supabase/supabase-js` from a CDN and talks to the real Supabase project directly (no local backend).
- There is no local/mock Supabase backend and no automated test suite. Verify changes manually in a browser against the real Supabase project, including checking realtime updates across two tabs/devices.
- To change schema, edit `supabase-schema.sql` and run the whole file in the Supabase Dashboard → SQL Editor (project id `dqagzpvvtqyctaiarwdk`).
- `com-trua.html` can still be smoke-tested via `mock-runtime.js` (inject as an init script, drive via `[data-a="..."]` selectors) if you're touching that legacy file specifically.

## Architecture

**Three-tier link model (the core design of this app — read before touching permissions)**

There is no login and no Supabase Auth. Access is entirely URL-based, via unguessable tokens embedded in the session row:

- **Root link** (`al-lunch.vercel.app`, no query string) — always shows an empty "create new group order" screen. Anyone can open it and create a session.
- **Manage link** (`?manage=<manage_token>`) — generated per-session when it's created; the page auto-redirects here after creation. Full control over *that one session only* (edit menu, confirm payments, close/reopen/delete) — does not grant control over any other session.
- **Order/guest link** (`?order=<order_token>`) — view/order for that one session only, no management rights.

Multiple sessions exist in parallel, each independently owned by whoever created it and holds its own `manage_token`/`order_token`. There is deliberately no global "current session" (`config.current` from the old artifact model doesn't exist here) and no RPC-level auth — RLS is wide open for the anon key on every table; "the right link edits the right session" is enforced client-side by which token is in the URL, not by the server. This was a deliberate 3rd-iteration design choice (PIN, then a single global host token, were both tried and rejected — see the migration memory file for why) and the tradeoff is accepted for a small trusted internal team. Do not reintroduce a global host token or a `config.current`-style pointer.

Bank account details (`bank_bin`, `bank_name`, `account_no`, `account_name`) live on the **session**, not on `config` — each session creator receives payment into their own account, entered inline when creating the session (autofilled from that browser's `localStorage`, never shows another user's account).

**State & rendering (`index.html`)**
- All app state lives in a single object `S` (~line 300: `view`, `sheet`, `cart`, `md`, `sf`, `ai`, `libQ`, `filter`, `busy`, `open`, plus Supabase-specific `db`, `uid`, `canEdit`, `isOwner`, `config`, `session`, `orders`, `dishes`, `drafting`).
- `render()` redraws the entire `#app` and `#overlay` (bottom-sheet) on every state change, while preserving focus and cursor position of the currently-focused input.
- Events use delegation via `data-a` (action) and `data-f` (field) attributes — there are no inline `addEventListener` calls scattered through the view functions.
- `S.cart` is a draft order; it is only written to the db when the user confirms ("Xác nhận đặt món").
- `S.open` persists which `<details>` elements are expanded across re-renders.

**Persistence — `supabase-adapter.js`**
- `index.html` calls `window.SupabaseAdapter.db/.user/.sample` (aliased locally), preserving the old Firestore-ish shape (`doc()`, `collection()`, `onSnapshot`, get/set/update/delete) so the rest of the app didn't need rewriting during migration.
- Field names are translated between camelCase (app) and snake_case (DB) via `CONFIG_MAP`/`SESSION_MAP`/`ORDER_MAP` in `supabase-adapter.js` — when adding a field, add it to the relevant map *and* to `supabase-schema.sql`.
- Orders are written via `mutateOrder(docId, sessionKey, fn)`, a read-modify-upsert-whole-row pattern, mapped onto the `orders` table's `(session_key, doc_id)` composite primary key.
- `doc_id` for a normal member is a per-browser anonymous UUID persisted in `localStorage` (`comtrua:uid`), not a real auth identity. Host detection (`user.canEdit()`/`isOwner()`) is `true` only when the current `?manage=` token resolves to an existing session (verified once via `SupabaseResolveManageAccess()` during boot, before any `canEdit()`/`isOwner()` call).
- Realtime updates use Supabase Realtime (`postgres_changes` subscriptions) instead of Firestore's `onSnapshot`; all five tables (`config`, `sessions`, `orders`, `dishes`, `drafting`) must stay in the `supabase_realtime` publication (see the `do $$ ... $$` block in the schema) or a given screen won't live-update.
- AI menu-image reading (`claude.use("sample")` in the old artifact) is **not ported** — `sample` is `null` in the adapter, so `S.imagesOK` stays false and that UI is disabled. Deferred because it needs a paid server-side Anthropic API call; current workaround is manual text paste / dish library reuse.

**"Đang đặt món" signal (`drafting` table)**
- While a guest has the cart screen open, the client upserts a `drafting` row `(session_key, doc_id, name, updated_at)` every 30s (`draftingState`/`draftingTimer` in `index.html`) and deletes it on confirm/leave. Only the host sees it (an "Đang đặt món (n)" card with a manual delete button). It stores no dishes/prices — the real draft cart stays in browser memory. Stale rows are filtered client-side by `updated_at`; there is no cron cleanup.

**DB-level input limits**
- Since RLS is wide open, `supabase-schema.sql` adds length/control-char CHECK constraints on user-entered text (names, shop, account name, notes) as a second line of defence. Postgres CHECK can't contain subqueries, so JSON-shape checks (`guests_shape_ok`, `sets_shape_ok`) are wrapped in IMMUTABLE functions. Constraints are dropped-then-added to stay idempotent. `esc()` at render time is still required — the constraints don't sanitize HTML.

**Session locking**
- Locking previously used an explicit "Chốt đơn" button; this is gone. Now, when the **host confirms their own order** (not an "on-behalf-of" proxy order) via "Xác nhận đặt món", the app asks for confirmation, then atomically saves the order AND sets `sessions.status = "closed"` in the same action — see `submitCart()`'s `isHostSelf` branch in `index.html`. The host's own "Mở để sửa" button is the only way to reopen (unlocks for everyone, jumps straight into the host's edit form).

**QR codes**
- VietQR payloads are built client-side per the EMVCo spec with manual CRC16 (`vietqr()`, `crc16()` in `index.html`), then rendered via `qrcode-generator@1.4.4` from cdnjs. Deliberately does not use `img.vietqr.io` (blocked historically by the old artifact's CSP; kept client-side for consistency).
- Bank logos use `api.vietqr.io/img/<CODE>.png` where `<CODE>` is the bank's **letter code** (e.g. `VCB`), not its numeric BIN (`970436`) — requesting by BIN returns a JSON error, not an image. `BANKS` in `index.html` is `[displayName, bin, letterCode]` triples.

## Split bill (`split.html` + `split-schema.sql`)

Standalone page for splitting shared event costs, linked from the root "create" screen of `index.html` ("💸 Chia tiền nhóm"). Same look and helpers as `index.html` (copied in, not shared), but **its own data model and a stricter permission model**:

- One table `split_events` (`data` jsonb = title/bank/people/expenses, `status` jsonb = per-person payment status, `recv` jsonb = per-person refund bank accounts). RLS is enabled with **no policies** and anon has no table grants — every read/write goes through `SECURITY DEFINER` RPCs in `split-schema.sql` (`split_create`, `split_get_manage`, `split_update`, `split_set_status`, `split_set_recv_manage`, `split_delete` for the `?manage=` link; `split_set_phase`; `split_get_view`, `split_guest_expense`, `split_claim`, `split_set_recv` for the `?view=` link). `manage_token` is never returned to view-link holders, and full refund account numbers are only returned to the manage link (view link gets bank name + last 4 digits).
- Links: `split.html` (create), `split.html?manage=<manage_token>` (host), `split.html?view=<view_token>` (participants pick their name, stored per-event in localStorage `split:me:<token>`).
- Two phases (`split_events.phase`): **`collect`** (default) — host enters their own expenses, shares the view link, and each participant picks their name and adds/edits/deletes only expenses where they are the payer (RPC `split_guest_expense`, server enforces `payerId = person`, host id rejected, only in `collect`); everyone sees the full expense list but no balances/QR. Host presses "Chốt khoản chi" (`split_set_phase` → `settle`, needs ≥1 expense) to start settlement; "Mở lại" goes back. `split_claim` / `split_set_recv` are refused outside `settle`. Because guests write `data.expenses` concurrently with the host's whole-`data` `split_update`, the host passes `p_base` (= `updated_at` it loaded); on `{conflict:true}` the client merges expenses it hasn't seen (`S.baseIds`) and retries. Known gap: an expense a guest deleted meanwhile is resurrected if the host had it loaded.
- Settlement goes through the host as a hub: each non-host person's `net = paid − share`; `net < 0` → pays `|net|` to the host's account via VietQR; `net > 0` → host refunds `net` to that person's account (they submit it via the view link, or host enters it). Each expense is split evenly in whole đồng; leftover đồng go to the first participants so shares always sum to the expense amount.
- Payment status entries store the amount they were set for (`{s, amt}`); the client ignores a status whose `amt` no longer matches the person's current balance, so editing expenses automatically resets stale "paid" marks.
- No realtime: the manage/view pages poll `split_get_*` every 10s while visible (and pause while editing).
- Local storage: `split:draft` (unsaved create form), `split:history` (events opened on this browser), and it reuses `comtrua:lastBank` / `comtrua:name` from the lunch app for prefill.

## Hard constraints / conventions carried over from the Claude Artifact era

- **No `confirm()` / `alert()`** — use the existing `ask(msg, ok, danger)` helper (bottom-sheet confirm dialog, `S.sheet = {kind:"confirm", ...}`, resolved via `closeAsk()`). Not a host limitation anymore, just the established UI pattern — keep it for consistency.
- **No dark mode, ever** — background must stay pure white (`<html data-theme="light">`), regardless of OS theme. Requested/enforced multiple times historically.
- UI mimics Grab's group-ordering flow (bottom sheets, pill buttons, orange circular `+`) and stays within a 560px-max-width mobile layout.
- `navigator.share()` for inviting teammates is now used where available (the artifact sandbox restriction that blocked it is gone), but **confirmed absent entirely on Xiaomi/HyperOS Chrome** (not a bug — verified via real-device testing; Android intent fallback is also blocked there by Xiaomi GetApps). "Copy tin nhắn mời" (the big orange button) is the reliable fallback on every device and must be kept. When sharing, `navigator.share()` must receive `url` as a separate field from `text` — concatenating the link into the text string breaks Zalo/other apps' ability to recognize it as a link.

## Key business rules (see PROJECT_HANDOFF.md §3 for full detail; still accurate)

- Price per set (`comboSetPrice()` in [index.html](index.html), `base` = `pricePerSet`, default 35,000₫, stored per-session): for COMBO dishes only (dishes with `price == null`) — 2 dishes = `base`; 1 dish = `base - 5000` if it's the *only* thing in the set, or a flat 20,000₫ if it's riding along with ≥1 priced dish (see below); 3+ dishes = `base + (n-2) * 20000`. Dishes with a fixed `price` (e.g. Special 45,000₫) always add their listed price on top, uncapped — `setPrice(picks)` sums `customTotal + comboSetPrice(comboCount, base, customTotal > 0)`. This replaced an older `Math.round(base * Math.max(n,2) / 2 / 1000) * 1000` formula (2025-09-28, pilot feedback) — don't resurrect the old rounding formula.
- A day can have multiple, independently-owned order sessions in parallel (see three-tier link model above). A session locks when `status === "closed"`, its date is in the past, or (if `autoClose`) the deadline has passed; the session's own host can always edit via their `?manage=` link.
- "Đặt hộ" (order-on-behalf-of): one payer can order and pay for multiple named guests in a single order/QR/payment-confirmation, with per-guest dish tabs.
- Backward compatibility matters: older sessions/orders may lack newer fields — code has defaulting helpers (`qtyOf`, `deadlineAt()`) for this; preserve that pattern when adding fields.

## Known gaps / not yet verified (see migration memory file for the full list)

- "Mở để sửa" flow after a recent fix hasn't been fully re-tested.
- `navigator.share()` confirmed working only via copy-fallback universally; not yet confirmed on non-Xiaomi devices (Samsung/Pixel/OPPO).
- AI menu-image reading is unported (see above) — deferred, not a bug.
- Multi-guest transfer payment flow, "Đặt hộ" on the Supabase build, and VietQR rendering across banks other than Vietcombank are not thoroughly tested.
