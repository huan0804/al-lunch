# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"Cơm trưa team" — a team lunch-ordering app for splitting a shared lunch order and collecting payment (cash or VietQR bank transfer). It runs as a **Claude Artifact**, not a normal web app: there is no build step, no package manager, no server. Read [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) in full before making changes — it is the authoritative spec (business rules, data model, UI states, known limitations, and a history of user corrections to avoid repeating). This CLAUDE.md summarizes structure; PROJECT_HANDOFF.md is the source of truth for behavior.

Files:
- `com-trua.html` — the entire app: HTML + CSS + vanilla JS in one file.
- `mock-runtime.js` — in-memory mock of `window.claude.use(...)` (the artifact runtime API) for testing outside Claude.
- `PROJECT_HANDOFF.md` — full product/business spec, written in Vietnamese.

## Running / testing locally

There is no build or test command. To smoke-test outside the Claude artifact host:

1. Inject `mock-runtime.js` before the page loads (e.g. Playwright `add_init_script(path="mock-runtime.js")`), then open `com-trua.html`.
2. The mock provides `db` (in-memory store with `onSnapshot`), `user` (id `u1`, host/owner), and `sample` (returns 2 canned dish names — stands in for AI menu-image parsing).
3. Drive the UI via `[data-a="..."]` selectors (event delegation attribute — see Architecture). The confirm-dialog sheet's accept button is `[data-a="ask-ok"]`.

There is no real test suite — verify changes manually via this mock, in a browser.

## Architecture

Everything lives in `com-trua.html`, vanilla JS, no framework, no dependencies except:
- `qrcode-generator@1.4.4` from cdnjs (client-side QR rendering)
- Be Vietnam Pro from Google Fonts

**State & rendering**
- All app state lives in a single object `S` (defined ~line 272: `view`, `sheet`, `cart`, `md`, `sf`, `ai`, `libQ`, `filter`, `busy`, `open`).
- `render()` redraws the entire `#app` and `#overlay` (bottom-sheet) on every state change, while preserving focus and cursor position of the currently-focused input.
- Events use delegation via `data-a` (action) and `data-f` (field) attributes — there are no inline `addEventListener` calls scattered through the view functions.
- `S.cart` is a draft order; it is only written to the db when the user confirms ("Xác nhận đặt món").
- `S.open` persists which `<details>` elements are expanded across re-renders.

**Persistence — Claude Artifact `db` API**
- Data access goes through `window.claude.use("db")`, `.use("user")`, `.use("sample")` — the Claude Artifact runtime, not a real backend. See `mock-runtime.js` for the shape of this API (`doc()`, `collection()`, `onSnapshot`, `get/set/update/delete`).
- Data model (config/sessions/orders/dishes) and access-control rules are documented in detail in PROJECT_HANDOFF.md §4. Orders are written via `mutateOrder(docId, sessionKey, fn)`, a read-modify-overwrite-whole-document pattern.
- AI menu-image reading uses `claude.use("sample")` → `sample.json(AI_PROMPT, { images: file })`; see PROJECT_HANDOFF.md §5 for error codes handled (`not_granted`, `rate_limited`, `image_rejected`, `invalid_json`, `images_unavailable`) — **not yet verified against a real image.**

**QR codes**
- VietQR payloads are built client-side per the EMVCo spec with manual CRC16 (`vietqr()`, `crc16()` in com-trua.html), then rendered via `qrcode-generator`. Deliberately does **not** use img.vietqr.io — the artifact's CSP blocks external images.

## Hard constraints of the Claude Artifact host (do not reintroduce these bugs)

- **No `confirm()` / `alert()`** — blocked by the host. Use the existing `ask(msg, ok, danger)` helper, which shows a bottom-sheet confirm dialog (`S.sheet = {kind:"confirm", ...}`), resolved via `closeAsk()`.
- **No dark mode, ever** — background must stay pure white (`<html data-theme="light">`), regardless of OS theme. This has been requested/enforced multiple times (see PROJECT_HANDOFF.md §10).
- **Cannot deep-link to external apps** — `navigator.share`, Zalo intents, Teams/Facebook share URLs all fail inside the artifact sandbox. Current workaround is "copy invite message" only. This is a primary motivator for the planned Vercel+Supabase migration (PROJECT_HANDOFF.md §8).
- UI must mimic Grab's group-ordering flow (bottom sheets, pill buttons, orange circular `+`) and stay within a 560px-max-width mobile layout.

## Key business rules (see PROJECT_HANDOFF.md §3 for full detail)

- Price per set: `setPrice(n) = Math.round(base * Math.max(n, 2) / 2 / 1000) * 1000` where `base` = `pricePerSet` (default 35,000₫). 1 dish = double portion at base price; 2 dishes = standard; 3+ scales up.
- A day can have multiple order sessions (`sessions/{YYYY-MM-DD[-suffix]}`); `config.current` points at the active one. Sessions lock when closed, past-dated, or (if `autoClose`) past `deadlineAt`; the host can always edit.
- "Đặt hộ" (order-on-behalf-of): one payer can order and pay for multiple named guests in a single order/QR/payment-confirmation, with per-guest dish tabs.
- Backward compatibility matters: older sessions/orders may lack fields like `hostName`, `deadlineAt`, `qty`, `guests`, `for` — code has defaulting helpers (`qtyOf`, `deadlineAt()`) for this; preserve that pattern when adding fields.

## Planned migration (not yet started)

User intends to eventually port this to Vercel + Supabase to escape the artifact sandbox (real external sharing, no Claude-org login requirement). Full migration plan is in PROJECT_HANDOFF.md §8 — covers replacing `db` with Supabase tables, `user.id()` with anon auth, host permission with a PIN/secret link, and AI image-reading with a server API route. Don't start this migration unless asked; keep the current artifact working in the meantime.
