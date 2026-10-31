# Tính năng Chia tiền nhóm (split bill) cho repo huan0804/al-lunch

File này gom toàn bộ thay đổi của tính năng Chia tiền nhóm. Đưa file này cho Claude (Claude Code / Claude Desktop) trong thư mục repo `al-lunch` và yêu cầu: **"Áp dụng toàn bộ thay đổi trong file này vào repo"**. Hoặc tự làm theo các bước bên dưới.

## Tóm tắt tính năng

- Host nhập tên sự kiện, tên mình, tài khoản nhận tiền (điền sẵn từ app cơm trưa), danh sách người tham gia (dán nhiều tên cách nhau bởi dấu phẩy được).
- Mỗi khoản chi: chi cho việc gì, số tiền (gõ được `300k`, `1,5tr`), ai đã chi, ai tham gia (có ô "Chọn tất cả" hoặc tick tay).
- App tính `net = đã chi − phần phải trả` cho từng người, thanh toán qua host làm trung gian:
  - `net < 0`: người đó quét VietQR chuyển `|net|` vào tài khoản host, bấm "Tôi đã chuyển khoản"; host bấm "Đã nhận tiền".
  - `net > 0`: host cần chuyển lại `net`; người đó gửi số tài khoản qua link xem (hoặc host nhập hộ / copy tin nhắn xin số tài khoản), host thấy QR để chuyển rồi bấm "Đã chuyển".
- Ba loại link: `split.html` (tạo mới), `split.html?manage=<manage_token>` (host), `split.html?view=<view_token>` (người tham gia chọn tên mình).

## Các bước áp dụng

1. **Supabase**: vào Dashboard → SQL Editor, chạy toàn bộ nội dung `split-schema.sql` (mục A bên dưới). An toàn khi chạy lại nhiều lần, không đụng tới bảng `sessions`/`orders`/`dishes`.
2. **Tạo file mới** `split.html` ở gốc repo với nội dung mục B. File dùng chung `supabase-config.js` sẵn có, không dùng `supabase-adapter.js`.
3. **Tạo file mới** `split-schema.sql` ở gốc repo với nội dung mục A.
4. **Sửa `index.html`** theo mục C (thêm nút "💸 Chia tiền nhóm" ở màn tạo đơn).
5. **Cập nhật tài liệu** `CLAUDE.md` và `WORK_LOG.md` theo mục D, E.
6. Commit, push. Vercel tự deploy.
7. Kiểm tra: mở `https://<domain>/split.html`, tạo một lần chia tiền nhỏ, mở link xem trên máy khác, chọn tên, thử gửi số tài khoản và "Tôi đã chuyển khoản", quay lại link quản lý xem trạng thái (trang tự cập nhật mỗi 10 giây).

## Lưu ý

- Bảng `split_events` khoá hoàn toàn với anon key (RLS bật, không policy, revoke quyền bảng). Mọi truy cập qua hàm `SECURITY DEFINER`. Link xem không lấy được `manage_token`, và chỉ thấy tên ngân hàng + 4 số cuối tài khoản nhận tiền của người khác.
- Trạng thái thanh toán lưu kèm số tiền lúc đánh dấu (`{s, amt}`). Sửa khoản chi làm số tiền của ai đó đổi thì trạng thái cũ của người đó tự mất hiệu lực.
- Đã test end-to-end bằng Playwright với RPC giả lập. **Chưa test với Supabase thật**; nếu RPC báo lỗi quyền, kiểm tra lại các dòng `grant execute` cuối file SQL đã chạy chưa.

---

## A. `split-schema.sql` (file mới)

```sql
-- ============================================================
-- Chia tiền nhóm (split bill) — bảng + RPC
-- Chạy toàn bộ file này trong Supabase Dashboard → SQL Editor.
-- An toàn khi chạy lại nhiều lần (IF NOT EXISTS / CREATE OR REPLACE).
--
-- Khác với bảng sessions/orders của app cơm trưa (RLS mở cho anon), bảng
-- split_events KHÓA HOÀN TOÀN với anon key: không có policy nào, nên mọi
-- truy cập phải đi qua các hàm SECURITY DEFINER bên dưới. Nhờ vậy:
--   - manage_token không bao giờ được trả về cho người cầm link xem (view).
--   - Số tài khoản nhận tiền của từng người chỉ hiện đầy đủ cho host;
--     người xem chỉ thấy tên ngân hàng + 4 số cuối của CHÍNH các dòng đó.
--   - Người cầm link xem chỉ làm được 2 việc: báo "đã chuyển khoản" và
--     gửi số tài khoản để nhận tiền hoàn lại.
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists split_events (
  id text primary key default encode(gen_random_bytes(8), 'hex'),
  manage_token text not null unique default encode(gen_random_bytes(16), 'hex'),
  view_token text not null unique default encode(gen_random_bytes(12), 'hex'),
  -- {title, hostName, bank:{bankBin,bankName,accountNo,accountName},
  --  people:[{id,name,isHost?}], expenses:[{id,title,amount,payerId,ids:[...]}]}
  data jsonb not null default '{}'::jsonb,
  -- {personId: {s: "claimed"|"confirmed"|"sent", amt: <số tiền lúc đổi trạng thái>}}
  -- amt dùng để client tự bỏ qua trạng thái cũ khi khoản chi bị sửa làm số tiền đổi.
  status jsonb not null default '{}'::jsonb,
  -- {personId: {bankBin,bankName,accountNo,accountName}} — tài khoản nhận tiền hoàn lại
  recv jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname='split_data_size') then
    alter table split_events add constraint split_data_size check (pg_column_size(data) < 200000);
  end if;
  if not exists (select 1 from pg_constraint where conname='split_status_size') then
    alter table split_events add constraint split_status_size check (pg_column_size(status) < 50000);
  end if;
  if not exists (select 1 from pg_constraint where conname='split_recv_size') then
    alter table split_events add constraint split_recv_size check (pg_column_size(recv) < 100000);
  end if;
end $$;

alter table split_events enable row level security;
-- Cố ý KHÔNG tạo policy nào: anon/authenticated không đọc/ghi trực tiếp được.
revoke all on split_events from anon, authenticated;

-- ---------- helpers ----------
create or replace function split_person_exists(p_data jsonb, p_person text)
returns boolean language sql immutable as $$
  select exists (select 1 from jsonb_array_elements(coalesce(p_data->'people','[]'::jsonb)) x where x->>'id' = p_person);
$$;

create or replace function split_valid_bank(p_bank jsonb)
returns boolean language sql immutable as $$
  select jsonb_typeof(p_bank) = 'object'
     and coalesce(p_bank->>'bankBin','') ~ '^\d{6}$'
     and coalesce(p_bank->>'accountNo','') ~ '^[0-9A-Za-z]{4,19}$'
     and length(coalesce(p_bank->>'bankName','')) <= 60
     and length(coalesce(p_bank->>'accountName','')) <= 60;
$$;

-- ---------- tạo / đọc / sửa / xoá (host) ----------
create or replace function split_create(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  if jsonb_typeof(p_data) <> 'object' then raise exception 'invalid data'; end if;
  insert into split_events (data) values (p_data) returning * into r;
  return jsonb_build_object('manage_token', r.manage_token, 'view_token', r.view_token, 'updated_at', r.updated_at);
end $$;

create or replace function split_get_manage(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  select * into r from split_events where manage_token = p_token;
  if not found then return null; end if;
  return jsonb_build_object('data', r.data, 'status', r.status, 'recv', r.recv,
    'view_token', r.view_token, 'updated_at', r.updated_at);
end $$;

create or replace function split_update(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  if jsonb_typeof(p_data) <> 'object' then raise exception 'invalid data'; end if;
  update split_events set data = p_data, updated_at = now() where manage_token = p_token returning * into r;
  if not found then raise exception 'not found'; end if;
  return jsonb_build_object('updated_at', r.updated_at);
end $$;

create or replace function split_set_status(p_token text, p_person text, p_status text, p_amount bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  if p_status not in ('unpaid','claimed','confirmed','sent') then raise exception 'invalid status'; end if;
  select * into r from split_events where manage_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  if p_status = 'unpaid' then
    update split_events set status = status - p_person, updated_at = now() where id = r.id;
  else
    update split_events set status = status || jsonb_build_object(p_person, jsonb_build_object('s', p_status, 'amt', p_amount)), updated_at = now() where id = r.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function split_set_recv_manage(p_token text, p_person text, p_bank jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  select * into r from split_events where manage_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  if p_bank is null then
    update split_events set recv = recv - p_person, updated_at = now() where id = r.id;
  else
    if not split_valid_bank(p_bank) then raise exception 'invalid bank'; end if;
    update split_events set recv = recv || jsonb_build_object(p_person, p_bank), updated_at = now() where id = r.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function split_delete(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  delete from split_events where manage_token = p_token;
  return jsonb_build_object('ok', found);
end $$;

-- ---------- người xem (link ?view=) ----------
create or replace function split_get_view(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events; masked jsonb;
begin
  select * into r from split_events where view_token = p_token;
  if not found then return null; end if;
  -- chỉ trả tên ngân hàng + 4 số cuối, không lộ số tài khoản đầy đủ của người khác
  select coalesce(jsonb_object_agg(key, jsonb_build_object('bankName', value->>'bankName', 'last4', right(value->>'accountNo', 4))), '{}'::jsonb)
    into masked from jsonb_each(r.recv);
  return jsonb_build_object('data', r.data, 'status', r.status, 'recv', masked, 'updated_at', r.updated_at);
end $$;

create or replace function split_claim(p_token text, p_person text, p_amount bigint, p_claim boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events; cur text;
begin
  select * into r from split_events where view_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  cur := r.status->p_person->>'s';
  -- người xem không được ghi đè trạng thái host đã chốt (đã nhận / đã chuyển)
  if cur in ('confirmed','sent') and (r.status->p_person->>'amt')::bigint = p_amount then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  if p_claim then
    update split_events set status = status || jsonb_build_object(p_person, jsonb_build_object('s','claimed','amt',p_amount)), updated_at = now() where id = r.id;
  else
    update split_events set status = status - p_person, updated_at = now() where id = r.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function split_set_recv(p_token text, p_person text, p_bank jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  select * into r from split_events where view_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  if not split_valid_bank(p_bank) then raise exception 'invalid bank'; end if;
  update split_events set recv = recv || jsonb_build_object(p_person, p_bank), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- quyền gọi hàm ----------
grant execute on function split_create(jsonb) to anon, authenticated;
grant execute on function split_get_manage(text) to anon, authenticated;
grant execute on function split_update(text, jsonb) to anon, authenticated;
grant execute on function split_set_status(text, text, text, bigint) to anon, authenticated;
grant execute on function split_set_recv_manage(text, text, jsonb) to anon, authenticated;
grant execute on function split_delete(text) to anon, authenticated;
grant execute on function split_get_view(text) to anon, authenticated;
grant execute on function split_claim(text, text, bigint, boolean) to anon, authenticated;
grant execute on function split_set_recv(text, text, jsonb) to anon, authenticated;
```

