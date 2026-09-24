-- ============================================================
-- Cơm trưa team — Supabase schema
-- Chạy toàn bộ file này trong Supabase Dashboard → SQL Editor.
-- An toàn chạy lại nhiều lần (dùng IF NOT EXISTS / CREATE OR REPLACE).
-- ============================================================

-- ---------- Extensions ----------
create extension if not exists pgcrypto; -- gen_random_bytes() cho order_token

-- ---------- Bảng config (1 row duy nhất, id cố định) ----------
-- CHỈ chứa cấu hình CHUNG cho toàn hệ thống (giá mặc định, tuỳ chọn thanh
-- toán, domain). Thông tin ngân hàng nhận tiền KHÔNG nằm ở đây nữa — mỗi
-- người tạo đơn nhận tiền vào tài khoản của chính họ, nên bank_bin/
-- bank_name/account_no/account_name đã chuyển sang bảng sessions (mỗi
-- session tự có bank riêng, xem bên dưới).
create table if not exists config (
  id integer primary key default 1 check (id = 1), -- ép chỉ có 1 row
  price_per_set integer not null default 35000,
  host_pays boolean not null default true,
  show_payment_to_team boolean not null default true,
  share_url text,
  updated_at timestamptz not null default now()
);
-- Dọn các cột không còn dùng từ các bản thiết kế trước:
-- host_pin_hash/host_token_hash (PIN, rồi token host cố định — đã bỏ),
-- current_session_key ("1 đơn active toàn cục" — đã bỏ, giờ nhiều đơn
-- tồn tại song song độc lập, mỗi đơn có sessions.manage_token riêng),
-- bank_bin/bank_name/account_no/account_name (chuyển sang sessions —
-- xem ghi chú trên).
alter table config drop column if exists host_pin_hash;
alter table config drop column if exists host_token_hash;
alter table config drop column if exists current_session_key;
alter table config drop column if exists bank_bin;
alter table config drop column if exists bank_name;
alter table config drop column if exists account_no;
alter table config drop column if exists account_name;

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
  bank_bin text, -- tài khoản nhận tiền CỦA NGƯỜI TẠO ĐƠN này (không dùng chung config nữa)
  bank_name text,
  account_no text,
  account_name text,
  order_token text not null default encode(gen_random_bytes(12), 'hex'), -- link guest (xem/đặt món): ?order=<order_token>
  manage_token text not null default encode(gen_random_bytes(12), 'hex'), -- link quản lý (người tạo đơn): ?manage=<manage_token>
  created_at bigint not null -- epoch ms
);
create index if not exists sessions_date_idx on sessions (date desc);
-- Nếu bảng sessions đã tồn tại từ trước (thiếu các cột mới ở trên vì được
-- tạo bởi bản schema cũ hơn — "create table if not exists" bỏ qua toàn bộ
-- định nghĩa cột khi bảng đã có), thêm từng cột còn thiếu. Các cột bank_*
-- nullable nên chỉ cần add column; order_token/manage_token NOT NULL nên
-- cần thêm bước điền giá trị TRƯỚC khi tạo unique index bên dưới.
alter table sessions add column if not exists bank_bin text;
alter table sessions add column if not exists bank_name text;
alter table sessions add column if not exists account_no text;
alter table sessions add column if not exists account_name text;
alter table sessions add column if not exists order_token text;
update sessions set order_token = encode(gen_random_bytes(12), 'hex') where order_token is null;
alter table sessions alter column order_token set not null;
create unique index if not exists sessions_order_token_idx on sessions (order_token);

alter table sessions add column if not exists manage_token text;
update sessions set manage_token = encode(gen_random_bytes(12), 'hex') where manage_token is null;
alter table sessions alter column manage_token set not null;
create unique index if not exists sessions_manage_token_idx on sessions (manage_token);

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
-- Mô hình quyền (đã chọn theo yêu cầu người dùng — nhiều đơn nhóm có thể
-- tồn tại SONG SONG, mỗi đơn do một người tạo và quản lý riêng; ưu tiên
-- đơn giản, chấp nhận đánh đổi bảo mật cho nhóm nội bộ nhỏ, tin tưởng nhau):
--
--   - Link gốc   index.html                        → LUÔN hiện màn "Tạo
--     đơn nhóm mới" trống, không gắn với session nào. Bất kỳ ai mở URL
--     gốc (domain Vercel) đều tạo được đơn mới.
--   - Link quản lý  index.html?manage=<manage_token>  → sau khi tạo đơn,
--     app chuyển sang link này (người tạo tự lưu/bookmark). Có toàn quyền
--     quản lý ĐÚNG session đó (sửa thực đơn, xác nhận thanh toán, chốt/xoá
--     đơn…) — KHÔNG quản lý được các session khác do người khác tạo.
--   - Link đơn (guest)  index.html?order=<order_token>  → xem menu và đặt
--     món cho ĐÚNG session đó, KHÔNG có quyền quản lý.
--
-- order_token và manage_token đều sinh ngẫu nhiên (96 bit) mỗi khi tạo
-- session mới (xem sessions.order_token, sessions.manage_token), không
-- đoán được. Bảo mật của "quyền quản lý 1 đơn" phụ thuộc vào việc không
-- làm lộ link ?manage=... của đơn đó (khác gì làm lộ mật khẩu) — người
-- dùng đã xác nhận chấp nhận đánh đổi này thay vì dùng Supabase Auth.
-- Không có RPC xác thực nào — anon key ghi trực tiếp vào
-- config/sessions/dishes/orders qua policy bên dưới; việc "đúng link mới
-- sửa được đúng đơn" là do CLIENT tự lọc theo manage_token trong URL,
-- không phải do RLS chặn ở tầng server (ai gọi thẳng Supabase API biết
-- session key vẫn sửa được — chấp nhận được cho nhóm nội bộ tin tưởng nhau).
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
-- 1. KHÔNG có xác thực host ở tầng server, kể cả cho manage_token —
--    verify hoàn toàn ở CLIENT (index.html đọc ?manage=... rồi tự so với
--    sessions.manage_token qua 1 SELECT thường, không phải RPC bảo mật).
--    Ai gọi thẳng Supabase REST API biết đúng session key hoặc đoán được
--    manage_token đều ghi được vào session đó (và về lý thuyết vào MỌI
--    session khác, vì RLS mở chung cho toàn bảng, không lọc theo token).
--    Người dùng đã xác nhận chấp nhận đánh đổi này cho nhóm nội bộ.
-- 2. Làm LỘ 1 link ?manage=... chỉ ảnh hưởng đơn đó (khác bản thiết kế
--    "token host toàn cục" trước đây, nơi lộ 1 token ảnh hưởng mọi đơn).
--    Đây là cải thiện so với thiết kế cũ, nhưng vẫn không phải access
--    control thật ở tầng server.
-- 3. Muốn siết lại sau này: khôi phục lại RPC xác thực (đã drop ở trên,
--    lịch sử các phiên bản trước còn trong git) để verify manage_token
--    qua security-definer function thay vì so sánh trực tiếp ở client.
-- 4. Nâng cấp triệt để hơn (không làm trong bản đầu): dùng Supabase
--    Anonymous Auth (auth.signInAnonymously()) để có auth.uid() thật +
--    custom claims phân biệt ai quản lý session nào, rồi viết lại RLS
--    chặt theo đúng session_key thay vì mở chung cho toàn bảng.
