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
  -- 'collect': đang thu thập khoản chi (người tham gia tự nhập khoản mình chi);
  -- 'settle': host đã chốt, hiện số tiền / QR / trạng thái thanh toán.
  -- 'done': host đã hoàn tất sự kiện — chỉ xem lại, người tham gia không ghi được gì nữa.
  phase text not null default 'collect',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table split_events add column if not exists phase text not null default 'collect';

do $$ begin
  -- drop rồi add lại để thêm giá trị 'done' cho DB đã chạy bản cũ
  alter table split_events drop constraint if exists split_phase_ok;
  alter table split_events add constraint split_phase_ok check (phase in ('collect','settle','done'));
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
    'view_token', r.view_token, 'phase', r.phase, 'updated_at', r.updated_at);
end $$;

-- p_base = updated_at host đã tải về lúc bắt đầu sửa. Nếu trong lúc đó có người khác
-- thêm khoản chi (updated_at đổi) thì trả {conflict:true} để client gộp rồi lưu lại,
-- thay vì ghi đè mất khoản chi của người ta.
drop function if exists split_update(text, jsonb);
create or replace function split_update(p_token text, p_data jsonb, p_base timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  if jsonb_typeof(p_data) <> 'object' then raise exception 'invalid data'; end if;
  select * into r from split_events where manage_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if p_base is not null and r.updated_at <> p_base then
    return jsonb_build_object('conflict', true);
  end if;
  update split_events set data = p_data, updated_at = now() where id = r.id returning * into r;
  return jsonb_build_object('updated_at', r.updated_at);
end $$;

-- host chốt khoản chi ('settle'), hoàn tất sự kiện ('done') hoặc mở lại ('collect' / 'settle')
create or replace function split_set_phase(p_token text, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events;
begin
  if p_phase not in ('collect','settle','done') then raise exception 'invalid phase'; end if;
  select * into r from split_events where manage_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if p_phase in ('settle','done') and jsonb_array_length(coalesce(r.data->'expenses','[]'::jsonb)) = 0 then
    raise exception 'no expenses';
  end if;
  update split_events set phase = p_phase, updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true);
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
  return jsonb_build_object('data', r.data, 'status', r.status, 'recv', masked, 'phase', r.phase, 'updated_at', r.updated_at);
end $$;

-- Người tham gia (không phải host) thêm / sửa / xoá khoản chi do CHÍNH HỌ chi,
-- chỉ khi đang ở phase 'collect'. p_op = 'upsert' | 'delete'.
-- p_expense = {id, title, amount, payerId, ids:[...]}; payerId bắt buộc = p_person.
create or replace function split_guest_expense(p_token text, p_person text, p_op text, p_expense jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events; exps jsonb; eid text; old jsonb; clean jsonb; ids jsonb; amt bigint; ttl text;
begin
  if p_op not in ('upsert','delete') then raise exception 'invalid op'; end if;
  select * into r from split_events where view_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if r.phase <> 'collect' then return jsonb_build_object('ok', false, 'reason', 'closed'); end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  if exists (select 1 from jsonb_array_elements(r.data->'people') x
             where x->>'id' = p_person and coalesce((x->>'isHost')::boolean, false)) then
    raise exception 'host must use manage link';
  end if;
  if jsonb_typeof(p_expense) <> 'object' then raise exception 'invalid expense'; end if;
  eid := p_expense->>'id';
  if eid is null or length(eid) > 40 then raise exception 'invalid expense id'; end if;
  exps := coalesce(r.data->'expenses','[]'::jsonb);
  select t.e into old from jsonb_array_elements(exps) as t(e) where t.e->>'id' = eid;
  if old is not null and old->>'payerId' <> p_person then
    return jsonb_build_object('ok', false, 'reason', 'not_yours');
  end if;

  if p_op = 'delete' then
    exps := coalesce((select jsonb_agg(t.e order by t.ord) from jsonb_array_elements(exps) with ordinality as t(e, ord)
                      where t.e->>'id' <> eid), '[]'::jsonb);
  else
    ttl := btrim(coalesce(p_expense->>'title',''));
    if length(ttl) < 1 or length(ttl) > 60 then raise exception 'invalid title'; end if;
    if coalesce(p_expense->>'amount','') !~ '^\d{1,12}$' then raise exception 'invalid amount'; end if;
    amt := (p_expense->>'amount')::bigint;
    if amt <= 0 then raise exception 'invalid amount'; end if;
    if p_expense->>'payerId' is distinct from p_person then raise exception 'payer must be you'; end if;
    ids := p_expense->'ids';
    if jsonb_typeof(ids) <> 'array' or jsonb_array_length(ids) < 1 or jsonb_array_length(ids) > 100 then raise exception 'invalid participants'; end if;
    if exists (select 1 from jsonb_array_elements_text(ids) i where not split_person_exists(r.data, i)) then
      raise exception 'unknown participant';
    end if;
    clean := jsonb_build_object('id', eid, 'title', ttl, 'amount', amt, 'payerId', p_person, 'ids', ids);
    if old is not null then
      exps := (select jsonb_agg(case when t.e->>'id' = eid then clean else t.e end order by t.ord)
               from jsonb_array_elements(exps) with ordinality as t(e, ord));
    else
      if jsonb_array_length(exps) >= 500 then raise exception 'too many expenses'; end if;
      exps := exps || jsonb_build_array(clean);
    end if;
  end if;

  update split_events set data = jsonb_set(r.data, '{expenses}', exps), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function split_claim(p_token text, p_person text, p_amount bigint, p_claim boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r split_events; cur text;
begin
  select * into r from split_events where view_token = p_token for update;
  if not found then raise exception 'not found'; end if;
  if not split_person_exists(r.data, p_person) then raise exception 'unknown person'; end if;
  if r.phase <> 'settle' then return jsonb_build_object('ok', false, 'reason', case when r.phase = 'done' then 'done' else 'collecting' end); end if;
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
  if r.phase <> 'settle' then return jsonb_build_object('ok', false, 'reason', case when r.phase = 'done' then 'done' else 'collecting' end); end if;
  update split_events set recv = recv || jsonb_build_object(p_person, p_bank), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- quyền gọi hàm ----------
grant execute on function split_create(jsonb) to anon, authenticated;
grant execute on function split_get_manage(text) to anon, authenticated;
grant execute on function split_update(text, jsonb, timestamptz) to anon, authenticated;
grant execute on function split_set_phase(text, text) to anon, authenticated;
grant execute on function split_guest_expense(text, text, text, jsonb) to anon, authenticated;
grant execute on function split_set_status(text, text, text, bigint) to anon, authenticated;
grant execute on function split_set_recv_manage(text, text, jsonb) to anon, authenticated;
grant execute on function split_delete(text) to anon, authenticated;
grant execute on function split_get_view(text) to anon, authenticated;
grant execute on function split_claim(text, text, bigint, boolean) to anon, authenticated;
grant execute on function split_set_recv(text, text, jsonb) to anon, authenticated;