---

## B. `split.html` (file mới)

```html
<!DOCTYPE html>
<html lang="vi" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Chia tiền nhóm</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Be+Vietnam+Pro:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
<style>
:root{
  --bg:#FFFFFF; --surface:#FFFFFF; --ink:#111111; --muted:#6B6B6B; --line:#EAEAEA;
  --brand:#F7941D; --brand-ink:#111111; --brand-soft:#FFF1E0; --brand-deep:#D97706;
  --chili:#D32F2F; --chili-soft:#FDE7E7; --amber:#B45309; --amber-soft:#FDEBD3;
  --ok:#2E7D32; --ok-soft:#E6F3E7; --gray-soft:#F0F0F0; --yel-soft:#FFF6CC;
  --sel:#111111; --sel-ink:#FFFFFF;
  box-sizing:border-box; padding-top:env(safe-area-inset-top,0px); padding-bottom:env(safe-area-inset-bottom,0px);
  color-scheme:light;
}
*,*::before,*::after{box-sizing:border-box}
html{scroll-padding-top:env(safe-area-inset-top,0px)}
html,body{background:#FFFFFF}
body{margin:0;background:var(--bg);color:var(--ink);font-family:"Be Vietnam Pro",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;font-size:16px;line-height:1.45;-webkit-font-smoothing:antialiased}
button,input,select,textarea{font:inherit;color:inherit}
.num{font-variant-numeric:tabular-nums}
.page{max-width:560px;margin:0 auto;min-height:100vh;padding-bottom:130px}
.pad{padding:0 20px}
.band{height:1px;background:var(--line);margin:20px 0}
.muted{color:var(--muted)} .small{font-size:14px} .err{color:var(--chili)}
:focus-visible{outline:3px solid var(--ink);outline-offset:2px}
svg.i{width:22px;height:22px;flex:none;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.topbar{display:flex;align-items:center;gap:12px;padding:14px 16px;position:sticky;top:env(safe-area-inset-top,0px);background:var(--bg);z-index:5}
.topbar .tt{flex:1;min-width:0}
.topbar .tt b{display:block;font-size:19px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.topbar .tt small{color:var(--muted);font-size:14px}
.icon{width:42px;height:42px;border-radius:50%;border:0;background:none;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;flex:none;text-decoration:none;color:inherit}
.icon:hover{background:var(--gray-soft)}
.icon.soft{background:var(--brand-soft);color:var(--brand-deep)}
h2.sec{font-size:21px;font-weight:800;margin:0 0 4px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;border:1.5px solid var(--line);background:var(--surface);border-radius:999px;padding:8px 14px;font-weight:600;font-size:14px;cursor:pointer;white-space:nowrap;text-decoration:none;color:inherit}
.btn:hover{border-color:var(--ink)}
.btn.pri{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.btn.danger{color:var(--chili)}
.btn[disabled]{opacity:.45;cursor:not-allowed}
.link{border:0;background:none;color:var(--brand-deep);font-weight:700;font-size:16px;cursor:pointer;padding:4px 0}
.link.red{color:var(--chili)}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.between{display:flex;justify-content:space-between;align-items:center;gap:10px}
label.f{display:block;font-weight:600;font-size:14px;margin:0 0 6px}
input[type=text],input[type=search],select{width:100%;border:1.5px solid var(--line);background:var(--surface);border-radius:12px;padding:11px 12px;font-size:16px;outline:none}
input:focus,select:focus{border-color:var(--brand)}
.card{border:1.5px solid var(--line);border-radius:16px;padding:16px;margin-bottom:12px;background:var(--surface)}
.pills{display:flex;flex-wrap:wrap;gap:10px;margin-top:14px}
.pill{display:inline-flex;align-items:center;gap:8px;border:1.5px solid var(--line);background:var(--surface);border-radius:999px;padding:10px 16px;font-weight:600;font-size:15px;cursor:pointer;white-space:nowrap;text-decoration:none;color:inherit}
.pill.hl{border-color:var(--brand)}
.pill:hover{border-color:var(--ink)}
.bottom{position:fixed;left:0;right:0;bottom:0;background:var(--bg);box-shadow:0 -4px 18px rgba(0,0,0,.06);border-radius:18px 18px 0 0;padding:14px 16px calc(14px + env(safe-area-inset-bottom,0px));z-index:20}
.bottom .in{max-width:528px;margin:0 auto}
.cta{width:100%;border:0;border-radius:999px;background:var(--brand);color:var(--brand-ink);font-weight:700;font-size:17px;padding:16px 20px;cursor:pointer;display:flex;align-items:center;justify-content:center;gap:10px}
.cta.split{justify-content:space-between}
.cta[disabled]{background:var(--gray-soft);color:var(--muted);cursor:not-allowed}
.cta.ghost{background:var(--surface);border:1.5px solid var(--line);margin-top:10px}
.hint{text-align:center;font-size:13px;color:var(--chili);margin-top:8px}
.badge{display:inline-block;border-radius:999px;padding:3px 10px;font-size:13px;font-weight:600;white-space:nowrap}
.b-red{background:var(--chili-soft);color:var(--chili)} .b-yel{background:var(--yel-soft);color:var(--ink)}
.b-grn{background:var(--ok-soft);color:var(--ok)} .b-gry{background:var(--gray-soft);color:var(--muted)} .b-org{background:var(--amber-soft);color:var(--amber)}
.opt{display:flex;align-items:center;gap:14px;width:100%;border:0;background:none;padding:13px 0;border-bottom:1px solid var(--line);cursor:pointer;text-align:left}
.opt:last-child{border-bottom:0}
.opt .t{flex:1;min-width:0}
.opt .t b{display:block;font-weight:600}
.opt .t small{color:var(--muted);font-size:13px}
.radio,.cbox{width:22px;height:22px;border:2px solid #BDBDBD;flex:none;display:inline-flex;align-items:center;justify-content:center}
.radio{border-radius:50%} .cbox{border-radius:6px}
[aria-checked="true"] .radio{border:7px solid var(--brand)}
[aria-checked="true"] .cbox{background:var(--brand);border-color:var(--brand);color:var(--brand-ink)}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chip{display:inline-flex;align-items:center;gap:6px;border:1.5px solid var(--line);border-radius:999px;padding:6px 6px 6px 14px;font-weight:600;font-size:15px;background:var(--surface)}
.chip.host{border-color:var(--brand);background:var(--brand-soft)}
.chip button{width:26px;height:26px;border-radius:50%;border:0;background:var(--gray-soft);cursor:pointer;display:inline-flex;align-items:center;justify-content:center}
.chip button svg{width:14px;height:14px}
.chip.pick{padding:8px 14px;cursor:pointer}
.chip.pick[aria-pressed="true"]{background:var(--sel);border-color:var(--sel);color:var(--sel-ink)}
.addrow{display:flex;gap:8px;margin-top:12px}
.addrow input{flex:1}
.exp{display:flex;gap:12px;align-items:flex-start;padding:14px 0;border-bottom:1px solid var(--line);cursor:pointer;width:100%;background:none;border-left:0;border-right:0;border-top:0;text-align:left}
.exp:last-child{border-bottom:0}
.exp .d{flex:1;min-width:0}
.exp .d b{display:block;font-size:17px;font-weight:600}
.exp .d small{display:block;color:var(--muted);font-size:14px}
.exp .p{font-weight:700;font-size:17px}
/* the balance — each person on a centre line: pays to the left, receives to the right */
.bal{padding:12px 0;border-bottom:1px solid var(--line)}
.bal:last-child{border-bottom:0}
.bal .top{display:flex;justify-content:space-between;align-items:baseline;gap:10px}
.bal .top b{font-size:16px}
.bal .amt{font-weight:800;font-size:17px}
.bal .amt.neg{color:var(--chili)} .bal .amt.pos{color:var(--ok)} .bal .amt.zero{color:var(--muted)}
.beam{position:relative;height:10px;margin:8px 0 4px;background:var(--gray-soft);border-radius:999px}
.beam::after{content:"";position:absolute;left:50%;top:-4px;bottom:-4px;width:2px;background:var(--ink);border-radius:2px}
.beam i{position:absolute;top:0;bottom:0;border-radius:999px}
.beam i.neg{right:50%;background:var(--chili)}
.beam i.pos{left:50%;background:var(--ok)}
.bal .sub{font-size:13px;color:var(--muted)}
.legend{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);font-weight:600;margin-top:2px}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.stat{border:1.5px solid var(--line);border-radius:14px;padding:12px}
.stat small{display:block;color:var(--muted);font-size:13px;font-weight:600}
.stat b{font-size:20px;font-weight:800}
.stat.r b{color:var(--chili)} .stat.g b{color:var(--ok)}
.person{border:1.5px solid var(--line);border-radius:16px;padding:14px 16px;margin-bottom:10px}
.person .head{display:flex;align-items:center;gap:12px}
.person .head .nm{flex:1;min-width:0;font-weight:700;font-size:17px}
.person .acts{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.avatar{width:38px;height:38px;border-radius:50%;background:var(--brand-soft);color:var(--brand-deep);display:inline-flex;align-items:center;justify-content:center;font-weight:700;flex:none;text-transform:uppercase}
.qrbox{display:flex;gap:16px;align-items:flex-start;flex-wrap:wrap;margin-top:12px}
.qr{background:#fff;border:1px solid var(--line);border-radius:14px;padding:6px;line-height:0}
.qr svg{width:200px;height:200px;display:block}
.kv{flex:1;min-width:220px}
.kv div{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--line)}
.kv div:last-child{border-bottom:0}
.kv span{color:var(--muted);font-size:14px}
.kv b{word-break:break-all;text-align:right;flex:1}
.note{border:1.5px solid var(--line);border-radius:12px;padding:12px 14px;font-size:14px}
.note.ok{border-color:var(--ok-soft);background:var(--ok-soft)}
details.more summary{cursor:pointer;font-weight:600;padding:10px 0;list-style:none;display:flex;justify-content:space-between;align-items:center}
details.more summary::-webkit-details-marker{display:none}
.scrim{position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:40}
.sheet{position:fixed;left:0;right:0;bottom:0;z-index:41;background:var(--bg);border-radius:22px 22px 0 0;max-height:90vh;overflow:auto;padding:8px 20px calc(20px + env(safe-area-inset-bottom,0px));max-width:560px;margin:0 auto}
.sheet .grab{width:44px;height:5px;border-radius:9px;background:#D6D6D6;margin:6px auto 12px}
.sheet h3{font-size:21px;margin:0 0 2px;font-weight:800}
.req{display:flex;justify-content:space-between;align-items:center;margin:16px 0 6px}
.req b{font-size:17px}
.req span{font-size:12px;font-weight:700;background:var(--gray-soft);border-radius:6px;padding:3px 8px}
.allrow{display:flex;align-items:center;gap:14px;width:100%;border:1.5px solid var(--line);border-radius:12px;background:var(--surface);padding:12px 14px;cursor:pointer;text-align:left;font-weight:700;margin-bottom:4px}
.allrow .t{flex:1}
.msgbox{border:1.5px solid var(--line);border-radius:12px;padding:12px;font-size:14px;white-space:pre-wrap;word-break:break-word}
.toast{position:fixed;left:50%;bottom:calc(110px + env(safe-area-inset-bottom,0px));transform:translateX(-50%);background:#111;color:#fff;padding:10px 16px;border-radius:12px;font-size:14px;font-weight:600;z-index:60;opacity:0;pointer-events:none;transition:opacity .2s;max-width:90vw;text-align:center}
.toast.on{opacity:1}
.spin{display:inline-block;width:14px;height:14px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:sp .8s linear infinite;vertical-align:-2px}
.boot{min-height:70vh;display:flex;align-items:center;justify-content:center;color:var(--brand)}
.boot .spin{width:42px;height:42px;border-width:4px}
@keyframes sp{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.spin{animation:none}.toast{transition:none}}
.empty{text-align:center;padding:30px 10px}
.empty b{display:block;font-size:19px;margin-bottom:4px}
</style>
</head>
<body>
<div id="app"><div class="boot"><span class="spin"></span></div></div>
<div id="overlay"></div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<script src="./supabase-config.js"></script>
<script>
/* ================= Helpers (giống index.html) ================= */
const BANKS = [
  ["Vietcombank","970436"],["VietinBank","970415"],["BIDV","970418"],["Agribank","970405"],
  ["Techcombank","970407"],["MB Bank","970422"],["ACB","970416"],["VPBank","970432"],
  ["TPBank","970423"],["Sacombank","970403"],["HDBank","970437"],["VIB","970441"],
  ["SHB","970443"],["Eximbank","970431"],["MSB","970426"],["OCB","970448"],
  ["SeABank","970440"],["LPBank","970449"],["Nam A Bank","970428"],["Bac A Bank","970409"],
  ["BVBank (Timo)","970454"],["ABBANK","970425"],["PVcomBank","970412"],["Kienlongbank","970452"],
  ["NCB","970419"],["VietABank","970427"],["Cake by VPBank","546034"],["Shinhan Bank","970424"],
  ["Woori Bank","970457"],["UOB","970458"]
];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const money = n => Math.round(Number(n)||0).toLocaleString("vi-VN") + "đ";
const clone = o => JSON.parse(JSON.stringify(o ?? null));
const rid = () => Math.random().toString(36).slice(2, 10);
function norm(s){ return String(s||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/đ/g,"d").replace(/Đ/g,"D").toLowerCase().replace(/\s+/g," ").trim(); }
function ascii(s){ return norm(s).toUpperCase().replace(/[^A-Z0-9 ]/g,"").replace(/\s+/g," ").trim(); }
function lsGet(k){ try{ return localStorage.getItem(k); }catch{ return null; } }
function lsSet(k,v){ try{ localStorage.setItem(k,v); }catch{} }
const tlv = (id,v) => id + String(v.length).padStart(2,"0") + v;
function crc16(str){ let c=0xFFFF; for(let i=0;i<str.length;i++){ c^=str.charCodeAt(i)<<8; for(let j=0;j<8;j++){ c=(c&0x8000)?((c<<1)^0x1021):(c<<1); c&=0xFFFF; } } return c.toString(16).toUpperCase().padStart(4,"0"); }
function vietqr(bin, acc, amount, info){
  const bene = tlv("00",bin) + tlv("01",acc);
  const mai = tlv("00","A000000727") + tlv("01",bene) + tlv("02","QRIBFTTA");
  let p = tlv("00","01") + tlv("01", amount ? "12" : "11") + tlv("38",mai) + tlv("53","704")
    + (amount ? tlv("54", String(Math.round(amount))) : "") + tlv("58","VN")
    + (info ? tlv("62", tlv("08", info)) : "") + "6304";
  return p + crc16(p);
}
function qrSvg(payload){ if (typeof qrcode === "undefined") return ""; try{ const q=qrcode(0,"M"); q.addData(payload); q.make(); return q.createSvgTag(6,12); }catch{ return ""; } }
function toast(msg){ const t=document.getElementById("toast"); t.textContent=msg; t.classList.add("on"); clearTimeout(toast._t); toast._t=setTimeout(()=>t.classList.remove("on"),2800); }
async function copyText(t, msg="Đã copy"){
  try{ await navigator.clipboard.writeText(t); toast(msg); return true; }catch{}
  const ta=document.createElement("textarea"); ta.value=t; ta.style.position="fixed"; ta.style.opacity="0"; document.body.appendChild(ta); ta.select();
  let ok=false; try{ ok=document.execCommand("copy"); }catch{} ta.remove();
  toast(ok ? msg : "Trình duyệt chặn copy, hãy chọn và copy thủ công"); return ok;
}
/* "1.250.000", "250k", "1,5tr", "2tr" → số đồng */
function parseMoney(s){
  s=String(s||"").trim().toLowerCase().replace(/\s+/g,"").replace(/đ|vnd/g,"");
  const m=s.match(/^([\d.,]+)(k|tr|m|trieu|nghin)?$/); if(!m) return NaN;
  let num=m[1];
  if (m[2]){ num=Number(num.replace(",",".")); if(isNaN(num)) return NaN; return Math.round(num*(m[2]==="k"||m[2]==="nghin"?1000:1000000)); }
  return Number(num.replace(/[.,]/g,""));
}
const I = {
  back:'<svg class="i" viewBox="0 0 24 24"><path d="M19 12H5M11 5l-7 7 7 7"/></svg>',
  close:'<svg class="i" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  plus:'<svg class="i" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
  pen:'<svg class="i" viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16v4z"/></svg>',
  share:'<svg class="i" viewBox="0 0 24 24"><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="6" r="2.5"/><circle cx="18" cy="18" r="2.5"/><path d="M8.2 10.8l7.6-3.6M8.2 13.2l7.6 3.6"/></svg>',
  link:'<svg class="i" viewBox="0 0 24 24"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></svg>',
  chev:'<svg class="i" viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg>',
  bowl:'<svg class="i" viewBox="0 0 24 24"><path d="M3 11h18a9 9 0 0 1-18 0zM8 7c0-1 1-1 1-2M12 7c0-1 1-1 1-2M16 7c0-1 1-1 1-2"/></svg>',
  clock:'<svg class="i" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
  check:'<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5 9-10"/></svg>'
};

/* ================= Supabase ================= */
const sb = window.supabase?.createClient && window.SUPABASE_URL ? window.supabase.createClient(window.SUPABASE_URL, window.SUPABASE_ANON_KEY) : null;
async function rpc(fn, args){
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}
const qs = new URLSearchParams(location.search);
const BASE = location.origin + location.pathname;

/* ================= State ================= */
const S = {
  mode: qs.get("manage") ? "manage" : qs.get("view") ? "view" : "create",
  token: qs.get("manage") || qs.get("view") || null,
  viewToken: null, loaded:false, notFound:false,
  ev: null, status:{}, recv:{}, updatedAt:null,
  view: "edit", sheet:null, busy:false, dirty:false, open:{}, newName:"", filter:"all",
  me: null, recvForm:null, showQr:{}
};
function blankEvent(){
  const bank = (()=>{ try{ return JSON.parse(lsGet("comtrua:lastBank")||"null"); }catch{ return null; } })() || {};
  return { title:"", hostName: lsGet("comtrua:name")||"",
    bank:{ bankBin: bank.bankBin||"970436", bankName: bank.bankName||"Vietcombank", accountNo: bank.accountNo||"", accountName: bank.accountName||"" },
    people:[{ id:"host", name: lsGet("comtrua:name")||"", isHost:true }], expenses:[] };
}
const people = () => S.ev?.people || [];
const host = () => people().find(p=>p.isHost) || people()[0];
const nameOf = id => people().find(p=>p.id===id)?.name || "?";
const displayName = p => p.isHost ? `${p.name||"Bạn"} (host)` : p.name;

/* ================= Tính toán ================= */
// Chia đều từng khoản theo số đồng nguyên; phần dư (vài đồng) dồn cho những
// người đầu danh sách để tổng phần chia luôn đúng bằng số tiền khoản chi.
function compute(ev){
  const paid={}, share={}, parts={};
  ev.people.forEach(p=>{ paid[p.id]=0; share[p.id]=0; parts[p.id]=[]; });
  let total=0;
  ev.expenses.forEach(e=>{
    const ids=(e.ids||[]).filter(id=>id in share), amt=Math.round(Number(e.amount)||0);
    if (!amt || !ids.length || !(e.payerId in paid)) return;
    total+=amt; paid[e.payerId]+=amt;
    const base=Math.floor(amt/ids.length); let rem=amt-base*ids.length;
    ids.forEach(id=>{ const s=base+(rem>0?1:0); if(rem>0) rem--; share[id]+=s; parts[id].push({id:e.id, title:e.title, amt:s}); });
  });
  const rows=ev.people.map(p=>({ ...p, paid:paid[p.id], share:share[p.id], net:paid[p.id]-share[p.id], parts:parts[p.id] }));
  const others=rows.filter(r=>!r.isHost);
  const toCollect=others.filter(r=>r.net<0).reduce((a,r)=>a-r.net,0);
  const toRefund=others.filter(r=>r.net>0).reduce((a,r)=>a+r.net,0);
  return { rows, total, toCollect, toRefund };
}
// Trạng thái chỉ còn hiệu lực nếu số tiền lúc đánh dấu khớp số tiền hiện tại.
function stOf(pid, amt){ const x=S.status?.[pid]; return x && Number(x.amt)===Math.abs(amt) ? x.s : "unpaid"; }
function badgeOf(r){
  if (r.isHost) return ["Host","b-gry"];
  if (r.net===0) return ["Không cần trả","b-gry"];
  const s=stOf(r.id, r.net);
  if (r.net<0) return s==="confirmed" ? ["Đã nhận tiền","b-grn"] : s==="claimed" ? ["Báo đã chuyển","b-yel"] : ["Chưa trả","b-red"];
  return s==="sent" ? ["Đã hoàn tiền","b-grn"] : S.recv?.[r.id] ? ["Đã gửi số tài khoản","b-org"] : ["Chờ số tài khoản","b-org"];
}
const transferNote = (title, name) => (ascii(name)+" "+ascii(title)).trim().slice(0,25);
const refundNote = title => ascii("Hoan tien "+title).slice(0,25);

/* ================= Lưu / tải ================= */
const DRAFT_KEY="split:draft", HIST_KEY="split:history";
function saveDraft(){ if (S.mode==="create") lsSet(DRAFT_KEY, JSON.stringify(S.ev)); }
function loadHist(){ try{ return JSON.parse(lsGet(HIST_KEY)||"[]"); }catch{ return []; } }
function addHist(entry){ const h=loadHist().filter(x=>x.link!==entry.link); h.unshift(entry); lsSet(HIST_KEY, JSON.stringify(h.slice(0,30))); }
const viewLink = () => S.viewToken ? `${BASE}?view=${S.viewToken}` : "";
const manageLink = () => S.mode==="manage" ? `${BASE}?manage=${S.token}` : "";

async function load(silent){
  try{
    if (S.mode==="manage"){
      const r=await rpc("split_get_manage",{p_token:S.token});
      if (!r){ S.notFound=true; }
      else { if (!S.dirty) S.ev=r.data; S.status=r.status||{}; S.recv=r.recv||{}; S.viewToken=r.view_token; S.updatedAt=r.updated_at; }
    } else if (S.mode==="view"){
      const r=await rpc("split_get_view",{p_token:S.token});
      if (!r){ S.notFound=true; }
      else { S.ev=r.data; S.status=r.status||{}; S.recv=r.recv||{}; S.viewToken=S.token; S.updatedAt=r.updated_at;
        const me=lsGet("split:me:"+S.token); if (me && people().some(p=>p.id===me)) S.me=me; }
    }
  }catch(e){ console.error(e); if(!silent) toast("Không tải được dữ liệu, thử tải lại trang"); }
}

function validateEvent(ev){
  if (!ev.title.trim()) return "Nhập tên sự kiện";
  if (!host()?.name.trim()) return "Nhập tên của bạn (host)";
  if (!/^\d{6}$/.test(ev.bank.bankBin||"")) return "Mã BIN ngân hàng phải gồm 6 số";
  if (!/^[0-9A-Za-z]{4,19}$/.test((ev.bank.accountNo||"").trim())) return "Nhập số tài khoản nhận tiền";
  if (ev.people.length<2) return "Thêm ít nhất 1 người tham gia";
  if (!ev.expenses.length) return "Thêm ít nhất 1 khoản chi";
  return null;
}
function cleanEvent(ev){
  const e=clone(ev);
  e.title=e.title.trim(); e.hostName=host().name.trim();
  e.bank.accountNo=e.bank.accountNo.trim(); e.bank.accountName=ascii(e.bank.accountName);
  e.people=e.people.map(p=>({ ...p, name:p.name.trim() }));
  return e;
}
async function saveEvent(){
  const err=validateEvent(S.ev); if (err){ toast(err); return; }
  const ev=cleanEvent(S.ev);
  S.busy=true; render();
  try{
    lsSet("comtrua:lastBank", JSON.stringify(ev.bank)); lsSet("comtrua:name", ev.hostName);
    if (S.mode==="create"){
      const r=await rpc("split_create",{p_data:ev});
      S.mode="manage"; S.token=r.manage_token; S.viewToken=r.view_token; S.ev=ev; S.dirty=false;
      history.replaceState(null,"",`?manage=${r.manage_token}`);
      try{ localStorage.removeItem(DRAFT_KEY); }catch{}
      S.view="result"; S.sheet={kind:"share"};
      toast("Đã tạo. Gửi link cho mọi người nhé");
    } else {
      await rpc("split_update",{p_token:S.token, p_data:ev});
      S.ev=ev; S.dirty=false; S.view="result"; toast("Đã lưu thay đổi");
    }
    addHist({ title:ev.title, at:Date.now(), role:"host", link:manageLink() });
  }catch(e){ console.error(e); toast("Không lưu được, thử lại sau ít giây"); }
  S.busy=false; render(); window.scrollTo({top:0});
}

/* ================= Render ================= */
const app=document.getElementById("app"), overlay=document.getElementById("overlay");
function render(){
  const ae=document.activeElement, fid=ae?.id; let s1=null,s2=null; try{ s1=ae.selectionStart; s2=ae.selectionEnd; }catch{}
  app.innerHTML=viewHtml(); overlay.innerHTML=sheetHtml();
  if (fid){ const el=document.getElementById(fid); if(el){ el.focus({preventScroll:true}); try{ if(s1!=null) el.setSelectionRange(s1,s2); }catch{} } }
}
function topbar(title, sub, left, right=""){
  return `<div class="topbar">${left||""}<div class="tt"><b>${esc(title)}</b>${sub?`<small>${esc(sub)}</small>`:""}</div>${right}</div>`;
}
function viewHtml(){
  if (!sb) return `<div class="page"><div class="empty" style="padding-top:60px"><b>Thiếu cấu hình Supabase</b><p class="muted">Kiểm tra supabase-config.js.</p></div></div>`;
  if (!S.loaded) return `<div class="boot"><span class="spin"></span></div>`;
  if (S.notFound) return `<div class="page"><div class="empty" style="padding-top:60px"><b>Không tìm thấy lần chia tiền này</b><p class="muted">Link có thể đã bị xoá hoặc gõ sai.</p><a class="btn pri" href="${BASE}">Tạo lần chia tiền mới</a></div></div>`;
  if (S.mode==="view") return guestView();
  if (S.view==="edit") return editView();
  return resultView();
}

/* ---------- Host: nhập liệu ---------- */
function editView(){
  const ev=S.ev, c=compute(ev), creating=S.mode==="create";
  const left = creating ? `<a class="icon" href="./" aria-label="Về app cơm trưa">${I.bowl}</a>` : `<button class="icon" data-a="to-result" aria-label="Quay lại">${I.back}</button>`;
  const b=ev.bank, known=BANKS.some(x=>x[1]===b.bankBin);
  const bankLine = b.accountNo ? `${esc(b.bankName||"")} ${esc(String(b.accountNo).slice(-4).padStart(8,"•"))}` : `<span class="err">Chưa nhập số tài khoản</span>`;
  const hist = creating ? loadHist() : [];
  const err=validateEvent(ev);
  const pp=people();
  return `<div class="page">${topbar(creating?"Chia tiền nhóm":"Sửa khoản chi", ev.title||"Nhập người tham gia và các khoản đã chi", left)}
  <div class="pad">
    ${creating && hist.length ? `<details class="more" data-k="hist" ${S.open.hist?"open":""}><summary><span>${I.clock} Các lần chia tiền trước (${hist.length})</span>${I.chev}</summary>
      ${hist.map(h=>`<a class="opt" href="${esc(h.link)}" style="text-decoration:none;color:inherit"><span class="t"><b>${esc(h.title)}</b><small>${new Date(h.at).toLocaleString("vi-VN",{hour:"2-digit",minute:"2-digit",day:"2-digit",month:"2-digit"})}${h.role==="host"?", bạn là host":""}</small></span>${I.chev}</a>`).join("")}</details>` : ""}
    <div style="display:grid;gap:12px;margin-top:4px">
      <div><label class="f" for="ev-title">Tên sự kiện</label><input type="text" id="ev-title" data-f="title" value="${esc(ev.title)}" placeholder="VD: Team building Vũng Tàu" maxlength="60"></div>
      <div><label class="f" for="ev-host">Tên của bạn</label><input type="text" id="ev-host" data-f="host" value="${esc(host()?.name||"")}" placeholder="VD: Han" maxlength="40"></div>
    </div>
    <details class="more" data-k="bank" ${S.open.bank!==false && !b.accountNo ? "open" : S.open.bank?"open":""} style="border-top:1px solid var(--line);margin-top:16px;padding-top:6px">
      <summary><span><b>Tài khoản nhận tiền</b> ${bankLine}</span>${I.chev}</summary>
      <div style="display:grid;gap:12px;padding-bottom:8px">
        <div><label class="f" for="b-bank">Ngân hàng</label><select id="b-bank" data-f="b-bank">${BANKS.map(x=>`<option value="${x[1]}" ${x[1]===b.bankBin?"selected":""}>${esc(x[0])}</option>`).join("")}<option value="other" ${!known?"selected":""}>Ngân hàng khác (nhập mã BIN)</option></select></div>
        ${!known?`<div><label class="f" for="b-bin">Mã BIN ngân hàng (6 số)</label><input type="text" id="b-bin" data-f="b-bin" inputmode="numeric" value="${esc(b.bankBin)}"></div>`:""}
        <div><label class="f" for="b-acc">Số tài khoản</label><input type="text" id="b-acc" data-f="b-acc" inputmode="numeric" value="${esc(b.accountNo)}"></div>
        <div><label class="f" for="b-name">Tên chủ tài khoản</label><input type="text" id="b-name" data-f="b-name" value="${esc(b.accountName)}" placeholder="NGUYEN VAN A"></div>
        <p class="small muted" style="margin:0">Người cần trả thêm sẽ quét QR chuyển vào tài khoản này.</p>
      </div>
    </details>
  </div>
  <div class="band"></div>
  <div class="pad">
    <h2 class="sec">Người tham gia (${pp.length})</h2>
    <p class="small muted" style="margin:0 0 10px">Bạn là host, luôn có trong danh sách. Bấm × để bỏ một người.</p>
    <div class="chips">${pp.map(p=>`<span class="chip ${p.isHost?"host":""}">${esc(displayName(p))}${p.isHost?"":`<button data-a="del-person" data-v="${esc(p.id)}" aria-label="Bỏ ${esc(p.name)}">${I.close}</button>`}</span>`).join("")}${p_pad(pp)}</div>
    <div class="addrow"><input type="text" id="new-name" data-f="new-name" value="${esc(S.newName)}" placeholder="Nhập tên, có thể dán nhiều tên cách nhau bởi dấu phẩy" maxlength="400" enterkeyhint="done"><button class="btn pri" data-a="add-person">Thêm</button></div>
  </div>
  <div class="band"></div>
  <div class="pad">
    <div class="between"><h2 class="sec">Khoản chi (${ev.expenses.length})</h2>${ev.expenses.length?`<b class="num">${money(c.total)}</b>`:""}</div>
    ${ev.expenses.length ? ev.expenses.map((e,i)=>{ const n=(e.ids||[]).length; return `<button class="exp" data-a="edit-exp" data-i="${i}"><div class="d"><b>${esc(e.title)}</b><small>${esc(nameOf(e.payerId))} đã chi, chia ${n===pp.length?"cả nhóm":n+" người"}${n?`, mỗi người khoảng ${money(Math.round(e.amount/n))}`:""}</small></div><span class="p num">${money(e.amount)}</span></button>`; }).join("")
      : `<p class="muted">Chưa có khoản chi nào. Ví dụ: tiền phòng, tiền xe, ăn tối…</p>`}
    <button class="btn" data-a="new-exp" style="margin-top:10px" ${pp.length<2?"disabled":""}>${I.plus} Thêm khoản chi</button>
    ${pp.length<2?`<p class="small muted">Thêm người tham gia trước khi nhập khoản chi.</p>`:""}
  </div>
  ${ev.expenses.length ? `<div class="band"></div><div class="pad"><h2 class="sec">Kết quả tạm tính</h2>${balanceList(c)}</div>` : ""}
  <div class="bottom"><div class="in"><button class="cta" data-a="save" ${err||S.busy?"disabled":""}>${S.busy?'<span class="spin"></span>':""} ${creating?"Tạo và gửi cho mọi người":"Lưu thay đổi"}</button>${err?`<div class="hint">${esc(err)}</div>`:""}</div></div>
  </div>`;
}
function p_pad(pp){ return pp.length<2 ? `<span class="small muted" style="align-self:center">Chưa có ai khác</span>` : ""; }

/* cán cân: trả thêm lệch trái (đỏ), nhận lại lệch phải (xanh) */
function balanceList(c){
  const max=Math.max(1, ...c.rows.map(r=>Math.abs(r.net)));
  return `<div class="legend"><span>Cần trả thêm</span><span>Nhận lại</span></div>` + c.rows.map(r=>{
    const w=Math.round(Math.abs(r.net)/max*50);
    const cls=r.net<0?"neg":r.net>0?"pos":"zero";
    const who = S.mode==="view" ? r.name : "Bạn";
    const txt = r.isHost ? (r.net<0?`Phần của ${S.mode==="view"?r.name:"bạn"} ${money(-r.net)}, trừ vào tiền thu`:r.net>0?`${who} ứng trước ${money(r.net)}`:"Cân bằng")
      : r.net<0?`Trả thêm ${money(-r.net)}`:r.net>0?`Nhận lại ${money(r.net)}`:"Không cần trả";
    return `<div class="bal"><div class="top"><b>${esc(displayName(r))}</b><span class="amt num ${cls}">${txt}</span></div>
      <div class="beam" aria-hidden="true">${r.net?`<i class="${cls}" style="width:${w}%"></i>`:""}</div>
      <div class="sub num">Đã chi ${money(r.paid)}, phần phải trả ${money(r.share)}</div></div>`;
  }).join("");
}

/* ---------- Host: kết quả + thu/chi ---------- */
function resultView(){
  const ev=S.ev, c=compute(ev), h=host();
  const owe=c.rows.filter(r=>!r.isHost && r.net<0), get=c.rows.filter(r=>!r.isHost && r.net>0);
  const collected=owe.filter(r=>stOf(r.id,r.net)==="confirmed").reduce((a,r)=>a-r.net,0);
  const refunded=get.filter(r=>stOf(r.id,r.net)==="sent").reduce((a,r)=>a+r.net,0);
  return `<div class="page">${topbar(ev.title, `${people().length} người, tổng chi ${money(c.total)}`, `<a class="icon" href="./" aria-label="Về app cơm trưa">${I.bowl}</a>`, `<button class="pill" style="padding:8px 14px" data-a="share">${I.share} Gửi link</button>`)}
  <div class="pad">
    <div class="stats">
      <div class="stat r"><small>Cần thu về (${owe.length} người)</small><b class="num">${money(c.toCollect-collected)}</b><div class="small muted">Đã nhận ${money(collected)}</div></div>
      <div class="stat g"><small>Cần chuyển lại (${get.length} người)</small><b class="num">${money(c.toRefund-refunded)}</b><div class="small muted">Đã chuyển ${money(refunded)}</div></div>
    </div>
    <div class="pills"><button class="pill" data-a="to-edit">${I.pen} Sửa khoản chi</button><button class="pill" data-a="copy-summary">${I.link} Copy bảng tổng kết</button></div>
  </div>
  <div class="band"></div>
  <div class="pad"><h2 class="sec" style="margin-bottom:10px">Cần trả cho bạn</h2>
    ${owe.length ? owe.map(r=>owePerson(r)).join("") : `<p class="muted">Không ai cần trả thêm.</p>`}
  </div>
  <div class="band"></div>
  <div class="pad"><h2 class="sec" style="margin-bottom:4px">Bạn cần chuyển lại</h2>
    <p class="small muted" style="margin:0 0 10px">Người nhận tự gửi số tài khoản qua link chia sẻ, hoặc bạn nhập hộ. Có số tài khoản là có QR để quét.</p>
    ${get.length ? get.map(r=>getPerson(r)).join("") : `<p class="muted">Không cần chuyển lại cho ai.</p>`}
  </div>
  <div class="band"></div>
  <div class="pad"><h2 class="sec">Cán cân cả nhóm</h2>${balanceList(c)}
    <details class="more" data-k="exps" ${S.open.exps?"open":""} style="margin-top:8px"><summary><span>Các khoản chi (${ev.expenses.length})</span>${I.chev}</summary>
      ${ev.expenses.map(e=>`<div class="exp" style="cursor:default"><div class="d"><b>${esc(e.title)}</b><small>${esc(nameOf(e.payerId))} chi, chia cho: ${esc((e.ids||[]).map(nameOf).join(", "))}</small></div><span class="p num">${money(e.amount)}</span></div>`).join("")}
    </details>
  </div>
  <div class="pad" style="text-align:center;margin-top:24px"><button class="link red" data-a="delete">Xoá lần chia tiền này</button></div>
  </div>`;
}
function owePerson(r){
  const amt=-r.net, s=stOf(r.id,r.net), [l,cls]=badgeOf(r), h=host();
  const info=transferNote(S.ev.title, r.name);
  const qrOpen=S.showQr[r.id];
  return `<div class="person"><div class="head"><span class="avatar">${esc(r.name.trim()[0]||"?")}</span><div class="nm">${esc(r.name)}<div class="small muted num" style="font-weight:500">Trả ${money(amt)}</div></div><span class="badge ${cls}">${l}</span></div>
    ${qrOpen?qrPanel(S.ev.bank, amt, info, `Chuyển cho ${h.name}`):""}
    <div class="acts">
      ${s==="confirmed" ? `<button class="btn" data-a="st" data-v="${esc(r.id)}" data-s="unpaid">Hoàn tác</button>`
        : `<button class="btn pri" data-a="st" data-v="${esc(r.id)}" data-s="confirmed">Đã nhận tiền</button><button class="btn" data-a="toggle-qr" data-v="${esc(r.id)}">${qrOpen?"Ẩn QR":"Hiện QR để quét"}</button>`}
    </div></div>`;
}
function getPerson(r){
  const amt=r.net, s=stOf(r.id,r.net), [l,cls]=badgeOf(r), acc=S.recv?.[r.id];
  const info=refundNote(S.ev.title);
  const qrOpen=S.showQr[r.id];
  const form = S.recvForm?.pid===r.id ? recvFormHtml("rf") : "";
  const askMsg=`Chào ${r.name}, mình cần chuyển lại cho bạn ${money(amt)} từ "${S.ev.title}". Bạn mở link này và gửi số tài khoản giúp mình nhé:\n${viewLink()}`;
  return `<div class="person"><div class="head"><span class="avatar">${esc(r.name.trim()[0]||"?")}</span><div class="nm">${esc(r.name)}<div class="small muted num" style="font-weight:500">Nhận lại ${money(amt)}</div></div><span class="badge ${cls}">${l}</span></div>
    ${acc ? `<div class="small" style="margin-top:8px">Tài khoản: <b>${esc(acc.bankName||acc.bankBin)} ${esc(acc.accountNo)}</b>${acc.accountName?`, ${esc(acc.accountName)}`:""}</div>` : ""}
    ${acc && qrOpen ? qrPanel(acc, amt, info, `Chuyển cho ${r.name}`) : ""}
    ${form}
    <div class="acts">
      ${s==="sent" ? `<button class="btn" data-a="st" data-v="${esc(r.id)}" data-s="unpaid">Hoàn tác</button>` : `
        ${acc?`<button class="btn" data-a="toggle-qr" data-v="${esc(r.id)}">${qrOpen?"Ẩn QR":"Hiện QR để chuyển"}</button>`:`<button class="btn" data-a="copy" data-t="${esc(askMsg)}">Copy tin nhắn xin số tài khoản</button>`}
        ${form?"":`<button class="btn" data-a="recv-edit" data-v="${esc(r.id)}">${acc?"Sửa tài khoản":"Nhập hộ tài khoản"}</button>`}
        <button class="btn pri" data-a="st" data-v="${esc(r.id)}" data-s="sent">Đã chuyển</button>`}
    </div></div>`;
}
function qrPanel(bank, amount, info, caption){
  const svg=qrSvg(vietqr(bank.bankBin, bank.accountNo, amount, info));
  return `<div class="qrbox">${svg?`<div class="qr" aria-label="Mã QR chuyển khoản">${svg}</div>`:""}<div class="kv">
    <div><span>${esc(caption)}</span><b>${esc(bank.bankName||bank.bankBin)}</b></div>
    <div><span>Số tài khoản</span><b class="num">${esc(bank.accountNo)}</b><button class="btn" data-a="copy" data-t="${esc(bank.accountNo)}">Copy</button></div>
    ${bank.accountName?`<div><span>Chủ tài khoản</span><b>${esc(bank.accountName)}</b></div>`:""}
    <div><span>Số tiền</span><b class="num">${money(amount)}</b><button class="btn" data-a="copy" data-t="${Math.round(amount)}">Copy</button></div>
    <div><span>Nội dung</span><b>${esc(info)}</b></div></div></div>`;
}
function recvFormHtml(prefix){
  const f=S.recvForm, known=BANKS.some(x=>x[1]===f.bankBin);
  return `<div style="display:grid;gap:10px;margin-top:12px">
    <div><label class="f" for="${prefix}-bank">Ngân hàng</label><select id="${prefix}-bank" data-f="rf-bank">${BANKS.map(x=>`<option value="${x[1]}" ${x[1]===f.bankBin?"selected":""}>${esc(x[0])}</option>`).join("")}<option value="other" ${!known?"selected":""}>Ngân hàng khác (nhập mã BIN)</option></select></div>
    ${!known?`<div><label class="f" for="${prefix}-bin">Mã BIN (6 số)</label><input type="text" id="${prefix}-bin" data-f="rf-bin" inputmode="numeric" value="${esc(f.bankBin)}"></div>`:""}
    <div><label class="f" for="${prefix}-acc">Số tài khoản</label><input type="text" id="${prefix}-acc" data-f="rf-acc" inputmode="numeric" value="${esc(f.accountNo)}"></div>
    <div><label class="f" for="${prefix}-name">Tên chủ tài khoản</label><input type="text" id="${prefix}-name" data-f="rf-name" value="${esc(f.accountName)}" placeholder="NGUYEN VAN A"></div>
    <div class="row"><button class="btn pri" data-a="recv-save" ${S.busy?"disabled":""}>Lưu tài khoản</button><button class="btn" data-a="recv-cancel">Huỷ</button></div></div>`;
}

/* ---------- Người tham gia (link xem) ---------- */
function guestView(){
  const ev=S.ev, c=compute(ev), h=host();
  const others=c.rows.filter(r=>!r.isHost);
  const head = topbar(ev.title, `${h?.name||"Host"} chia tiền, tổng chi ${money(c.total)}`, "", `<button class="pill" style="padding:8px 14px" data-a="to-pick">${S.me?"Đổi người":"Chọn tên"}</button>`);
  if (!S.me) return `<div class="page">${head}<div class="pad">
    <h2 class="sec">Bạn là ai?</h2><p class="small muted" style="margin:0 0 12px">Chọn tên của bạn để xem số tiền cần trả hoặc được nhận lại.</p>
    <div class="chips">${others.map(r=>`<button class="chip pick" data-a="pick-me" data-v="${esc(r.id)}">${esc(r.name)}</button>`).join("")}</div>
    <div class="band"></div><h2 class="sec">Cán cân cả nhóm</h2>${balanceList(c)}</div></div>`;
  const r=c.rows.find(x=>x.id===S.me); if(!r){ S.me=null; return guestView(); }
  const s=stOf(r.id, r.net);
  let block="";
  if (r.net<0){
    const amt=-r.net, info=transferNote(ev.title, r.name);
    block = s==="confirmed" ? `<div class="note ok"><b>${esc(h.name)} đã nhận ${money(amt)} của bạn.</b> Xong rồi!</div>`
      : `<div class="note">Bạn cần chuyển thêm <b class="num">${money(amt)}</b> cho ${esc(h.name)}.</div>${qrPanel(ev.bank, amt, info, `Chuyển cho ${h.name}`)}
         <p class="small muted">Mở app ngân hàng và quét QR (hoặc chụp màn hình rồi chọn ảnh QR trong app). Số tiền và nội dung đã điền sẵn.</p>
         ${s==="claimed"?`<div class="note">Bạn đã báo chuyển khoản. Đang chờ ${esc(h.name)} xác nhận. <button class="link" data-a="unclaim" style="font-size:14px">Chưa chuyển?</button></div>`:""}`;
  } else if (r.net>0){
    const acc=S.recv?.[r.id];
    block = s==="sent" ? `<div class="note ok"><b>${esc(h.name)} đã chuyển lại ${money(r.net)} cho bạn.</b></div>`
      : `<div class="note">Bạn sẽ nhận lại <b class="num">${money(r.net)}</b> từ ${esc(h.name)}.</div>
         ${acc && !S.recvForm ? `<p class="small">Đã gửi tài khoản <b>${esc(acc.bankName||"")} ••••${esc(acc.last4||"")}</b>. ${esc(h.name)} sẽ quét QR để chuyển cho bạn. <button class="link" data-a="recv-edit" data-v="${esc(r.id)}" style="font-size:14px">Sửa</button></p>`
           : S.recvForm ? `<h3 style="margin:16px 0 0;font-size:17px">Tài khoản nhận tiền của bạn</h3>${recvFormHtml("gf")}` : `<button class="btn pri" data-a="recv-edit" data-v="${esc(r.id)}" style="margin-top:12px">Gửi số tài khoản để nhận tiền</button>`}`;
  } else block = `<div class="note ok"><b>Bạn không cần trả thêm và cũng không nhận lại.</b></div>`;
  const bar = r.net<0 && s==="unpaid" ? `<div class="bottom"><div class="in"><button class="cta" data-a="claim" ${S.busy?"disabled":""}>Tôi đã chuyển khoản ${money(-r.net)}</button></div></div>` : "";
  return `<div class="page">${head}<div class="pad">
    <div class="person"><div class="head"><span class="avatar">${esc(r.name.trim()[0]||"?")}</span><div class="nm">${esc(r.name)}<div class="small muted num" style="font-weight:500">Đã chi ${money(r.paid)}, phần của bạn ${money(r.share)}</div></div><span class="badge ${badgeOf(r)[1]}">${badgeOf(r)[0]}</span></div>
      <div style="margin-top:12px">${block}</div></div>
    <h2 class="sec" style="margin-top:20px">Phần của bạn</h2>
    ${r.parts.length ? r.parts.map(p=>{ const e=ev.expenses.find(x=>x.id===p.id); return `<div class="exp" style="cursor:default"><div class="d"><b>${esc(p.title)}</b><small>${esc(nameOf(e?.payerId))} chi ${money(e?.amount)}, chia ${(e?.ids||[]).length} người</small></div><span class="p num">${money(p.amt)}</span></div>`; }).join("") : `<p class="muted">Bạn không tham gia khoản chi nào.</p>`}
    <div class="band"></div><h2 class="sec">Cán cân cả nhóm</h2>${balanceList(c)}
  </div>${bar}</div>`;
}

/* ---------- Sheets ---------- */
function sheetHtml(){
  const sh=S.sheet; if(!sh) return "";
  if (sh.kind==="confirm") return `<div class="scrim" data-a="ask-no"></div><div class="sheet" role="alertdialog" aria-label="Xác nhận"><div class="grab"></div>
    <p style="font-size:17px;font-weight:600;margin:6px 0 20px">${esc(sh.msg)}</p>
    <button class="cta" data-a="ask-ok" ${sh.danger?'style="background:var(--chili);color:#fff"':""}>${esc(sh.ok)}</button>
    <button class="cta ghost" data-a="ask-no">Quay lại</button></div>`;
  if (sh.kind==="share") return shareSheet();
  if (sh.kind==="exp") return expSheet(sh);
  return "";
}
function shareMsg(){ return `💸 ${host()?.name||""} chia tiền "${S.ev.title}". Mở link để xem bạn cần trả thêm hay được nhận lại bao nhiêu:`; }
function shareSheet(){
  const link=viewLink(), msg=shareMsg();
  return `<div class="scrim" data-a="sh-close"></div><div class="sheet" role="dialog" aria-label="Gửi link">
    <div class="grab"></div><div class="between"><h3>Gửi cho mọi người</h3><button class="icon" data-a="sh-close" aria-label="Đóng">${I.close}</button></div>
    <div class="muted small">Ai mở link cũng chọn tên mình để xem số tiền và mã QR.</div>
    <div class="msgbox" style="margin-top:14px">${esc(msg)}\n${esc(link)}</div>
    ${navigator.share?`<button class="cta" data-a="native-share" style="margin-top:12px">${I.share} Chia sẻ qua Zalo, Messenger…</button>`:""}
    <button class="cta ${navigator.share?"ghost":""}" data-a="copy" data-t="${esc(msg+"\n"+link)}" style="${navigator.share?"":"margin-top:12px"}">${I.link} Copy tin nhắn</button>
    <p class="small muted">Link quản lý của bạn (đừng gửi cho người khác): <button class="link" style="font-size:14px" data-a="copy" data-t="${esc(manageLink())}">Copy link quản lý</button></p>
  </div>`;
}
function expSheet(sh){
  const pp=people(), allOn=pp.every(p=>sh.ids.includes(p.id)), amt=parseMoney(sh.amount), n=sh.ids.length;
  const ok = sh.title.trim() && amt>0 && sh.payerId && n>0;
  return `<div class="scrim" data-a="sh-close"></div><div class="sheet" role="dialog" aria-label="Khoản chi">
    <div class="grab"></div><div class="between"><h3>${sh.index!=null?"Sửa khoản chi":"Thêm khoản chi"}</h3><button class="icon" data-a="sh-close" aria-label="Đóng">${I.close}</button></div>
    <div style="display:grid;gap:12px;margin-top:10px">
      <div><label class="f" for="x-title">Chi cho việc gì</label><input type="text" id="x-title" data-f="x-title" value="${esc(sh.title)}" placeholder="VD: Tiền phòng, Ăn tối, Xăng xe" maxlength="60"></div>
      <div><label class="f" for="x-amt">Số tiền</label><input type="text" id="x-amt" data-f="x-amt" inputmode="decimal" value="${esc(sh.amount)}" placeholder="VD: 1250000 hoặc 1,25tr hoặc 300k">
        <div class="small ${sh.amount && !(amt>0)?"err":"muted"}" style="margin-top:4px">${sh.amount ? (amt>0?`= ${money(amt)}`:"Số tiền chưa hợp lệ") : "Gõ được 300k, 1,5tr"}</div></div>
    </div>
    <div class="req"><b>Ai đã chi?</b><span>Bắt buộc</span></div>
    <div class="chips">${pp.map(p=>`<button class="chip pick" data-a="x-payer" data-v="${esc(p.id)}" aria-pressed="${sh.payerId===p.id}">${esc(displayName(p))}</button>`).join("")}</div>
    <div class="req"><b>Ai tham gia?</b><span>${n} / ${pp.length} người</span></div>
    <button class="allrow" role="checkbox" aria-checked="${allOn}" data-a="x-all"><span class="t">Chọn tất cả</span><span class="cbox">${allOn?I.check:""}</span></button>
    <div>${pp.map(p=>{ const on=sh.ids.includes(p.id); return `<button class="opt" role="checkbox" aria-checked="${on}" data-a="x-id" data-v="${esc(p.id)}"><span class="t"><b>${esc(displayName(p))}</b></span><span class="cbox">${on?I.check:""}</span></button>`; }).join("")}</div>
    <p class="small muted">${ok?`Chia đều ${n} người, mỗi người khoảng <b class="num">${money(Math.round(amt/n))}</b>.`:"Điền đủ thông tin để xem mỗi người trả bao nhiêu."}</p>
    <button class="cta" data-a="x-save" ${ok?"":"disabled"}>${sh.index!=null?"Lưu khoản chi":"Thêm khoản chi"}</button>
    ${sh.index!=null?`<button class="link red" style="display:block;margin:14px auto 0" data-a="x-del">Xoá khoản chi này</button>`:""}
  </div>`;
}

/* ================= Events ================= */
function ask(msg, ok="Đồng ý", danger=false){ return new Promise(res=>{ S.sheet={kind:"confirm",msg,ok,danger,res}; render(); }); }
function closeAsk(v){ const sh=S.sheet; if(sh?.kind==="confirm"){ S.sheet=null; render(); sh.res(v); return true; } return false; }
function markDirty(){ if (S.mode==="manage") S.dirty=true; saveDraft(); }
function addPeople(raw){
  const names=String(raw||"").split(/[,\n;]/).map(x=>x.trim()).filter(Boolean);
  let added=0, dup=[];
  names.forEach(n=>{ if (people().some(p=>norm(p.name)===norm(n))) dup.push(n); else { S.ev.people.push({id:"p"+rid(), name:n.slice(0,40)}); added++; } });
  if (added) markDirty();
  toast(dup.length ? `Đã thêm ${added}. Trùng tên: ${dup.join(", ")}` : `Đã thêm ${added} người`);
}
async function setStatus(pid, s, amt){
  try{ await rpc("split_set_status",{p_token:S.token, p_person:pid, p_status:s, p_amount:Math.abs(amt)}); await load(true); }
  catch(e){ console.error(e); toast("Không lưu được trạng thái"); }
}
async function onClick(e){
  const b=e.target.closest("[data-a]"); if(!b||b.disabled) return;
  const a=b.dataset.a, v=b.dataset.v, i=Number(b.dataset.i);
  if (a==="ask-ok"){ closeAsk(true); return; }
  if (a==="ask-no"){ closeAsk(false); return; }
  if (S.sheet?.kind==="confirm") return;
  const c = S.ev ? compute(S.ev) : null;
  const rowOf = id => c?.rows.find(r=>r.id===id);
  switch(a){
    case "copy": copyText(b.dataset.t); return;
    case "sh-close": S.sheet=null; break;
    case "share": S.sheet={kind:"share"}; break;
    case "native-share": try{ await navigator.share({ title:S.ev.title, text:shareMsg(), url:viewLink() }); }catch(err){ if(err?.name!=="AbortError") copyText(shareMsg()+"\n"+viewLink(),"Không mở được bảng chia sẻ. Đã copy tin nhắn"); } return;
    case "to-edit": S.view="edit"; window.scrollTo({top:0}); break;
    case "to-result":
      if (S.dirty && !(await ask("Bỏ các thay đổi chưa lưu?","Bỏ thay đổi",true))) return;
      if (S.dirty){ S.dirty=false; await load(true); }
      S.view="result"; window.scrollTo({top:0}); break;
    case "save": saveEvent(); return;
    case "add-person": addPeople(S.newName); S.newName=""; break;
    case "del-person": {
      const used=S.ev.expenses.find(x=>x.payerId===v);
      if (used){ toast(`${nameOf(v)} là người chi khoản "${used.title}". Đổi người chi trước khi bỏ.`); return; }
      const inAny=S.ev.expenses.some(x=>(x.ids||[]).includes(v));
      if (inAny && !(await ask(`Bỏ ${nameOf(v)}? Các khoản chi sẽ được chia lại cho những người còn lại.`,"Bỏ người này",true))) return;
      S.ev.people=S.ev.people.filter(p=>p.id!==v); S.ev.expenses.forEach(x=>x.ids=(x.ids||[]).filter(id=>id!==v)); markDirty(); break; }
    case "new-exp": S.sheet={kind:"exp", index:null, title:"", amount:"", payerId:host().id, ids:people().map(p=>p.id)}; break;
    case "edit-exp": { const x=S.ev.expenses[i]; S.sheet={kind:"exp", index:i, title:x.title, amount:String(x.amount), payerId:x.payerId, ids:[...(x.ids||[])]}; break; }
    case "x-payer": S.sheet.payerId=v; break;
    case "x-all": { const pp=people(); S.sheet.ids = pp.every(p=>S.sheet.ids.includes(p.id)) ? [] : pp.map(p=>p.id); break; }
    case "x-id": { const ids=S.sheet.ids, k=ids.indexOf(v); if(k>=0) ids.splice(k,1); else ids.push(v); S.sheet.ids=people().map(p=>p.id).filter(id=>ids.includes(id)); break; }
    case "x-save": { const sh=S.sheet, amt=parseMoney(sh.amount); if(!(amt>0)) return;
      const x={ id: sh.index!=null ? S.ev.expenses[sh.index].id : "e"+rid(), title:sh.title.trim(), amount:amt, payerId:sh.payerId, ids:[...sh.ids] };
      if (sh.index!=null) S.ev.expenses[sh.index]=x; else S.ev.expenses.push(x);
      S.sheet=null; markDirty(); toast(sh.index!=null?"Đã lưu khoản chi":"Đã thêm khoản chi"); break; }
    case "x-del": { const k=S.sheet.index; S.sheet=null; render(); if(!(await ask(`Xoá khoản "${S.ev.expenses[k].title}"?`,"Xoá",true))) return; S.ev.expenses.splice(k,1); markDirty(); break; }
    case "st": { const r=rowOf(v); if(!r) return; await setStatus(v, b.dataset.s, r.net); break; }
    case "toggle-qr": S.showQr[v]=!S.showQr[v]; break;
    case "recv-edit": { const cur = S.mode==="manage" ? S.recv?.[v] : null; S.recvForm={ pid:v, bankBin:cur?.bankBin||"970436", bankName:cur?.bankName||"Vietcombank", accountNo:cur?.accountNo||"", accountName:cur?.accountName||"" }; break; }
    case "recv-cancel": S.recvForm=null; break;
    case "recv-save": {
      const f=S.recvForm;
      if (!/^\d{6}$/.test(f.bankBin)){ toast("Mã BIN ngân hàng phải gồm 6 số"); return; }
      if (!/^[0-9A-Za-z]{4,19}$/.test(f.accountNo.trim())){ toast("Số tài khoản không hợp lệ"); return; }
      const bank={ bankBin:f.bankBin, bankName:f.bankName, accountNo:f.accountNo.trim(), accountName:ascii(f.accountName) };
      S.busy=true; render();
      try{
        if (S.mode==="manage") await rpc("split_set_recv_manage",{p_token:S.token, p_person:f.pid, p_bank:bank});
        else await rpc("split_set_recv",{p_token:S.token, p_person:f.pid, p_bank:bank});
        S.recvForm=null; await load(true); toast(S.mode==="manage"?"Đã lưu tài khoản":"Đã gửi số tài khoản cho host");
      }catch(err){ console.error(err); toast("Không lưu được tài khoản"); }
      S.busy=false; break; }
    case "copy-summary": copyText(summaryText(), "Đã copy bảng tổng kết"); return;
    case "delete":
      if (!(await ask("Xoá lần chia tiền này? Link gửi cho mọi người sẽ không mở được nữa.","Xoá",true))) return;
      try{ await rpc("split_delete",{p_token:S.token}); lsSet(HIST_KEY, JSON.stringify(loadHist().filter(x=>x.link!==manageLink()))); location.href=BASE; }catch(err){ toast("Không xoá được"); } return;
    case "to-pick": S.me=null; S.recvForm=null; break;
    case "pick-me": S.me=v; lsSet("split:me:"+S.token, v); addHist({ title:S.ev.title, at:Date.now(), role:"guest", link:viewLink() }); window.scrollTo({top:0}); break;
    case "claim": case "unclaim": {
      const r=rowOf(S.me); if(!r) return;
      S.busy=true; render();
      try{ const res=await rpc("split_claim",{p_token:S.token, p_person:S.me, p_amount:-r.net, p_claim:a==="claim"}); if(res?.ok===false) toast("Host đã xác nhận rồi"); else toast(a==="claim"?"Đã báo host":"Đã huỷ báo chuyển"); await load(true); }
      catch(err){ console.error(err); toast("Không lưu được, thử lại"); }
      S.busy=false; break; }
    default: return;
  }
  render();
}
function summaryText(){
  const ev=S.ev, c=compute(ev), h=host();
  const lines=[`💸 ${ev.title}: tổng chi ${money(c.total)}, ${ev.people.length} người`, "", "Các khoản chi:"];
  ev.expenses.forEach(e=>lines.push(`- ${e.title} ${money(e.amount)}: ${nameOf(e.payerId)} chi, chia ${(e.ids||[]).length} người`));
  lines.push("", "Kết quả:");
  c.rows.filter(r=>!r.isHost).forEach(r=>lines.push(`- ${r.name}: ${r.net<0?`trả thêm ${money(-r.net)}`:r.net>0?`nhận lại ${money(r.net)}`:"không cần trả"}`));
  lines.push("", `Chuyển khoản cho ${h.name} và xem QR tại: ${viewLink()}`);
  return lines.join("\n");
}
app.addEventListener("click", onClick); overlay.addEventListener("click", onClick);
function onInput(e){
  const t=e.target, f=t.dataset.f; if(!f) return;
  const ev=S.ev;
  switch(f){
    case "title": ev.title=t.value; markDirty(); break;
    case "host": host().name=t.value; markDirty(); break;
    case "b-acc": ev.bank.accountNo=t.value; markDirty(); break;
    case "b-name": ev.bank.accountName=t.value; markDirty(); return;
    case "b-bin": ev.bank.bankBin=t.value.trim(); markDirty(); break;
    case "new-name": S.newName=t.value; return;
    case "x-title": S.sheet.title=t.value; break;
    case "x-amt": S.sheet.amount=t.value; break;
    case "rf-acc": S.recvForm.accountNo=t.value; return;
    case "rf-name": S.recvForm.accountName=t.value; return;
    case "rf-bin": S.recvForm.bankBin=t.value.trim(); return;
    default: return;
  }
  render();
}
app.addEventListener("input", onInput); overlay.addEventListener("input", onInput);
app.addEventListener("change", e=>{
  const t=e.target, f=t.dataset.f;
  if (f==="b-bank"){ if(t.value==="other"){ S.ev.bank.bankBin=""; S.ev.bank.bankName="Ngân hàng khác"; } else { S.ev.bank.bankBin=t.value; S.ev.bank.bankName=BANKS.find(x=>x[1]===t.value)?.[0]||""; } markDirty(); render(); }
  if (f==="rf-bank"){ if(t.value==="other"){ S.recvForm.bankBin=""; S.recvForm.bankName="Ngân hàng khác"; } else { S.recvForm.bankBin=t.value; S.recvForm.bankName=BANKS.find(x=>x[1]===t.value)?.[0]||""; } render(); }
});
app.addEventListener("keydown", e=>{ if (e.target.id==="new-name" && e.key==="Enter"){ e.preventDefault(); addPeople(S.newName); S.newName=""; render(); } });
app.addEventListener("toggle", e=>{ const d=e.target; if(d?.dataset?.k) S.open[d.dataset.k]=d.open; }, true);
document.addEventListener("keydown", e=>{ if(e.key==="Escape"&&S.sheet){ if(!closeAsk(false)){ S.sheet=null; render(); } } });
window.addEventListener("beforeunload", e=>{ if (S.mode==="manage" && S.dirty){ e.preventDefault(); e.returnValue=""; } });

/* ================= Boot ================= */
(async function boot(){
  if (!sb){ S.loaded=true; render(); return; }
  if (S.mode==="create"){
    try{ S.ev = JSON.parse(lsGet(DRAFT_KEY)||"null"); }catch{ S.ev=null; }
    if (!S.ev?.people) S.ev = blankEvent();
    S.view="edit";
  } else {
    await load(); S.view = "result";
  }
  S.loaded=true; render();
  // cập nhật trạng thái thanh toán / tài khoản người khác vừa gửi, không cần realtime
  setInterval(async ()=>{
    if (document.hidden || S.mode==="create" || S.sheet || S.recvForm || S.busy || S.dirty) return;
    const before=S.updatedAt; await load(true); if (S.updatedAt!==before) render();
  }, 10000);
})();
</script>
</body>
</html>
```

