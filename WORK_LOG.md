# Work Log — Cơm trưa team

Nhật ký tiến độ theo phiên làm việc. Mới nhất ở trên cùng. Xem [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) cho spec sản phẩm đầy đủ, [CLAUDE.md](CLAUDE.md) cho kiến trúc code.

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
