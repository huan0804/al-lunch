-- ============================================================
-- AL Lunch — lớp RPC SECURITY DEFINER cho phần "Đặt cơm trưa" (index.html)
--
-- MỤC ĐÍCH: thay RLS mở hoàn toàn (anon đọc/ghi thẳng mọi bảng) bằng hàm
-- máy chủ kiểm tra token, giống split-schema.sql. Sau khi chạy THÊM
-- lunch-lockdown.sql, anon chỉ gọi được các hàm lunch_* bên dưới.
--
-- THỨ TỰ TRIỂN KHAI (quan trọng, đừng đảo):
--   1. Chạy file NÀY trong Supabase SQL Editor. Chỉ TẠO hàm, không đổi quyền
--      → bản app cũ đang chạy KHÔNG bị ảnh hưởng.
--   2. Deploy bản supabase-adapter.js mới (gọi các hàm này) lên Vercel, kiểm tra.
--   3. Chạy lunch-lockdown.sql: thu quyền anon trên bảng. Từ đây bản app cũ
--      (kể cả bản đã cache) sẽ hết chạy được.
-- An toàn chạy lại nhiều lần (CREATE OR REPLACE).
--
-- Mô hình: không có đăng nhập. Hai loại token trên sessions:
--   manage_token → role 'manage' (toàn quyền ĐÚNG session đó)
--   order_token  → role 'order'  (xem, đặt/huỷ đơn trong ĐÚNG session đó)
-- manage_token không bao giờ trả cho người cầm order_token.
--
-- GIỚI HẠN ĐÃ BIẾT (không có Auth nên không chặn được):
--   * doc_id của người đặt là mã ẩn danh ở trình duyệt, các thành viên cùng
--     đơn đọc được doc_id của nhau → người cầm link đặt món có thể sửa/huỷ
--     đơn của người khác TRONG CÙNG đơn đó (không còn vượt ra ngoài đơn).
--   * `total` do client tính; server không tính lại công thức giá.
--   * Thư viện món (dishes) dùng chung toàn hệ thống, ai cũng thêm được
--     (có giới hạn kích thước); xoá cần token hợp lệ của bất kỳ đơn nào.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- Cài đặt THEO TỪNG ĐƠN (thay cho cấu hình chung ghi được bởi mọi host) ----------
-- host_pays / show_payment_to_team trước nằm ở config (1 dòng dùng chung): host nào đổi là đổi
-- cho mọi đơn của mọi người. Nay mỗi đơn có giá trị riêng. Lần đầu thêm cột: copy giá trị config
-- hiện tại sang các đơn đang có để hành vi không đổi. share_url không còn dùng (link mời luôn theo
-- domain của trang). config chỉ còn để đọc; chỉnh giá mặc định bằng SQL Editor nếu cần.
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='sessions' and column_name='host_pays') then
    alter table sessions add column host_pays boolean not null default true;
    alter table sessions add column show_payment_to_team boolean not null default true;
    update sessions s set host_pays = c.host_pays, show_payment_to_team = c.show_payment_to_team
      from config c where c.id = 1;
  end if;
end $$;

-- ---------- Hàm nội bộ: xác định session + vai trò từ token ----------
-- Không cấp cho anon (xem cuối file); chỉ các hàm SECURITY DEFINER bên dưới gọi.
create or replace function lunch_auth(p_token text)
returns table (skey text, role text, status text)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.key, 'manage'::text, s.status from sessions s
   where p_token is not null and length(p_token) >= 16 and s.manage_token = p_token
  union all
  select s.key, 'order'::text, s.status from sessions s
   where p_token is not null and length(p_token) >= 16 and s.order_token = p_token
  limit 1
$$;

-- ---------- Đọc ----------
create or replace function lunch_get_config()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(to_jsonb(c), '{}'::jsonb) from (select * from config where id = 1) c
$$;

create or replace function lunch_session_exists(p_key text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from sessions where key = p_key)
$$;

