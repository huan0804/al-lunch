-- ============================================================
-- Cơm trưa team — Supabase schema
-- Chạy toàn bộ file này trong Supabase Dashboard → SQL Editor.
-- An toàn chạy lại nhiều lần (dùng IF NOT EXISTS / CREATE OR REPLACE).
-- ============================================================

-- ---------- Extensions ----------
create extension if not exists pgcrypto; -- crypt() + gen_random_bytes() cho host_token_hash

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
  host_token_hash text, -- crypt(token, gen_salt('bf')) — xem verify_host_token
  updated_at timestamptz not null default now()
);

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
  created_at bigint not null -- epoch ms
);
create index if not exists sessions_date_idx on sessions (date desc);

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
-- Mô hình quyền: KHÔNG dùng Supabase Auth, KHÔNG dùng PIN. Có 2 link:
--   - Link thành viên: index.html                (không có quyền host)
--   - Link host:        index.html?manage=<token> (token dài, ngẫu nhiên)
-- App đọc "manage" trên URL, gọi RPC verify_host_token để xác nhận, rồi
-- lưu "đã là host" trong localStorage của trình duyệt đó (không cần nhập
-- lại mỗi lần). Token cố định 1 lần lúc setup, không có tính năng đổi lại
-- trong app — muốn đổi phải sửa trực tiếp trong Supabase (gọi lại
-- set_host_token). Token đủ dài (256 bit ngẫu nhiên, xem generate_host_token)
-- nên không cần nhập tay như PIN.
--
-- Vì không có Supabase Auth, ta KHÔNG thể dùng auth.uid() để phân biệt
-- "chủ đơn" ở tầng RLS. Việc chỉ đúng chủ đơn mới sửa được đơn của mình
-- (orders/{self}) do đó được enforce ở phía CLIENT (mỗi người tự giữ
-- doc_id ẩn danh riêng), không phải ở RLS — giống hạn chế vốn có của
-- localStorage-uuid pattern. RLS ở đây chỉ chặn việc app lạ đọc/ghi
-- ngoài các bảng này (client dùng anon key, không phải chặn giữa các
-- thành viên với nhau).
--
-- Nếu cần siết chặt hơn (không cho thành viên A sửa đơn của thành viên B
-- kể cả khi đoán được doc_id), cần chuyển sang Supabase anonymous auth
-- thật (auth.uid()) — xem ghi chú cuối file.

alter table config enable row level security;
alter table sessions enable row level security;
alter table dishes enable row level security;
alter table orders enable row level security;

-- Đọc: ai cũng đọc được (link chia sẻ công khai trong nội bộ team)
drop policy if exists config_select on config;
create policy config_select on config for select using (true);
drop policy if exists sessions_select on sessions;
create policy sessions_select on sessions for select using (true);
drop policy if exists dishes_select on dishes;
create policy dishes_select on dishes for select using (true);
drop policy if exists orders_select on orders;
create policy orders_select on orders for select using (true);

-- Ghi orders: ai cũng ghi được (client tự giới hạn sửa đơn của chính mình
-- qua doc_id trong localStorage — xem ghi chú RLS ở trên).
drop policy if exists orders_write on orders;
create policy orders_write on orders for all using (true) with check (true);

-- Ghi config/sessions/dishes: CHỈ qua RPC chạy security definer bên dưới
-- (không cấp insert/update/delete trực tiếp qua policy cho anon key).
-- Không tạo policy insert/update/delete cho 3 bảng này => mặc định chặn hết,
-- trừ khi gọi qua các hàm SECURITY DEFINER dưới đây.

-- ============================================================
-- RPC: xác thực & thao tác của host
-- ============================================================

-- Sinh token host mới, TRẢ VỀ token thô đúng 1 lần (chỉ lúc gọi hàm này).
-- Chỉ gọi 1 lần khi setup ban đầu — chạy trong SQL Editor:
--   select generate_host_token();
-- rồi copy kết quả, ghép thành link host: index.html?manage=<token>.
-- KHÔNG có RPC "đổi lại token" gọi được từ client (theo thiết kế đã chọn:
-- token cố định, không đổi qua app). Muốn đổi, chạy lại hàm này trong
-- SQL Editor rồi cập nhật link đã gửi.
create or replace function generate_host_token()
returns text
language plpgsql security definer
as $$
declare new_token text;
begin
  new_token := encode(gen_random_bytes(24), 'hex'); -- 192 bit ngẫu nhiên, đủ dài để không đoán được
  insert into config (id, host_token_hash)
  values (1, crypt(new_token, gen_salt('bf')))
  on conflict (id) do update set host_token_hash = excluded.host_token_hash, updated_at = now();
  return new_token;
end;
$$;

-- Kiểm tra token đúng không (trả về true/false, không lộ hash).
-- Gọi từ client bằng anon key khi app đọc ?manage=... trên URL.
create or replace function verify_host_token(token_try text)
returns boolean
language plpgsql security definer
as $$
declare stored text;
begin
  if token_try is null or length(token_try) < 20 then return false; end if;
  select host_token_hash into stored from config where id = 1;
  if stored is null then return false; end if;
  return stored = crypt(token_try, stored);
end;
$$;

