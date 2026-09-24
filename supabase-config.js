// Cấu hình Supabase công khai (publishable/anon key — an toàn để lộ ra
// client, giống hệt cách Firebase/Supabase vẫn thiết kế; bảo mật thật sự
// nằm ở RLS + RPC trong supabase-schema.sql, không nằm ở việc giấu key này).
window.SUPABASE_URL = "https://dqagzpvvtqyctaiarwdk.supabase.co";
window.SUPABASE_ANON_KEY = "sb_publishable_iRw9biOWUUxlH8ssMQuvPA_ICmZo4DQ";

// Link chia sẻ cho THÀNH VIÊN (không có quyền host). Đổi thành domain thật
// sau khi deploy lên Vercel, ví dụ "https://al-lunch.vercel.app/".
window.SUPABASE_SHARE_URL = location.origin + location.pathname;