-- Toàn bộ trạng thái của ĐÚNG session mà token trỏ tới (thay cho 3 truy vấn
-- "select * from sessions/orders/drafting" không điều kiện ở bản cũ).
create or replace function lunch_get_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a record; s sessions%rowtype; sess jsonb;
begin
  select * into a from lunch_auth(p_token);
  if a.skey is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select * into s from sessions where key = a.skey;
  sess := to_jsonb(s);
  if a.role <> 'manage' then sess := sess - 'manage_token'; end if;
  return jsonb_build_object(
    'ok', true, 'role', a.role, 'session', sess,
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at) from orders o where o.session_key = a.skey), '[]'::jsonb),
    'drafting', case when a.role = 'manage'
      then coalesce((select jsonb_agg(to_jsonb(d)) from drafting d where d.session_key = a.skey), '[]'::jsonb)
      else '[]'::jsonb end
  );
end $$;

create or replace function lunch_get_order(p_token text, p_doc_id text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_token);
  if a.skey is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  return jsonb_build_object('ok', true,
    'order', (select to_jsonb(o) from orders o where o.session_key = a.skey and o.doc_id = p_doc_id));
end $$;

create or replace function lunch_list_dishes()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(to_jsonb(d) order by d.times_used desc), '[]'::jsonb) from dishes d
$$;

