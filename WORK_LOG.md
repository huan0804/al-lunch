# Work Log — Cơm trưa team

Nhật ký tiến độ theo phiên làm việc. Mới nhất ở trên cùng. Xem [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) cho spec sản phẩm đầy đủ, [CLAUDE.md](CLAUDE.md) cho kiến trúc code.

---

## 2026-10-31: RPC SECURITY DEFINER cho "Đặt cơm trưa" (nhánh `rpc-security`, CHƯA deploy)

Việc "Chặn trước khi công khai" của mục 2026-10-15. Bản cũ để RLS mở cho anon key: ai cũng đọc được **cả `manage_token` của mọi đơn** (bảng `sessions` select không điều kiện) và sửa/xoá đơn bất kỳ.

- **Đã làm (trên nhánh, chưa merge/push):** `lunch-rpc-schema.sql` (các hàm `lunch_*` + `upsert_dish` có kiểm tra đầu vào; token xác định session + vai trò `manage`/`order`; guest không đặt `by_host`, không tự "xác nhận" thanh toán, không ghi khi đơn đóng/đã xác nhận; whitelist cột khi sửa session; giới hạn tạo 30 đơn/phút), `lunch-lockdown.sql` (gỡ policy, thu quyền bảng của anon, gỡ bảng khỏi publication realtime), `supabase-adapter.js` viết lại để gọi RPC, `sw.js` CACHE v2, `privacy.html` (bản nháp, còn chỗ **[CẦN ĐIỀN]**). `index.html` không đổi.
- **Cài đặt chung → theo từng đơn (cùng ngày, theo yêu cầu):** `config` là 1 dòng dùng chung nên host nào lưu "Cài đặt chung" cũng đổi `hostPays`/`showPaymentToTeam` của MỌI đơn, và `shareUrl` có thể bị trỏ link mời của mọi host sang domain lạ. Nay: `sessions.host_pays` + `sessions.show_payment_to_team` (migration lần đầu copy giá trị config hiện tại sang các đơn đang có), `shareUrl` bỏ hẳn (link mời luôn theo domain của trang), `lunch_set_config` bị gỡ, `config` chỉ đọc. Màn "Cài đặt đơn của tôi" lưu mặc định trong `localStorage` (`comtrua:prefs`), ghi vào đơn khi tạo; mở bằng link quản lý thì hai tuỳ chọn hiển thị cũng ghi vào đúng đơn đang mở. Giá chỉ áp dụng cho đơn tạo sau đó. Hệ quả: người không có link quản lý (link gốc) vẫn lưu được mặc định trên máy mình nhưng không đổi được gì của đơn nào.
- **Realtime bỏ:** anon hết quyền SELECT nên Realtime không còn đẩy sự kiện; adapter thăm dò `lunch_get_state` mỗi 5 s khi tab đang hiện (30 s cho thư viện món, 60 s cho config). Giới hạn gói free (tra 2026-10-31): Supabase 500 MB DB, 5 GB egress, 200 kết nối realtime đồng thời, 2 triệu tin realtime/tháng, **dự án bị tạm dừng sau 1 tuần không hoạt động** (supabase.com/pricing). Vercel Hobby: 100 GB Fast Data Transfer, 1 triệu CDN request, 100 deploy/ngày, **chỉ dùng phi thương mại/cá nhân** (vercel.com/docs/plans/hobby) — phát hành công khai có thu tiền/quảng cáo cần gói Pro.
- **Đã kiểm thử (PGlite = Postgres thật chạy trong Node, KHÔNG phải Supabase):** 65 kiểm tra SQL (quyền theo vai trò, whitelist, khoá, chạy lại được, anon bị từ chối trên bảng nhưng vẫn gọi được RPC) và 33 kiểm tra adapter↔DB (3 "trang" link gốc/host/guest: đặt món, xác nhận, drafting, xoá). **Chưa** thử trên Supabase thật, chưa thử `index.html` trên trình duyệt với adapter mới.
- **Giới hạn còn lại (không có Auth nên không chặn được):** người cầm link đặt món đọc được `doc_id` của người khác cùng đơn nên sửa/huỷ được đơn của họ TRONG CÙNG đơn; `total` do client tính; thư viện món dùng chung, ai cũng thêm được. Chi tiết ở đầu `lunch-rpc-schema.sql`.
- **Thứ tự triển khai (đừng đảo):** (1) chạy `lunch-rpc-schema.sql` trong SQL Editor (không ảnh hưởng bản đang chạy) → (2) merge nhánh + deploy, thử tạo đơn / đặt món / xác nhận bằng 2 thiết bị → (3) chạy `lunch-lockdown.sql`. Sau bước 3 bản cũ hết chạy. Hoàn tác ở cuối `lunch-lockdown.sql`.
- **Thay đổi so với mô tả trong CLAUDE.md:** mục "Three-tier link model" nói "no RPC-level auth, RLS wide open" và dặn đừng thêm lại; nhánh này đảo quyết định đó có chủ đích để phát hành công khai. Nếu merge thì sửa CLAUDE.md cho khớp.