---

## C. Sửa `index.html`

Trong hàm `createView()`, tìm đúng dòng sau:

```js
      ${!live?`<button class="btn" data-a="go" data-v="history" style="margin-bottom:14px">${I.clock} Lịch sử đơn đã đặt${histCount?` (${histCount})`:""}</button>`:""}
```

Thay bằng:

```js
      ${!live?`<div class="row" style="margin-bottom:14px"><button class="btn" data-a="go" data-v="history">${I.clock} Lịch sử đơn đã đặt${histCount?` (${histCount})`:""}</button><a class="btn" href="./split.html" style="text-decoration:none;color:inherit">💸 Chia tiền nhóm</a></div>`:""}
```

---

## D. Thêm vào `CLAUDE.md`

Chèn đoạn sau ngay **trước** heading `## Hard constraints / conventions carried over from the Claude Artifact era`:

```markdown
## Split bill (`split.html` + `split-schema.sql`)

Standalone page for splitting shared event costs, linked from the root "create" screen of `index.html` ("💸 Chia tiền nhóm"). Same look and helpers as `index.html` (copied in, not shared), but **its own data model and a stricter permission model**:

- One table `split_events` (`data` jsonb = title/bank/people/expenses, `status` jsonb = per-person payment status, `recv` jsonb = per-person refund bank accounts). RLS is enabled with **no policies** and anon has no table grants — every read/write goes through `SECURITY DEFINER` RPCs in `split-schema.sql` (`split_create`, `split_get_manage`, `split_update`, `split_set_status`, `split_set_recv_manage`, `split_delete` for the `?manage=` link; `split_get_view`, `split_claim`, `split_set_recv` for the `?view=` link). `manage_token` is never returned to view-link holders, and full refund account numbers are only returned to the manage link (view link gets bank name + last 4 digits).
- Links: `split.html` (create), `split.html?manage=<manage_token>` (host), `split.html?view=<view_token>` (participants pick their name, stored per-event in localStorage `split:me:<token>`).
- Settlement goes through the host as a hub: each non-host person's `net = paid − share`; `net < 0` → pays `|net|` to the host's account via VietQR; `net > 0` → host refunds `net` to that person's account (they submit it via the view link, or host enters it). Each expense is split evenly in whole đồng; leftover đồng go to the first participants so shares always sum to the expense amount.
- Payment status entries store the amount they were set for (`{s, amt}`); the client ignores a status whose `amt` no longer matches the person's current balance, so editing expenses automatically resets stale "paid" marks.
- No realtime: the manage/view pages poll `split_get_*` every 10s while visible (and pause while editing).
- Local storage: `split:draft` (unsaved create form), `split:history` (events opened on this browser), and it reuses `comtrua:lastBank` / `comtrua:name` from the lunch app for prefill.
```

