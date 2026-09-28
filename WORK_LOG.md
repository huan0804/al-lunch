# Work Log — Cơm trưa team

Nhật ký tiến độ theo phiên làm việc. Mới nhất ở trên cùng. Xem [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) cho spec sản phẩm đầy đủ, [CLAUDE.md](CLAUDE.md) cho kiến trúc code.

---

## 2026-09-28 — Công thức giá combo mới, menu đủ 4 khu, lịch sử đơn, dọn UI

Bối cảnh: tiếp tục pilot thật. User gửi ảnh chụp thực tế của quán (WEEK MENU + menu Thứ Ba in màu) và feedback qua nhiều vòng nhỏ trong ngày.

### 1. Công thức tính tiền combo đổi hoàn toàn
Quán báo giá thật khác công thức cũ (`Math.round(base*n/2/1000)*1000`). Quy tắc mới, xác nhận qua nhiều vòng hỏi lại user với ví dụ số cụ thể:
- Combo đứng một mình: 1 món = base−5.000đ (35k → 30k), 2 món = base (35k), từ món thứ 3 mỗi món thêm **cố định** 20.000đ.
- Combo đi kèm ≥1 món giá riêng (VD Special 45k): 1 món combo chỉ tính 20.000đ (không phải 30k) vì "bụng đã no nhờ món riêng"; 2 món combo vẫn gộp 35k; từ món thứ 3 vẫn +20.000đ/món — chỉ khác duy nhất ở bậc "1 món".
- Viết lại `comboSetPrice()`/`setPrice()` trong `index.html`, verify bằng script Node độc lập cho toàn bộ ví dụ user đưa trước khi commit. Cập nhật `CLAUDE.md` và đánh dấu obsolete công thức cũ trong `PROJECT_HANDOFF.md` §3.

### 2. Đủ 4 khu menu (Bữa sáng / Combo / Món riêng / Ăn vặt) thay vì 2
- `WEEK_MENU` giờ có đủ giá breakfast/snack lấy từ ảnh menu quán gửi (Bún gạo xào/Bún nước tương 30k, các món chính 35k, Bánh mì ốp la 25k, Khoai tây chiên 20k...). Combo đồ chiên không có giá niêm yết → cố ý bỏ qua, để host tự thêm tay.
- Thêm field `category` cho từng món (không đổi schema — `menu` là 1 cột jsonb, field mới tự "đi kèm" trong mỗi item) chỉ dùng để **chia nhóm hiển thị**, không đụng vào cách tính tiền (vẫn hoàn toàn dựa vào `price`). `dishCategory()`/`groupByCategory()`/`categoryLabel()` là logic nhóm dùng chung cho `homeView()`, màn sửa menu, và sheet chọn món "Cơm phần" — trước đó 3 nơi tự lặp lại code `price==null`/`price!=null` riêng. Món cũ không có `category` tự suy ra từ `price` để tương thích ngược.
- **Bug phát hiện sau khi deploy** (user báo "vẫn không thấy thay đổi" dù đã confirm code đã lên production): draft "tạo đơn mới" cũ lưu trong `localStorage` từ **trước** khi thêm breakfast/snack, cùng ngày hôm nay, vẫn qua được check "cùng ngày" nên bị khôi phục nguyên trạng (menu cũ 7 món), che mất auto-fill mới — dù tạo đơn hoàn toàn mới từ link gốc. Fix: thêm `WEEK_MENU_VERSION`, stamp vào mỗi draft mới; draft thiếu field này (hoặc version cũ hơn) bị coi là stale và tự rebuild — tự khắc phục cho user đang có draft kẹt, không cần họ tự xoá cache.

### 3. Lịch sử đơn đã đặt (chưa từng có trước đây)
App không có đăng nhập, chỉ có link riêng theo session (xem "Ba cấp link" trong CLAUDE.md) — hỏi user xác nhận trước khi làm: chọn scope theo **trình duyệt** (localStorage), không phải toàn cục hay tra theo tên. Ghi 1 dòng lịch sử (tên quán, ngày, giờ, vai trò host/guest, link manage/order) mỗi khi host tạo/sửa session (`publishGroup()`) hoặc thành viên đặt món xong (`submitCart()`). Màn `historyView()` mới, vào từ nút trên màn tạo đơn mới (root link); mỗi dòng bấm vào mở đúng link đã lưu, có nút xoá từng dòng/xoá hết.
- Sau feedback tiếp theo: hiện thêm giờ:phút (`h.at`) bên cạnh ngày, vì nhiều session tạo cùng ngày lúc test trông giống hệt nhau khi chỉ có tên quán + ngày.