---

## 2026-10-15: PWA + kế hoạch phát hành công khai

Yêu cầu: đưa app lên điện thoại như app thật, cuối cùng muốn phát hành công khai cho mọi người, cần cả iOS. User không có Mac và iPhone.

- **Đã làm (commit `1d19cac`, đã deploy):** biến cả `index.html` và `split.html` thành PWA: `manifest.json` (standalone, nền trắng, theme cam `#F7941D`), `icons/` (icon tạm chữ "AL" trắng trên nền cam, thay được bằng logo thật giữ nguyên tên file), `sw.js` (network-first, chỉ xử lý request cùng origin nên Supabase/realtime/CDN không bị ảnh hưởng). Khi sửa code sau này nên tăng `CACHE` trong `sw.js` (`al-lunch-v1` → `v2`).
- **Đã kiểm tra:** manifest/sw/icon trả 200 trên bản live, trang chủ có thẻ manifest. **Chưa** test cài thật trên Chrome Android / Safari iOS (cần user thử: nút cài đặt, toàn màn hình, link `?manage=`/`?order=` vẫn chạy).
- **Quyết định về lộ trình:** (1) PWA (xong, miễn phí, iPhone cài qua Safari → Thêm vào Màn hình chính); (2) Google Play bằng TWA/Capacitor ($25, làm được trên Windows; tài khoản cá nhân mới có thể phải closed test ~12 người/14 ngày — cần kiểm tra lại quy định hiện hành); (3) App Store để sau cùng ($99/năm, cần Mac hoặc build cloud, không có iPhone thì test mù, Apple 4.2 dễ từ chối app chỉ bọc web).
- **Chặn trước khi công khai:** lunch app (`index.html`) vẫn để RLS mở hoàn toàn cho anon key → công khai thì ai cũng sửa/xoá được đơn người khác. Cần chuyển sang RPC `SECURITY DEFINER` như `split.html` (phải viết lại lớp `supabase-adapter.js`), thêm privacy policy, kiểm tra giới hạn gói free Supabase/Vercel. Với app lên store, app-link/deep-link (`assetlinks.json`, `apple-app-site-association`) và việc `localStorage` (uid, lịch sử host) bị xoá trong WebView cũng là rủi ro cần xử lý.

---

## 2026-10-06: Thêm tính năng Chia tiền nhóm (split bill)

Yêu cầu: host nhập người tham gia một sự kiện, các khoản chi (ai chi, ai tham gia, có nút chọn tất cả), app tính ai phải trả thêm / được nhận lại. Người trả thêm quét QR chuyển vào tài khoản host; người được nhận lại thì host thấy số tiền và xin số tài khoản để chuyển.

