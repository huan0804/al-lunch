# Work Log — Cơm trưa team

Nhật ký tiến độ theo phiên làm việc. Mới nhất ở trên cùng. Xem [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) cho spec sản phẩm đầy đủ, [CLAUDE.md](CLAUDE.md) cho kiến trúc code.

---

## 2026-10-06: Thêm tính năng Chia tiền nhóm (split bill)

Yêu cầu: host nhập người tham gia một sự kiện, các khoản chi (ai chi, ai tham gia, có nút chọn tất cả), app tính ai phải trả thêm / được nhận lại. Người trả thêm quét QR chuyển vào tài khoản host; người được nhận lại thì host thấy số tiền và xin số tài khoản để chuyển.

- Trang mới `split.html`, vào từ nút "💸 Chia tiền nhóm" ở màn tạo đơn của `index.html`. Ba loại link: tạo mới / `?manage=` cho host / `?view=` cho người tham gia.
- Bảng mới `split_events` + RPC trong `split-schema.sql` (chạy riêng file này trong SQL Editor). Khác bảng cơm trưa: khoá hoàn toàn với anon, chỉ truy cập qua hàm SECURITY DEFINER, nên link xem không lấy được link quản lý hay số tài khoản đầy đủ của người khác.
- Người được nhận lại tự gửi số tài khoản qua link xem; host thấy QR để chuyển. Host cũng nhập hộ được, hoặc copy tin nhắn xin số tài khoản.
- Người trả thêm bấm "Tôi đã chuyển khoản"; host bấm "Đã nhận tiền" / "Đã chuyển" để chốt. Sửa khoản chi làm số tiền đổi thì trạng thái cũ tự mất hiệu lực.
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
