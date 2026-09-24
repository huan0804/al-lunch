-- ============================================================
-- Cơm trưa team — Supabase schema
-- Chạy toàn bộ file này trong Supabase Dashboard → SQL Editor.
-- An toàn chạy lại nhiều lần (dùng IF NOT EXISTS / CREATE OR REPLACE).
-- ============================================================

-- ---------- Extensions ----------
create extension if not exists pgcrypto; -- gen_random_bytes() cho order_token

-- ---------- Bảng config (1 row duy nhất, id cố định) ----------
create table if not exists config (
  id integer primary key default 1 check (id = 1), -- ép chỉ có 1 row
  bank_bin text,
  bank_name text,
  account_no text,
  account_name text,
  price_per_set integer not null default 35000,
  host_pays boolean not null default true,
  show_payment_to_team boolean not null default true,
  share_url text,
  current_session_key text,
  updated_at timestamptz not null default now()
);
-- Dọn cột host_pin_hash/host_token_hash còn sót lại từ các bản thiết kế
-- trước (PIN, rồi token cố định) — bản hiện tại không cần cột nào trong đó.
alter table config drop column if exists host_pin_hash;
alter table config drop column if exists host_token_hash;

-- ---------- Bảng sessions (đơn nhóm theo ngày) ----------
create table if not exists sessions (
  key text primary key, -- "YYYY-MM-DD" hoặc "YYYY-MM-DD-xxxxx"
  date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  price_per_set integer not null,
  deadline_at bigint not null default 0, -- epoch ms, giữ nguyên đơn vị như bản Claude artifact
  deadline text, -- "HH:MM"
  auto_close boolean not null default true,
  host_name text,
  shop_name text,
  menu jsonb not null default '[]'::jsonb, -- [{id, nameVi, nameEn, soldOut}]
  order_token text not null default encode(gen_random_bytes(12), 'hex'), -- link guest: ?order=<order_token>
  created_at bigint not null -- epoch ms
);
create index if not exists sessions_date_idx on sessions (date desc);
create unique index if not exists sessions_order_token_idx on sessions (order_token);
-- Nếu bảng sessions đã tồn tại từ trước (thiếu cột order_token), thêm vào
-- và điền giá trị cho các session cũ để không có row nào bị null.
alter table sessions add column if not exists order_token text;
update sessions set order_token = encode(gen_random_bytes(12), 'hex') where order_token is null;
alter table sessions alter column order_token set not null;

-- ---------- Bảng dishes (thư viện món) ----------
create table if not exists dishes (
  id text primary key,
  name_vi text not null,
  name_en text default '',
  times_used integer not null default 0,
  last_used date
);

-- ---------- Bảng orders (1 row / người / session) ----------
-- doc_id gốc trong artifact là user.id() hoặc "proxy-xxxx"; ở đây dùng
-- doc_id = uuid ẩn danh lưu trong localStorage của trình duyệt người đặt.
create table if not exists orders (
  session_key text not null references sessions(key) on delete cascade,
  doc_id text not null, -- uuid của người đặt (anon auth hoặc localStorage uuid)
  name text not null default '',
  guests jsonb not null default '[]'::jsonb, -- [tên người được đặt hộ]
  sets jsonb not null default '[]'::jsonb,   -- [{dishes:[{id,name,portions}], note, qty, price, for}]
  total integer not null default 0,
  price_per_set integer not null default 35000,
  pay_method text check (pay_method in ('cash','transfer','host')),
  pay_status text not null default 'unpaid' check (pay_status in ('unpaid','claimed','confirmed')),
  by_host boolean not null default false,
  created_at bigint not null,
  updated_at bigint not null,
  primary key (session_key, doc_id)
);
create index if not exists orders_session_idx on orders (session_key);

-- ============================================================
-- Row Level Security
-- ============================================================
-- Mô hình quyền (đã chọn theo yêu cầu người dùng — ưu tiên đơn giản,
-- chấp nhận đánh đổi bảo mật cho nhóm nội bộ nhỏ, tin tưởng nhau):
--
--   - Link gốc  index.html                 → LUÔN là host, không cần xác
--     thực gì cả. Bất kỳ ai mở đúng URL gốc (domain Vercel) đều có toàn
--     quyền quản lý (sửa bank, tạo/sửa/xoá đơn nhóm, xác nhận thanh toán…).
--   - Link đơn  index.html?order=<order_token>  → guest dùng để xem menu
--     và đặt món cho ĐÚNG session đó. order_token sinh ngẫu nhiên mỗi khi
--     host tạo đơn nhóm mới (xem cột sessions.order_token), không đoán
--     được, nhưng KHÔNG có quyền quản lý.
--
-- Bảo mật của "quyền host" hoàn toàn dựa vào việc domain Vercel không bị
-- lộ ra ngoài nhóm — không có xác thực nào khác ở tầng ứng dụng. Người
-- dùng đã xác nhận chấp nhận đánh đổi này. Vì vậy KHÔNG cần RPC xác thực
-- (không còn PIN/token host như các bản thiết kế trước) — anon key được
-- quyền ghi trực tiếp vào config/sessions/dishes qua policy bên dưới.
--
-- Vì không có Supabase Auth, ta cũng KHÔNG thể dùng auth.uid() để phân
-- biệt "chủ đơn" ở tầng RLS cho bảng orders. Việc chỉ đúng chủ đơn mới
-- sửa được đơn của mình được enforce ở phía CLIENT (mỗi người tự giữ
-- doc_id ẩn danh riêng trong localStorage), không phải ở RLS.