- Trang mới `split.html`, vào từ nút "💸 Chia tiền nhóm" ở màn tạo đơn của `index.html`. Ba loại link: tạo mới / `?manage=` cho host / `?view=` cho người tham gia.
- Bảng mới `split_events` + RPC trong `split-schema.sql` (chạy riêng file này trong SQL Editor). Khác bảng cơm trưa: khoá hoàn toàn với anon, chỉ truy cập qua hàm SECURITY DEFINER, nên link xem không lấy được link quản lý hay số tài khoản đầy đủ của người khác.
- Người được nhận lại tự gửi số tài khoản qua link xem; host thấy QR để chuyển. Host cũng nhập hộ được, hoặc copy tin nhắn xin số tài khoản.
- Người trả thêm bấm "Tôi đã chuyển khoản"; host bấm "Đã nhận tiền" / "Đã chuyển" để chốt. Sửa khoản chi làm số tiền đổi thì trạng thái cũ tự mất hiệu lực.
- **Rà soát bảo mật phần chia tiền:** sửa lỗi XSS (tên host trong bảng cán cân chưa qua `esc()`, ai tạo sự kiện cũng chèn được HTML vào trang người xem). `split_set_recv` không cho người xem ghi đè tài khoản nhận tiền đã gửi (chỉ host sửa) — cần chạy lại `split-schema.sql`. Thêm `vercel.json` với `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`. Chưa rà `index.html` (đặt cơm trưa); điểm yếu đã biết: RLS mở cho anon key.
- **Hoàn tất sự kiện:** thêm phase `done` (nút "Hoàn tất sự kiện" ở màn chia bill, báo còn mấy người chưa thanh toán). Host thấy bản tổng kết chỉ xem + "Mở lại sự kiện"; người xem chỉ thấy kết quả của mình, không báo chuyển khoản/gửi tài khoản được nữa. Lịch sử trên máy ghi trạng thái + tổng tiền, hiện badge "Hoàn tất". Phải chạy lại `split-schema.sql` (đổi check constraint). Redirect link xem → link quản lý nay cũng nhận ra sự kiện tạo từ bản cũ (hỏi server để bù viewToken).
- **Màn chọn chức năng ở link gốc:** `al-lunch.vercel.app` giờ hiện 2 thẻ "Đặt cơm trưa" và "Chia tiền nhóm" thay vì vào thẳng màn tạo đơn. Link `?manage=`/`?order=` không đổi. "Đặt đơn nhóm mới" chuyển tới `/#lunch` để bỏ qua màn chọn.
- **Đổi flow (cùng ngày):** thêm bước thu thập khoản chi trước khi chia bill. Host nhập phần của mình rồi gửi link; người khác chọn tên và tự thêm/sửa/xoá khoản do CHÍNH HỌ chi (mọi người thấy cả danh sách, chưa thấy số tiền ai nợ ai). Host bấm "Chốt khoản chi" mới hiện số tiền/QR, và mở lại được. Thêm cột `phase`, RPC `split_set_phase` và `split_guest_expense`; `split_update` có `p_base` để không ghi đè khoản chi người khác vừa thêm (client tự gộp rồi lưu lại). Tạo sự kiện không còn bắt buộc có khoản chi.
- Đã test end-to-end bằng Playwright với RPC giả lập (tạo sự kiện 5 người, 3 khoản chi, người xem chọn tên, gửi tài khoản nhận tiền, báo đã chuyển, host thấy trạng thái). **Chưa** test với Supabase thật.

---

## 2026-09-29 — Host lạc mất link quản lý, tín hiệu "đang đặt món"

### 1. Host tự động về link quản lý khi mở nhầm link guest
Host lỡ thoát `?manage=` và chỉ còn link guest `?order=` đã gửi cho nhóm, không có đường quay lại. Fix trong `boot()`: nếu trình duyệt này có lưu lịch sử (`comtrua:history`) với `role==="host"` khớp `sessionKey` đang mở, `location.replace()` thẳng sang `?manage=...` trước khi render. Chỉ hoạt động trên cùng trình duyệt đã tạo session (giới hạn cố hữu của kiến trúc URL-based, xem CLAUDE.md).