### 4. "Hoàn tất đơn, bắt đầu đơn mới"
User muốn 1 luồng rõ ràng: copy xong đơn gửi quán → bấm nút → quay về link gốc để bắt đầu session mới, đơn cũ vẫn xem lại được qua Lịch sử. Thêm action `finish-session` (hỏi xác nhận, điều hướng về root link — đơn cũ không xoá, đã tự lưu lịch sử từ lúc tạo). Trải qua 3 vòng chỉnh theo feedback thẩm mỹ: ban đầu đặt trong card "Quản lý đơn nhóm" dạng nút cam to (`.cta` full-width) → bị chê tràn 2 dòng xấu → dời xuống cuối trang ngay trên "Xoá đơn hàng nhóm", đổi sang pill gọn (`.btn`) → bị chê mất màu cam thu hút → đổi `.btn.pri` (cam, dùng chung với nút "Xác nhận đã nhận") → bị chê chữ nhỏ hơn "Xoá đơn hàng nhóm" bên cạnh → tăng font-size khớp 16px.

### 5. Dọn text/UI theo phản hồi nhỏ
- Bỏ khối "Ghi chú:" lặp lại ở cuối text "Copy tổng đơn gửi quán" — ghi chú giờ chỉ nằm inline trong dòng từng người dạng `[Ghi chú: ...]`.
- Bỏ hẳn card "Danh sách gửi quán" trong màn quản lý đơn — trùng lặp y hệt nội dung nút "Copy tổng đơn gửi quán" ngay phía trên, chỉ khác định dạng hiển thị.
- Tô màu cam đậm (`--brand-deep`) cho mọi heading khu (`h3.sec-sub`: BỮA SÁNG/COMBO/MÓN RIÊNG/ĂN VẶT) để dễ phân biệt — 1 dòng CSS dùng chung nên áp dụng nhất quán cả 3 nơi hiển thị nhóm món.

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

### Việc còn tồn đọng / chưa test
- Công thức giá combo mới chỉ verify bằng script Node độc lập (đúng logic), **chưa** verify end-to-end qua UI thật với dữ liệu Supabase production — nên test kỹ trước khi đội dùng đơn thật với nhiều tổ hợp món.
- Lịch sử đơn (`localStorage`) chưa test qua nhiều session/nhiều lần tạo liên tiếp trên máy thật ngoài ảnh chụp user gửi.
- Breakfast/Snack mới thêm — chưa có phản hồi từ việc đặt món thật (giá, tên món đúng chưa) sau khi lên production.

---

## 2026-09-26 — Fix feedback từ pilot thật (guest/host dùng bản Supabase)

Bối cảnh: app đã lên `al-lunch.vercel.app`, đội đang pilot thật. Nhận 4 vòng feedback trong ngày, xử lý và deploy từng vòng.

### 1. Bỏ chữ "x2 gấp đôi" gây hiểu nhầm
Tên món trong giỏ hàng/sheet chọn món từng hiện `"Tên món (x2 gấp đôi)"` khi suất chỉ chọn 1 món — user tưởng nhầm là đặt 2 lần. Bỏ hẳn phần chú thích, chỉ hiện tên món; giá vẫn tính đúng công thức cũ.

### 2. Giá riêng cho món đặc biệt (setPrice viết lại 2 lần)
- **Lần 1**: thêm ô nhập giá tuỳ chọn cho từng món trong màn sửa thực đơn. Ban đầu chỉ áp dụng giá riêng khi suất **chỉ có đúng 1 món** đó — nếu combo với món khác thì rơi về công thức base cũ (im lặng bỏ giá riêng).
- **Lần 2 (bug thật, phát hiện qua ảnh chụp màn hình user gửi)**: giá riêng bị "nuốt mất" khi combo với món khác (45k + món thường khác vẫn hiện 35k). Viết lại `setPrice()`: mỗi món giá riêng luôn cộng đúng giá niêm yết; món thường còn lại trong suất tính theo công thức base dựa trên số lượng món thường đó, **trừ trường hợp đúng 1 món thường đi kèm ít nhất 1 món giá riêng khác thì không gấp đôi** (tính base/2, cho phép lẻ 500đ, không làm tròn thêm — theo yêu cầu rõ ràng của user qua 2 ví dụ cụ thể).
- Đã verify bằng Playwright end-to-end trên Supabase production thật (tạo session test, xoá sau khi xong) cho toàn bộ tổ hợp: 1 món riêng, 1 món riêng+1 thường, +2 thường, +3 thường, 2 món thường không giá riêng.