---

## E. Thêm vào `WORK_LOG.md`

Chèn đoạn sau ngay **trước** mục `## 2026-09-28` (sau dòng `---` phân cách phía trên nó), kèm một dòng `---` phân cách:

```markdown
## 2026-10-06: Thêm tính năng Chia tiền nhóm (split bill)

Yêu cầu: host nhập người tham gia một sự kiện, các khoản chi (ai chi, ai tham gia, có nút chọn tất cả), app tính ai phải trả thêm / được nhận lại. Người trả thêm quét QR chuyển vào tài khoản host; người được nhận lại thì host thấy số tiền và xin số tài khoản để chuyển.

- Trang mới `split.html`, vào từ nút "💸 Chia tiền nhóm" ở màn tạo đơn của `index.html`. Ba loại link: tạo mới / `?manage=` cho host / `?view=` cho người tham gia.
- Bảng mới `split_events` + RPC trong `split-schema.sql` (chạy riêng file này trong SQL Editor). Khác bảng cơm trưa: khoá hoàn toàn với anon, chỉ truy cập qua hàm SECURITY DEFINER, nên link xem không lấy được link quản lý hay số tài khoản đầy đủ của người khác.
- Người được nhận lại tự gửi số tài khoản qua link xem; host thấy QR để chuyển. Host cũng nhập hộ được, hoặc copy tin nhắn xin số tài khoản.
- Người trả thêm bấm "Tôi đã chuyển khoản"; host bấm "Đã nhận tiền" / "Đã chuyển" để chốt. Sửa khoản chi làm số tiền đổi thì trạng thái cũ tự mất hiệu lực.
- Đã test end-to-end bằng Playwright với RPC giả lập (tạo sự kiện 5 người, 3 khoản chi, người xem chọn tên, gửi tài khoản nhận tiền, báo đã chuyển, host thấy trạng thái). **Chưa** test với Supabase thật.
```