### 2. Tín hiệu "Đang đặt món" cho host + nút xoá
Host trước đây chỉ thấy đơn sau khi guest bấm "Xác nhận đặt món" — không biết ai đang soạn dở, dễ chốt đơn sớm khi còn người chưa kịp đặt. Chỉ hiện tên + "đang đặt...", không lộ món/giá; trigger ngay khi mở màn giỏ hàng.
- Bảng mới `drafting (session_key, doc_id, name, updated_at)` — 1 row/người, ghi đè mỗi lần mở giỏ hàng, heartbeat 30s trong khi cart mở, xoá khi submit/cancel. Dọn dòng hết hạn hoàn toàn ở **client** (TTL 90s lúc render, không cron).
- `supabase-adapter.js`: `setDrafting`/`clearDrafting`/`watchDrafting`. `index.html`: `syncDrafting()` (gọi mỗi `render()`) + khối UI trong `cartView()`, chỉ host thấy, lọc bỏ chính host và ai đã có đơn chính thức.
- Nút xoá tín hiệu (`draft-del`) có confirm (`ask()`), nội dung nhắc rõ nó tự hiện lại trong ~30s nếu người đó vẫn đang mở trang — tránh host tưởng bug.

### 3. Bug schema: CHECK constraint chứa subquery
Chạy lại `supabase-schema.sql` từ đầu (để tạo bảng `drafting`) lộ lỗi có sẵn từ trước: `orders_guests_shape`/`orders_sets_shape` dùng `not exists (select ...)` trực tiếp trong CHECK — Postgres không cho phép subquery trong CHECK dưới bất kỳ hình thức nào (`0A000`). Fix: bọc mỗi điều kiện trong function `immutable` riêng (`guests_shape_ok()`/`sets_shape_ok()`), CHECK gọi hàm thay vì tự chứa subquery.

### Commit trong ngày
```
7e919df Confirm before deleting a "still ordering" signal
1842f48 Fix schema: Postgres CHECK constraints can't contain subqueries
9297b98 Add "who's ordering now" signal for host + delete button
696c066 Auto-redirect host from guest link to their manage link
5d18903 Add link to host's manage page when host reopens their own order via guest link
```

### Việc còn tồn đọng
- Tín hiệu "Đang đặt món" mới chạy schema xong trong session này — chưa xác nhận test thành công end-to-end thật.
- TTL 90s cho draft hết hạn là số chọn tạm, chưa có phản hồi thực tế.

---

## 2026-09-28 — Công thức giá combo mới, menu đủ 4 khu, lịch sử đơn

### 1. Công thức tính tiền combo đổi hoàn toàn
Quán báo giá thật khác công thức cũ. Quy tắc mới: combo đứng một mình — 1 món = base−5.000đ, 2 món = base, từ món thứ 3 mỗi món +20.000đ cố định. Combo đi kèm ≥1 món giá riêng: 1 món combo chỉ tính 20.000đ (không phải base−5.000đ); các bậc còn lại giống nhau. Viết lại `comboSetPrice()`/`setPrice()`, verify bằng script Node độc lập trước khi commit.

### 2. Đủ 4 khu menu (Bữa sáng / Combo / Món riêng / Ăn vặt)
Thêm field `category` cho từng món (chỉ để chia nhóm hiển thị, không đụng cách tính tiền). Bug phát hiện sau deploy: draft "tạo đơn mới" cũ trong `localStorage` (cùng ngày, trước khi thêm breakfast/snack) vẫn qua check "cùng ngày" nên khôi phục menu cũ, che mất auto-fill mới. Fix: `WEEK_MENU_VERSION` stamp vào mỗi draft, draft thiếu/cũ hơn version này tự bị coi là stale và rebuild.