### 3. Khôi phục draft sau khi refresh (mất trắng cart/menu đang soạn)
- Lưu `S.cart`/`S.md` vào `localStorage`, khoá theo `location.search` (mỗi `?manage=`/`?order=` là 1 URL riêng, tự cô lập giữa các session/host/guest).
- Phát hiện bug trong lúc test: `saveDraft()` ban đầu chỉ gắn vào `render()`, nhưng nhiều ô input (tên quán, tên món, giá...) cố tình **không** gọi `render()` mỗi lần gõ (tránh vẽ lại toàn trang mỗi phím bấm) → gõ xong refresh ngay là mất trắng, chưa từng được lưu. Fix: thêm `saveDraftSoon()` debounce 400ms riêng, gọi trực tiếp từ `onInput()` độc lập với `render()`.
- Verify qua Playwright: cả guest (giỏ hàng đang chọn dở) và host (đang sửa thực đơn dở, kể cả khôi phục đúng lại màn hình "create") đều giữ được state sau F5.

### 4. Bỏ "Tên tiếng Anh" và nút "Còn/Hết món" khỏi màn sửa thực đơn
Theo yêu cầu user: team toàn người Việt (tiếng Anh thừa), và "Hết món" vô nghĩa lúc tạo mới (host chỉ thêm món khi nó đang bán) — quyết định bỏ hẳn tính năng đánh dấu hết món giữa buổi luôn, không giữ lại ở màn sửa đơn đang mở. Dữ liệu cũ có `nameEn`/`soldOut` từ trước vẫn đọc được (hiển thị đúng), chỉ không còn UI để tạo/sửa mới.

### 5. Làm rõ chuyển khoản là trả cho host, không phải cho quán
Guest hiểu nhầm "Chuyển khoản" nghĩa là chuyển thẳng cho quán ăn. Sửa label ở màn chọn thanh toán ("...chuyển cho trưởng nhóm") và thêm ghi chú tên host ngay phía trên mã QR thực tế.

### Bonus: màn "Đang tải" ban đầu
User gửi ảnh thấy spinner nhỏ, xám, lệch góc trên trái lúc mới mở link. Đổi thành spinner cam to, canh giữa màn hình cho đồng bộ brand.

### Ghi chú kỹ thuật phát sinh trong lúc test (không phải bug, chỉ là quirk môi trường test local)
- `publishGroup()` redirect theo `config.share_url` lưu trong Supabase (đang trỏ về domain production thật) — test local phải tự "localize" lại token về `127.0.0.1` sau khi tạo session để tiếp tục test trên bản chưa deploy.
- Server test local cần header `Cache-Control: no-store` — thiếu header này trình duyệt cache lại `index.html` cũ qua các lần điều hướng, dễ gây ảo giác "code mới không chạy".

### Commit trong ngày
```
c42eec3 Update CLAUDE.md to reflect Supabase migration
9d746cf Fix pilot feedback: drop "gấp đôi" wording, per-dish pricing, draft persistence
58a4982 Fix custom dish price to stack instead of being dropped when combined
5c70076 Make the boot loading screen bigger, orange, and centered
a3f00b2 Remove English dish names and the Còn/Hết toggle from menu editing
fa5f118 Clarify that bank transfer payment goes to the host, not the restaurant
```

### Việc còn tồn đọng / chưa test
- AI đọc ảnh menu vẫn chưa port sang Supabase (đã biết từ trước, không phải việc hôm nay).
- Chưa có phản hồi pilot mới sau các fix hôm nay — cần theo dõi vòng dùng thử tiếp theo.
- `com-trua.html` + `mock-runtime.js` (bản Claude Artifact cũ) vẫn còn giữ trong repo làm tham chiếu, chưa quyết định xoá.