-- Host cập nhật config (bank info, giá, v.v.) — yêu cầu đúng token host.
create or replace function update_config(
  token_try text,
  p_bank_bin text, p_bank_name text, p_account_no text, p_account_name text,
  p_price_per_set integer, p_host_pays boolean, p_show_payment_to_team boolean,
  p_share_url text, p_current_session_key text
)
returns void
language plpgsql security definer
as $$
begin
  if not verify_host_token(token_try) then
    raise exception 'invalid_token';
  end if;
  update config set
    bank_bin = p_bank_bin, bank_name = p_bank_name,
    account_no = p_account_no, account_name = p_account_name,
    price_per_set = p_price_per_set, host_pays = p_host_pays,
    show_payment_to_team = p_show_payment_to_team,
    share_url = p_share_url, current_session_key = p_current_session_key,
    updated_at = now()
  where id = 1;
end;
$$;

-- Host tạo/sửa session (đơn nhóm), thêm/sửa menu.
create or replace function upsert_session(
  token_try text, p_key text, p_date date, p_status text,
  p_price_per_set integer, p_deadline_at bigint, p_deadline text,
  p_auto_close boolean, p_host_name text, p_shop_name text, p_menu jsonb
)
returns void
language plpgsql security definer
as $$
begin
  if not verify_host_token(token_try) then
    raise exception 'invalid_token';
  end if;
  insert into sessions (key, date, status, price_per_set, deadline_at, deadline, auto_close, host_name, shop_name, menu, created_at)
  values (p_key, p_date, coalesce(p_status,'open'), p_price_per_set, p_deadline_at, p_deadline, p_auto_close, p_host_name, p_shop_name, p_menu, (extract(epoch from now())*1000)::bigint)
  on conflict (key) do update set
    status = excluded.status, price_per_set = excluded.price_per_set,
    deadline_at = excluded.deadline_at, deadline = excluded.deadline,
    auto_close = excluded.auto_close, host_name = excluded.host_name,
    shop_name = excluded.shop_name, menu = excluded.menu;
end;
$$;

-- Host đóng/mở/xoá session.
create or replace function set_session_status(token_try text, p_key text, p_status text)
returns void language plpgsql security definer as $$
begin
  if not verify_host_token(token_try) then raise exception 'invalid_token'; end if;
  update sessions set status = p_status where key = p_key;
end;
$$;

create or replace function delete_session(token_try text, p_key text)
returns void language plpgsql security definer as $$
begin
  if not verify_host_token(token_try) then raise exception 'invalid_token'; end if;
  delete from sessions where key = p_key; -- orders xoá theo cascade
end;
$$;

-- Host thêm/cập nhật món vào thư viện dishes (không cần token host — đọc/ghi
-- thư viện món dùng chung, rủi ro thấp; đổi thành yêu cầu token nếu muốn chặt hơn).
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

-- Host xác nhận/hoàn tác thanh toán, sửa/xoá đơn của người khác.
create or replace function host_set_order_pay(token_try text, p_session_key text, p_doc_id text, p_pay_status text)
returns void language plpgsql security definer as $$
begin
  if not verify_host_token(token_try) then raise exception 'invalid_token'; end if;
  update orders set pay_status = p_pay_status, updated_at = (extract(epoch from now())*1000)::bigint
  where session_key = p_session_key and doc_id = p_doc_id;
end;
$$;

create or replace function host_delete_order(token_try text, p_session_key text, p_doc_id text)
returns void language plpgsql security definer as $$
begin
  if not verify_host_token(token_try) then raise exception 'invalid_token'; end if;
  delete from orders where session_key = p_session_key and doc_id = p_doc_id;
end;
$$;

-- ============================================================
-- Realtime
-- ============================================================
alter publication supabase_realtime add table sessions;
alter publication supabase_realtime add table orders;
alter publication supabase_realtime add table config;

-- ============================================================
-- Ghi chú bảo mật (đọc trước khi dùng thật với dữ liệu nhạy cảm)
-- ============================================================
-- 1. host_token_hash: hash bằng bcrypt (crypt + gen_salt('bf')), không lưu
--    plaintext. Token 192 bit ngẫu nhiên nên không thể dò được bằng cách
--    thử — khác PIN ngắn. Rủi ro chính là làm LỘ chính link host (vd gửi
--    nhầm vào nhóm chat thường, hoặc lưu trong lịch sử trình duyệt dùng
--    chung máy) — ai có link đó có toàn quyền host. Không có cách thu hồi
--    trong app (đã chọn "cố định, không đổi"); muốn thu hồi phải chạy lại
--    generate_host_token() trong SQL Editor và gửi link host mới.
-- 2. Bảng orders cho phép ai cũng ghi (orders_write using(true)) vì
--    không có Supabase Auth để phân biệt "chủ đơn" ở tầng RLS. Thành
--    viên nào biết được doc_id (uuid) của người khác về lý thuyết có
--    thể sửa đơn hộ họ. uuid đủ dài để không đoán được ngẫu nhiên, nhưng
--    đây KHÔNG phải access control thật. Nếu cần chặt hơn, xem mục 3.
-- 3. Nâng cấp sau (không làm trong bản đầu): dùng Supabase Anonymous
--    Auth (auth.signInAnonymously()) để có auth.uid() thật, rồi đổi
--    policy orders_write thành `using (doc_id = auth.uid()::text)`.