### 3. Lịch sử đơn đã đặt (mới, theo trình duyệt)
Ghi 1 dòng lịch sử (tên quán, ngày, giờ, vai trò, link manage/order) mỗi khi host tạo/sửa session hoặc thành viên đặt món xong. Màn `historyView()` vào từ nút trên màn tạo đơn mới, mỗi dòng bấm vào mở đúng link đã lưu.

### 4. "Hoàn tất đơn, bắt đầu đơn mới"
Action `finish-session`: hỏi xác nhận, điều hướng về root link để bắt đầu session mới — đơn cũ không xoá, xem lại qua Lịch sử.

### Commit trong ngày
```
9d05572 Color section headers (BỮA SÁNG/COMBO/MÓN RIÊNG/ĂN VẶT) orange
9209752 Bump finish-session button font to match "Xoá đơn hàng nhóm" size
6cca330 Color the "finish session" button orange (btn pri) to draw attention
7b9049d Move "finish session" button next to delete, make it a compact pill
26ba8f7 Remove duplicate "Danh sách gửi quán" card, add finish-session flow, show time in history
c8c1ed7 Fix stale localStorage draft hiding the new breakfast/snack auto-fill
b784174 Add Breakfast and Snack to the auto-filled menu, grouped as separate sections
d5794a1 New combo pricing formula, full weekly menu prices, per-browser order history
```

### Việc còn tồn đọng
- Công thức giá combo mới chỉ verify bằng script Node, chưa end-to-end qua UI thật với nhiều tổ hợp món.
- Breakfast/Snack mới thêm — chưa có phản hồi từ đặt món thật (giá, tên món đúng chưa).

---

## 2026-09-26 — Fix feedback từ pilot thật (guest/host dùng bản Supabase)

### 1. Giá riêng cho món đặc biệt (bug thật)
Giá riêng bị "nuốt mất" khi combo với món khác (45k + món thường khác vẫn hiện 35k thay vì cộng đúng). Viết lại `setPrice()`: mỗi món giá riêng luôn cộng đúng giá niêm yết; món thường còn lại tính theo công thức base, trừ trường hợp đúng 1 món thường đi kèm ≥1 món giá riêng thì không gấp đôi (base/2, cho phép lẻ 500đ). Verify bằng Playwright end-to-end trên Supabase production cho mọi tổ hợp.

### 2. Khôi phục draft sau khi refresh
Lưu `S.cart`/`S.md` vào `localStorage`, khoá theo `location.search`. Bug: nhiều ô input không gọi `render()` mỗi lần gõ (tránh vẽ lại toàn trang) → gõ xong refresh ngay là mất trắng vì `saveDraft()` chỉ gắn vào `render()`. Fix: `saveDraftSoon()` debounce 400ms riêng, gọi trực tiếp từ `onInput()`.

### 3. Các fix nhỏ khác
Bỏ chữ "(x2 gấp đôi)" gây hiểu nhầm đặt 2 lần. Bỏ "Tên tiếng Anh" và nút "Còn/Hết món" khỏi màn sửa thực đơn (dữ liệu cũ vẫn đọc được, chỉ không còn UI tạo/sửa). Làm rõ "Chuyển khoản" là trả cho host, không phải cho quán — sửa label + thêm tên host cạnh mã QR.

### Commit trong ngày
```
c42eec3 Update CLAUDE.md to reflect Supabase migration
9d746cf Fix pilot feedback: drop "gấp đôi" wording, per-dish pricing, draft persistence
58a4982 Fix custom dish price to stack instead of being dropped when combined
5c70076 Make the boot loading screen bigger, orange, and centered
a3f00b2 Remove English dish names and the Còn/Hết toggle from menu editing
fa5f118 Clarify that bank transfer payment goes to the host, not the restaurant
```

### Việc còn tồn đọng
- AI đọc ảnh menu vẫn chưa port sang Supabase.
- `com-trua.html` + `mock-runtime.js` (bản Claude Artifact cũ) vẫn còn giữ trong repo làm tham chiếu, chưa quyết định xoá.