alter table config enable row level security;
alter table sessions enable row level security;
alter table dishes enable row level security;
alter table orders enable row level security;

-- Đọc: ai cũng đọc được (cần thiết để guest xem được menu/đơn qua link).
drop policy if exists config_select on config;
create policy config_select on config for select using (true);
drop policy if exists sessions_select on sessions;
create policy sessions_select on sessions for select using (true);
drop policy if exists dishes_select on dishes;
create policy dishes_select on dishes for select using (true);
drop policy if exists orders_select on orders;
create policy orders_select on orders for select using (true);

-- Ghi: mở cho tất cả (anon key). Xem ghi chú bảo mật ở đầu mục RLS —
-- không có RPC xác thực host, mọi phân quyền nằm ở việc biết đúng URL.
drop policy if exists orders_write on orders;
create policy orders_write on orders for all using (true) with check (true);
drop policy if exists config_write on config;
create policy config_write on config for all using (true) with check (true);
drop policy if exists sessions_write on sessions;
create policy sessions_write on sessions for all using (true) with check (true);
drop policy if exists dishes_write on dishes;
create policy dishes_write on dishes for all using (true) with check (true);

-- ============================================================
-- Dọn RPC của các bản thiết kế trước (PIN, rồi token host) — không
-- còn dùng trong bản hiện tại vì client ghi thẳng qua policy ở trên.
-- ============================================================
drop function if exists set_host_pin(text);
drop function if exists verify_host_pin(text);
drop function if exists generate_host_token();
drop function if exists verify_host_token(text);
drop function if exists update_config(text,text,text,text,text,integer,boolean,boolean,text,text);
drop function if exists upsert_session(text,text,date,text,integer,bigint,text,boolean,text,text,jsonb);
drop function if exists set_session_status(text,text,text);
drop function if exists delete_session(text,text);
drop function if exists host_set_order_pay(text,text,text,text);
drop function if exists host_delete_order(text,text,text);

-- ============================================================
-- RPC còn giữ lại: upsert_dish (gộp/tăng đếm món trong thư viện — tiện
-- hơn làm select-rồi-update ở client, không liên quan gì đến quyền host).
-- ============================================================
create or replace function upsert_dish(p_id text, p_name_vi text, p_name_en text)
returns text
language plpgsql security definer
as $$
declare found_id text;
begin
  select id into found_id from dishes where lower(name_vi) = lower(p_name_vi) limit 1;
  if found_id is not null then
    update dishes set times_used = times_used + 1, last_used = current_date where id = found_id;
    return found_id;
  end if;
  insert into dishes (id, name_vi, name_en, times_used, last_used)
  values (coalesce(p_id, 'd'||substr(md5(random()::text),1,10)), p_name_vi, coalesce(p_name_en,''), 1, current_date);
  return coalesce(p_id, (select id from dishes where name_vi = p_name_vi order by last_used desc limit 1));
end;
$$;

-- ============================================================
-- Realtime
-- ============================================================
-- alter publication ... add table không có "if not exists", nên kiểm tra
-- thủ công qua pg_publication_tables trước khi thêm (an toàn chạy lại nhiều lần).
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='sessions') then
    alter publication supabase_realtime add table sessions;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='orders') then
    alter publication supabase_realtime add table orders;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='config') then
    alter publication supabase_realtime add table config;
  end if;
end $$;

-- ============================================================
-- Ghi chú bảo mật (đọc trước khi dùng thật với dữ liệu nhạy cảm)
-- ============================================================
-- 1. KHÔNG có xác thực host ở tầng server. Bất kỳ ai biết domain Vercel
--    (dù không có link guest nào) đều có toàn quyền quản lý ngay khi mở
--    trang — kể cả sửa bank, xoá đơn nhóm, xem tất cả đơn của mọi người.
--    Đây là đánh đổi được người dùng chấp nhận cho đơn giản; domain Vercel
--    coi như bí mật tương đương "mật khẩu quản trị". KHÔNG đăng domain
--    này công khai (ví dụ trong README public, group chat lớn...).
-- 2. Muốn siết lại sau này: khôi phục lại RPC xác thực (PIN hoặc token)
--    đã bị drop ở trên — lịch sử các phiên bản trước còn trong git.
-- 3. order_token (link guest) sinh ngẫu nhiên 96 bit mỗi khi tạo session
--    mới, đủ khó đoán, nhưng CHỈ giới hạn được việc "xem/đặt món đúng
--    session" — guest không có quyền ghi vào config/sessions/dishes vì
--    UI không hiển thị các thao tác đó cho họ, nhưng RLS (orders_write,
--    config_write...) không tự phân biệt được host với guest ở tầng
--    server — ai gọi trực tiếp Supabase API (không qua UI) đều ghi được
--    vào mọi bảng. Chấp nhận được cho nhóm nội bộ tin tưởng nhau.
-- 4. Nâng cấp sau (không làm trong bản đầu): dùng Supabase Anonymous
--    Auth (auth.signInAnonymously()) để có auth.uid() thật + custom
--    claims phân biệt host/guest, rồi viết lại RLS chặt hơn.