-- ---------- Tạo / sửa / xoá session ----------
create or replace function lunch_create_session(p_key text, p_fields jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare ot text; mt text; now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if p_key is null or p_key !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}(-[a-z0-9]{1,8})?$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_key');
  end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'bad_fields');
  end if;
  if jsonb_typeof(coalesce(p_fields->'menu', '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_fields->'menu', '[]'::jsonb)) > 80
     or pg_column_size(coalesce(p_fields->'menu', '[]'::jsonb)) > 30000 then
    return jsonb_build_object('ok', false, 'reason', 'bad_menu');
  end if;
  -- chặn spam tạo hàng loạt: tối đa 30 đơn mới / phút trên toàn hệ thống
  if (select count(*) from sessions where created_at > now_ms - 60000) >= 30 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;
  if exists (select 1 from sessions where key = p_key) then
    return jsonb_build_object('ok', false, 'reason', 'exists');
  end if;
  ot := encode(gen_random_bytes(12), 'hex');
  mt := encode(gen_random_bytes(12), 'hex');
  insert into sessions (key, date, status, price_per_set, host_pays, show_payment_to_team, deadline_at, deadline, auto_close,
                        host_name, shop_name, menu, bank_bin, bank_name, account_no, account_name,
                        order_token, manage_token, created_at)
  values (p_key,
          coalesce((p_fields->>'date')::date, current_date),
          'open',
          coalesce((p_fields->>'price_per_set')::integer, 35000),
          coalesce((p_fields->>'host_pays')::boolean, true),
          coalesce((p_fields->>'show_payment_to_team')::boolean, true),
          coalesce((p_fields->>'deadline_at')::bigint, 0),
          p_fields->>'deadline',
          coalesce((p_fields->>'auto_close')::boolean, true),
          p_fields->>'host_name', p_fields->>'shop_name',
          coalesce(p_fields->'menu', '[]'::jsonb),
          p_fields->>'bank_bin', p_fields->>'bank_name', p_fields->>'account_no', p_fields->>'account_name',
          ot, mt, now_ms);
  return jsonb_build_object('ok', true, 'order_token', ot, 'manage_token', mt, 'created_at', now_ms);
end $$;

-- Chỉ các khoá trong danh sách trắng được sửa; không bao giờ đổi key/token/created_at.
create or replace function lunch_update_session(p_manage_token text, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_manage_token);
  if a.skey is null or a.role <> 'manage' then return jsonb_build_object('ok', false, 'reason', 'forbidden'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_fields'); end if;
  if p_patch ? 'menu' and (jsonb_typeof(p_patch->'menu') <> 'array'
       or jsonb_array_length(p_patch->'menu') > 80 or pg_column_size(p_patch->'menu') > 30000) then
    return jsonb_build_object('ok', false, 'reason', 'bad_menu');
  end if;
  if p_patch ? 'status' and (p_patch->>'status') not in ('open', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'bad_status');
  end if;
  update sessions set
    status        = case when p_patch ? 'status'        then p_patch->>'status' else status end,
    price_per_set = case when p_patch ? 'price_per_set' then (p_patch->>'price_per_set')::integer else price_per_set end,
    deadline_at   = case when p_patch ? 'deadline_at'   then (p_patch->>'deadline_at')::bigint else deadline_at end,
    deadline      = case when p_patch ? 'deadline'      then p_patch->>'deadline' else deadline end,
    host_pays     = case when p_patch ? 'host_pays' then (p_patch->>'host_pays')::boolean else host_pays end,
    show_payment_to_team = case when p_patch ? 'show_payment_to_team' then (p_patch->>'show_payment_to_team')::boolean else show_payment_to_team end,
    auto_close    = case when p_patch ? 'auto_close'    then (p_patch->>'auto_close')::boolean else auto_close end,
    host_name     = case when p_patch ? 'host_name'     then p_patch->>'host_name' else host_name end,
    shop_name     = case when p_patch ? 'shop_name'     then p_patch->>'shop_name' else shop_name end,
    menu          = case when p_patch ? 'menu'          then p_patch->'menu' else menu end,
    bank_bin      = case when p_patch ? 'bank_bin'      then p_patch->>'bank_bin' else bank_bin end,
    bank_name     = case when p_patch ? 'bank_name'     then p_patch->>'bank_name' else bank_name end,
    account_no    = case when p_patch ? 'account_no'    then p_patch->>'account_no' else account_no end,
    account_name  = case when p_patch ? 'account_name'  then p_patch->>'account_name' else account_name end
  where key = a.skey;
  return jsonb_build_object('ok', true);
end $$;

create or replace function lunch_delete_session(p_manage_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_manage_token);
  if a.skey is null or a.role <> 'manage' then return jsonb_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from sessions where key = a.skey; -- orders/drafting xoá theo (on delete cascade)
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Đơn đặt món ----------
-- p_order = null → xoá. Người cầm link đặt món (role 'order') không được:
-- đặt by_host, tự "xác nhận" thanh toán, ghi khi đơn đã khoá, sửa/xoá đơn đã được host xác nhận.
create or replace function lunch_put_order(p_token text, p_doc_id text, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record; cur orders%rowtype; v_status text; now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  select * into a from lunch_auth(p_token);
  if a.skey is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if p_doc_id is null or p_doc_id !~ '^[A-Za-z0-9_-]{1,64}$' then return jsonb_build_object('ok', false, 'reason', 'bad_doc'); end if;
  select * into cur from orders where session_key = a.skey and doc_id = p_doc_id;

  if a.role = 'order' then
    if a.status = 'closed' then return jsonb_build_object('ok', false, 'reason', 'closed'); end if;
    if found and cur.pay_status = 'confirmed' then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;
  end if;

  if p_order is null or jsonb_typeof(p_order) = 'null' then
    delete from orders where session_key = a.skey and doc_id = p_doc_id;
    return jsonb_build_object('ok', true);
  end if;
  if jsonb_typeof(p_order) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_fields'); end if;
  if pg_column_size(p_order) > 60000 then return jsonb_build_object('ok', false, 'reason', 'too_big'); end if;

  v_status := coalesce(p_order->>'pay_status', 'unpaid');
  if a.role = 'order' and v_status = 'confirmed' then v_status := coalesce(cur.pay_status, 'unpaid'); end if;
  if a.role = 'order' and v_status not in ('unpaid', 'claimed') then v_status := 'unpaid'; end if;

  insert into orders (session_key, doc_id, name, guests, sets, total, price_per_set, pay_method, pay_status, by_host, created_at, updated_at)
  values (a.skey, p_doc_id,
          coalesce(p_order->>'name', ''),
          coalesce(p_order->'guests', '[]'::jsonb),
          coalesce(p_order->'sets', '[]'::jsonb),
          coalesce((p_order->>'total')::integer, 0),
          coalesce((p_order->>'price_per_set')::integer, 35000),
          p_order->>'pay_method',
          v_status,
          case when a.role = 'manage' then coalesce((p_order->>'by_host')::boolean, false) else false end,
          coalesce((p_order->>'created_at')::bigint, now_ms),
          coalesce((p_order->>'updated_at')::bigint, now_ms))
  on conflict (session_key, doc_id) do update set
    name = excluded.name, guests = excluded.guests, sets = excluded.sets, total = excluded.total,
    price_per_set = excluded.price_per_set, pay_method = excluded.pay_method, pay_status = excluded.pay_status,
    by_host = case when a.role = 'manage' then excluded.by_host else orders.by_host end,
    updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Tín hiệu "đang đặt món" ----------
create or replace function lunch_set_drafting(p_token text, p_doc_id text, p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_token);
  if a.skey is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if p_doc_id is null or p_doc_id !~ '^[A-Za-z0-9_-]{1,64}$' then return jsonb_build_object('ok', false, 'reason', 'bad_doc'); end if;
  insert into drafting (session_key, doc_id, name, updated_at)
  values (a.skey, p_doc_id, coalesce(p_name, ''), (extract(epoch from clock_timestamp()) * 1000)::bigint)
  on conflict (session_key, doc_id) do update set name = excluded.name, updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true);
end $$;

create or replace function lunch_clear_drafting(p_token text, p_doc_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_token);
  if a.skey is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  delete from drafting where session_key = a.skey and doc_id = p_doc_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Thư viện món ----------
-- (Không còn hàm ghi cấu hình chung: xem ghi chú đầu file về host_pays/show_payment_to_team.)
-- upsert_dish: giữ tên cũ để tương thích, thêm kiểm tra đầu vào + trần số món.
create or replace function upsert_dish(p_id text, p_name_vi text, p_name_en text)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare found_id text; nm text := btrim(coalesce(p_name_vi, ''));
begin
  if char_length(nm) < 1 or char_length(nm) > 60 or nm ~ '[\u0000-\u001F]' then
    raise exception 'ten mon khong hop le';
  end if;
  select id into found_id from dishes where lower(name_vi) = lower(nm) limit 1;
  if found_id is not null then
    update dishes set times_used = times_used + 1, last_used = current_date where id = found_id;
    return found_id;
  end if;
  if (select count(*) from dishes) >= 3000 then raise exception 'thu vien mon da day'; end if;
  found_id := coalesce(p_id, 'd' || substr(md5(random()::text), 1, 10));
  if found_id !~ '^[A-Za-z0-9_-]{1,40}$' then raise exception 'id mon khong hop le'; end if;
  insert into dishes (id, name_vi, name_en, times_used, last_used)
  values (found_id, nm, left(coalesce(p_name_en, ''), 60), 1, current_date)
  on conflict (id) do update set times_used = dishes.times_used + 1, last_used = current_date;
  return found_id;
end $$;

create or replace function lunch_delete_dish(p_manage_token text, p_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a record;
begin
  select * into a from lunch_auth(p_manage_token);
  if a.skey is null or a.role <> 'manage' then return jsonb_build_object('ok', false, 'reason', 'forbidden'); end if;
  delete from dishes where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================
-- Quyền thực thi: mặc định Postgres cấp EXECUTE cho PUBLIC; thu hồi hết rồi
-- chỉ cấp cho anon/authenticated các hàm API (hàm nội bộ lunch_auth thì không).
-- ============================================================
revoke all on function lunch_auth(text) from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'lunch_get_config()', 'lunch_session_exists(text)', 'lunch_get_state(text)',
    'lunch_get_order(text,text)', 'lunch_list_dishes()', 'lunch_create_session(text,jsonb)',
    'lunch_update_session(text,jsonb)', 'lunch_delete_session(text)', 'lunch_put_order(text,text,jsonb)',
    'lunch_set_drafting(text,text,text)', 'lunch_clear_drafting(text,text)',
    'upsert_dish(text,text,text)', 'lunch_delete_dish(text,text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon', f);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;
