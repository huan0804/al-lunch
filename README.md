# AL Lunch

Ứng dụng web nhỏ cho nhóm đồng nghiệp, gồm hai chức năng dùng chung một link: **https://al-lunch.vercel.app/**

| Chức năng | Dùng để làm gì |
|---|---|
| 🍱 **Đặt cơm trưa** | Một người tạo đơn nhóm, mời đồng nghiệp chọn món, app tự tính tiền từng người và tạo mã VietQR để thanh toán. |
| 💸 **Chia tiền nhóm** | Chia chi phí chung của một sự kiện (team building, ăn tối…): ai đã chi gì, ai tham gia, cuối cùng ai trả thêm, ai được nhận lại bao nhiêu. |

Giao diện dành cho điện thoại (tối đa 560px), nền trắng cố định, không có chế độ tối.

## Cách dùng

Mở link gốc, chọn một trong hai chức năng. Không cần đăng nhập: quyền truy cập dựa hoàn toàn vào các link có mã bí mật.

### Đặt cơm trưa

1. Host tạo đơn (nhập menu, tài khoản nhận tiền) và được chuyển tới link quản lý `?manage=…`.
2. Host gửi link `?order=…` cho nhóm. Mỗi người chọn món và xác nhận; có thể "đặt hộ" người khác.
3. Host xác nhận thanh toán (tiền mặt hoặc chuyển khoản VietQR), đóng hoặc mở lại đơn khi cần.

Cách tính giá combo và các quy tắc khác nằm trong [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) và [CLAUDE.md](CLAUDE.md).

### Chia tiền nhóm

1. Host nhập tên sự kiện, người tham gia, tài khoản nhận tiền và các khoản host đã chi. Có hai cách tiếp tục:
   - **Cho người khác thêm khoản chi:** tạo sự kiện và gửi link xem; mỗi người chọn tên mình và tự nhập các khoản mình đã chi.
   - **Chốt toàn bộ bill và chia tiền:** dùng khi host đã nhập đủ.
2. Khi đủ khoản chi, host bấm **Chốt khoản chi**. App tính `đã chi − phần phải trả` cho từng người:
   - Người cần trả thêm quét VietQR chuyển cho host, rồi báo "đã chuyển khoản"; host bấm "Đã nhận tiền".
   - Người được nhận lại gửi số tài khoản qua link; host quét QR để chuyển, rồi bấm "Đã chuyển".
3. Host bấm **Hoàn tất sự kiện**. Sự kiện chuyển sang chế độ chỉ xem và vẫn nằm trong mục "Các lần chia tiền trước" (lưu trên từng trình duyệt).

## Công nghệ

- Web tĩnh: HTML, CSS và JavaScript thuần, không build, không framework. Phục vụ trên **Vercel**.
- Dữ liệu trên **Supabase** (Postgres + Realtime). Trang đặt cơm trưa cập nhật theo thời gian thực; trang chia tiền tải lại dữ liệu mỗi 10 giây.
- Mã QR: VietQR (chuẩn EMVCo, tự tính CRC16 phía client), vẽ bằng `qrcode-generator`.

## Cấu trúc thư mục

| File | Vai trò |
|---|---|
| `index.html` | Trang chính: màn chọn chức năng và toàn bộ app đặt cơm trưa |
| `supabase-adapter.js` | Lớp nối giữa `index.html` và Supabase |
| `supabase-config.js` | URL và anon key của Supabase (khoá công khai, được thiết kế để lộ phía client) |
| `supabase-schema.sql` | Bảng, RLS và RPC cho đặt cơm trưa |
| `split.html` | Trang chia tiền nhóm (độc lập, dùng chung `supabase-config.js`) |
| `split-schema.sql` | Bảng và RPC cho chia tiền nhóm |
| `com-trua.html`, `mock-runtime.js` | Bản cũ chạy trên Claude Artifact, chỉ giữ để tham khảo |

## Chạy thử và triển khai

Không có bước build hay test tự động.

- **Chạy local:** phục vụ thư mục này bằng một static server bất kỳ, hoặc mở thẳng `index.html`. App kết nối tới project Supabase thật, không có backend giả lập.
- **Triển khai:** push lên nhánh `main`, Vercel tự deploy.
- **Đổi database:** sửa `supabase-schema.sql` hoặc `split-schema.sql` rồi chạy **toàn bộ file** trong Supabase Dashboard → SQL Editor. Cả hai file chạy lại nhiều lần được. Mỗi lần thêm tính năng ở phía chia tiền cần chạy lại `split-schema.sql` trước khi dùng bản web mới.

## Bảo mật (đọc trước khi sửa phần quyền)

- Đặt cơm trưa: ai có link nào thì làm được đúng phần của link đó. Bảng mở cho anon key, được chấp nhận vì đây là nhóm nhỏ tin cậy.
- Chia tiền nhóm chặt hơn: bảng `split_events` khoá hoàn toàn với anon key, mọi thao tác đi qua hàm `SECURITY DEFINER`. Link xem không lấy được link quản lý và chỉ thấy 4 số cuối tài khoản của người khác.

## Tài liệu trong repo

- [CLAUDE.md](CLAUDE.md): kiến trúc và quy ước code chi tiết.
- [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md): đặc tả sản phẩm ban đầu (phần mô hình dữ liệu và vai trò đã cũ).
- [WORK_LOG.md](WORK_LOG.md): nhật ký thay đổi theo từng phiên.
