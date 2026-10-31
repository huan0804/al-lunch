-- ============================================================
-- AL Lunch — KHOÁ quyền trực tiếp của anon trên các bảng cơm trưa.
--
-- CHỈ CHẠY SAU KHI: (1) lunch-rpc-schema.sql đã chạy, (2) bản
-- supabase-adapter.js mới (dùng RPC) đã deploy và đặt/đọc đơn thử thành công.
-- Chạy file này SỚM HƠN thì bản app đang chạy sẽ hỏng ngay.
--
-- Sau khi chạy: anon KHÔNG select/insert/update/delete được config, sessions,
-- dishes, orders, drafting; mọi thao tác đi qua hàm lunch_* (SECURITY DEFINER).
-- Hệ quả: Supabase Realtime (postgres_changes) không còn đẩy sự kiện tới anon vì
-- không còn quyền SELECT → adapter mới đã chuyển sang thăm dò (polling).
--
-- HOÀN TÁC (nếu cần quay lại bản cũ): chạy lại supabase-schema.sql (tạo lại policy)
-- rồi grant lại quyền bảng cho anon (xem cuối file).
-- ============================================================

-- Gỡ mọi policy cũ (đọc/ghi mở cho tất cả).
do $$
declare t text;
begin
  foreach t in array array['config', 'sessions', 'dishes', 'orders', 'drafting'] loop
    execute format('drop policy if exists %I_select on %I', t, t);
    execute format('drop policy if exists %I_write on %I', t, t);
    execute format('alter table %I enable row level security', t);
    -- Thu hồi quyền bảng. RLS bật + không policy + không grant = anon không đụng được.
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on table %I from anon', t);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on table %I from authenticated', t);
    end if;
  end loop;
end $$;

-- Gỡ các bảng khỏi publication realtime (không còn ai nhận được sự kiện, đỡ tốn message).
do $$
declare t text;
begin
  foreach t in array array['config', 'sessions', 'dishes', 'orders', 'drafting'] loop
    if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime drop table %I', t);
    end if;
  end loop;
end $$;

-- ---- HOÀN TÁC (bỏ comment nếu cần) ----
-- grant select, insert, update, delete on config, sessions, dishes, orders, drafting to anon;
-- (rồi chạy lại supabase-schema.sql để tạo lại policy và đưa bảng vào publication realtime)
