# Cơm trưa team: tài liệu bàn giao dự án

Tài liệu này dành cho một phiên Claude khác (ví dụ Claude Desktop) tiếp tục phát triển app. Đọc hết file này trước khi sửa code.

**Các file đi kèm:**

| File | Nội dung |
|---|---|
| `com-trua.html` | Toàn bộ app, gói trong một file HTML: CSS, JS, không dùng framework |
| `mock-runtime.js` | Bản giả lập `window.claude.use(...)` để chạy thử app ngoài Claude (xem mục 9) |
| `PROJECT_HANDOFF.md` | File này |

**Link app đang chạy:** https://claude.ai/artifact/K2uJdJa5pQnRcuwYx7r8pT (Claude artifact, chỉ người trong tổ chức mở được)

---

## 1. Mục tiêu dự án

Công ty cần đặt cơm trưa cho team mỗi ngày. Trưởng nhóm (host) nhận ảnh menu từ quán, cả team chọn món, rồi mỗi người thanh toán bằng tiền mặt hoặc chuyển khoản vào tài khoản host.

App thay cho việc gom đơn bằng tay trong nhóm chat. Nó phải:

- Cho host tạo menu nhanh: upload ảnh menu để AI đọc, chọn lại món cũ, hoặc dán text.
- Cho thành viên chọn món theo **suất**, mỗi suất có ghi chú riêng. Luồng đặt giống **đặt đơn nhóm của Grab/XanhSM** vì team đã quen.
- Tự tính tiền, tạo **QR VietQR có sẵn số tiền và nội dung** chuyển khoản.
- Cho host thấy ngay ai đã trả, ai trả tiền mặt cần thu, ai chưa trả.
- Cho phép **đặt hộ**: một người chọn món và trả tiền luôn cho người khác.

**Hướng tiếp theo do người dùng quyết định:** chuyển app sang **Vercel + Supabase** để thoát giới hạn của Claude artifact: chia sẻ Zalo, không cần tài khoản Claude, mở ứng dụng ngoài (xem mục 8).

---

## 2. Vai trò

| Vai trò | Nhận diện hiện tại | Quyền |
|---|---|---|
| Host / Trưởng nhóm | `user.canEdit()` là true (chủ artifact hoặc người được chia sẻ quyền edit). `user.isOwner()` dùng cho tuỳ chọn "Host tự trả" | Cài đặt ngân hàng, tạo/sửa đơn nhóm, xác nhận thanh toán, sửa/xoá đơn người khác, chốt/mở lại/xoá đơn nhóm, xem lịch sử |
| Thành viên (guest) | Tài khoản Claude, `user.id()` | Đặt/sửa/huỷ đơn của mình trước giờ chốt, đặt hộ, báo đã chuyển khoản |

---

## 3. Quy tắc nghiệp vụ

### 3.1 Giá theo số món trong một suất

Giá cơ bản `pricePerSet` mặc định là 35.000đ, host chỉnh được trong Cài đặt.

| Số món | Cách tính | Giá (base 35k) | Phần ăn |
|---|---|---|---|
| 1 | Gấp đôi món đó | 35.000đ | Món đó được tính 2 phần |
| 2 | Suất chuẩn | 35.000đ | Mỗi món 1 phần |
| n ≥ 3 | base/2 × n, làm tròn đến nghìn | 3 món 53k, 4 món 70k, 5 món 88k, 6 món 105k | Mỗi món 1 phần |

Công thức trong code:

```js
setPrice(n) = Math.round(base * Math.max(n, 2) / 2 / 1000) * 1000
```

Không giới hạn số món trong một suất. Mỗi suất có thêm `qty` (số lượng suất giống hệt nhau).

### 3.2 Đơn nhóm (session)

- Một ngày có thể có **nhiều đơn nhóm**. Id của đơn là `YYYY-MM-DD`, nếu ngày đó đã có đơn thì thêm hậu tố: `YYYY-MM-DD-xxxxx`.
- `config.current` trỏ tới đơn nhóm đang mở. Link app luôn mở đơn này.
- **Giới hạn thời gian:** host chỉnh bằng nút −/+ (bước 5 phút). App lưu `deadlineAt` (ms) và `deadline` ("HH:MM").
- **Tự động chốt đơn** (`autoClose`): nếu bật, qua giờ là khoá. Nếu tắt, host tự bấm "Chốt đơn".
- Đơn bị khoá khi: `status === "closed"`, hoặc ngày của đơn nhỏ hơn hôm nay, hoặc `autoClose` bật và đã quá `deadlineAt`. Host luôn sửa được.
- "Đặt đơn nhóm mới": app hỏi xác nhận, tạo đơn mới rồi chốt đơn cũ. Đơn cũ vẫn xem và thu tiền được ở "Đơn nhóm gần đây".
- "Mở lại" một đơn đã chốt sẽ tắt `autoClose`.

### 3.3 Thanh toán

- Thành viên **bắt buộc chọn** Chuyển khoản hoặc Tiền mặt thì nút "Xác nhận đặt món" mới bật.
- Nếu `hostPays` bật, suất của chủ artifact có `payMethod = "host"` ("Trưởng nhóm") và không cần trả.
- Trạng thái thanh toán:

| payMethod | payStatus | Nhãn hiển thị | Màu |
|---|---|---|---|
| transfer | unpaid | Chưa chuyển | đỏ |
| transfer | claimed | Báo đã chuyển (thành viên tự bấm) | vàng |
| transfer | confirmed | Đã nhận chuyển khoản (host xác nhận) | xanh |
| cash | unpaid | Tiền mặt, chờ thu | cam |
| cash | confirmed | Đã thu tiền mặt | xanh |
| host | confirmed | Trưởng nhóm | xám |

- Khi sửa đơn mà tổng tiền hoặc hình thức thanh toán thay đổi, `payStatus` được đặt lại về `unpaid` và app báo cho người dùng.
- Nội dung chuyển khoản: `COM{DD}{MM} {TEN KHONG DAU}`, tối đa 25 ký tự.

### 3.4 Đặt hộ

- Nút "Đặt hộ" có cho **cả host và thành viên**, trên trang chủ và trong giỏ hàng.
- Bảng Đặt hộ hỏi số người, rồi hiện ô nhập tên từng người. Tên phải đủ, không trùng nhau và không trùng tên người đặt.
- Bảng chọn món có **tab theo từng người**. Mỗi tab có món, ghi chú và số lượng riêng. Nút "Thêm N suất vào giỏ" thêm suất cho mọi người đã chọn món.
- Mọi người được đặt hộ phải có ít nhất 1 suất thì mới xác nhận được.
- Người đặt **thanh toán một lần cho cả nhóm**: một order, một QR, host xác nhận một lần.
- Kết quả cuối (bản copy gửi quán) có mục "Theo người", ghi rõ suất nào của ai.
- Bỏ bớt người được đặt hộ thì các suất của người đó bị xoá.

---

## 4. Mô hình dữ liệu (Claude artifact `db`)

```
config/main
  bankBin, bankName, accountNo, accountName (IN HOA KHÔNG DẤU)
  pricePerSet: 35000
  hostPays: bool
  showPaymentToTeam: bool          // cho thành viên xem ai đã trả (chỉ tên + trạng thái)
  shareUrl: string                 // link gửi cho team
  current: sessionKey | null

sessions/{sessionKey}
  date: "YYYY-MM-DD", status: "open" | "closed", createdAt
  pricePerSet                      // chụp lại giá lúc tạo đơn
  deadlineAt (ms), deadline "HH:MM", autoClose: bool
  hostName, shopName
  menu: [{ id, nameVi, nameEn, soldOut }]

orders/{userId | "proxy-xxxx"}
  days: {
    [sessionKey]: {
      name, guests: [tên người được đặt hộ],
      sets: [{ dishes: [{ id, name, portions }], note, qty, price (đơn giá 1 suất), for: tên | null }],
      total, pricePerSet,
      payMethod: "cash" | "transfer" | "host",
      payStatus: "unpaid" | "claimed" | "confirmed",
      createdAt, updatedAt, byHost
    }
  }
  // chỉ giữ 60 sessionKey gần nhất

dishes/{id}            // thư viện món
  nameVi, nameEn, timesUsed, lastUsed
```

**Quy tắc quyền (khai báo khi publish):**

```json
{"db":{"rules":[
  {"path":"","read":"view","write":"admin"},
  {"path":"orders","read":"view","write":"admin"},
  {"path":"orders/{self}","write":"interact"}
]},"sample":{},"user":{}}
```

Thành viên chỉ ghi được `orders/<id của mình>`. Host (quyền admin) ghi được tất cả. Team phải được chia sẻ artifact với quyền **"Can interact"**.

**Ghi đơn:** hàm `mutateOrder(docId, sessionKey, fn)` làm theo kiểu đọc, sửa, rồi ghi đè cả document.

---

## 5. Đọc ảnh menu bằng AI

- Dùng `claude.use("sample")` rồi gọi `sample.json(AI_PROMPT, { images: file })`.
- Kết quả trả về là mảng `[{ nameVi, nameEn }]`.
- App so khớp tên với thư viện món bằng hàm `norm()` (bỏ dấu, chữ thường). Món trùng thì dùng lại id cũ để tên món nhất quán.
- Ảnh có thể đưa vào bằng: chọn file, kéo thả, hoặc Ctrl+V.
- Các mã lỗi được xử lý: `not_granted`, `rate_limited`, `image_rejected`, `invalid_json`, `images_unavailable`.
- **Trạng thái kiểm thử:** mới thử với runtime giả lập, chưa xác nhận chạy thật với ảnh thật. Người dùng chưa báo lỗi.
- Khi chuyển sang Vercel: tạo một API route phía server gọi Anthropic Messages API, gửi ảnh dạng base64. API key để trong biến môi trường, không đặt ở client.

---

## 6. UI/UX

### 6.1 Nguyên tắc

- **Luôn nền trắng.** Người dùng đã yêu cầu nhiều lần, và app không đổi theo dark mode của máy. `<html data-theme="light">`, không có khối CSS dark.
- **Bố cục mô phỏng Grab**:
  - Trang quán có thẻ thông tin và các nút dạng pill.
  - Danh sách món có nút **+** tròn màu cam.
  - Bảng chọn món trượt lên từ đáy (bottom sheet).
  - Thanh giỏ hàng cố định ở đáy.
  - Trang "Kiểm tra đơn hàng".
  - Màn "Tạo đơn hàng nhóm" gồm: Chia hoá đơn (bút chì), Giới hạn thời gian −/+, công tắc Tự động chốt đơn.
- Tối ưu cho điện thoại, chiều rộng tối đa 560px.
- Tiếng Việt có dấu đầy đủ.
- **Không dùng `confirm()` hay `alert()`**: Claude artifact chặn chúng. Dùng hàm `ask()` có sẵn, nó hiện hộp xác nhận dạng sheet.

### 6.2 Màu (theo logo công ty: trắng, đen, cam)

| Token | Giá trị | Dùng cho |
|---|---|---|
| `--bg` / `--surface` | #FFFFFF | Nền |
| `--ink` | #111111 | Chữ |
| `--muted` | #6B6B6B | Chữ phụ |
| `--line` | #EAEAEA | Viền, đường kẻ |
| `--brand` | #F7941D | Nút chính, nút +, thanh giỏ hàng, checkbox/radio đang chọn |
| `--brand-ink` | #111111 | Chữ trên nền cam (không dùng chữ trắng vì tương phản kém) |
| `--sel` | #111111 | Tab và chip đang chọn (nền đen, chữ trắng) |
| `--ok` / `--chili` / `--amber` | xanh / đỏ / cam đậm | Chỉ dùng cho trạng thái thanh toán |

- Font: **Be Vietnam Pro** (Google Fonts), fallback là font hệ thống.
- Số tiền dùng `font-variant-numeric: tabular-nums`, định dạng `35.000đ`.

### 6.3 Các màn hình

| View | Thành phần chính |
|---|---|
| `home` | Nút Cài đặt (host); thẻ quán có dải "Đơn hàng nhóm của X"; các pill Mời thêm thành viên / Quản lý đơn hoặc Đơn của tôi / Sửa thực đơn / Đặt đơn nhóm mới / Đặt hộ; Thực đơn hôm nay kèm cách tính giá; Đơn nhóm gần đây (host); thanh giỏ hàng |
| sheet `item` | Tab theo người (khi đặt hộ); checkbox món; ghi chú; số lượng; nút "Thêm vào giỏ hàng" có giá |
| sheet `proxy` | Đặt hộ mấy người (−/+); ô tên từng người; nút Xong, chọn món; nút Bỏ đặt hộ |
| sheet `share` | Tin nhắn mời; nút cam Copy tin nhắn mời; các ô Zalo / Teams / Facebook / Chỉ copy link |
| sheet `confirm` | Hộp xác nhận thay cho `confirm()` |
| `cart` | Topbar "Kiểm tra đơn hàng" + Mời thêm; khối Quản lý đơn nhóm (host); giỏ hàng chia theo người; thanh toán (radio); tổng tạm tính; QR + nút "Tôi đã chuyển khoản"; thành viên đã đặt (host có bộ lọc Tất cả / Chưa trả / Cần thu tiền mặt); Xoá đơn hàng nhóm |
| `create` | Tên trưởng nhóm, tên quán, Chia hoá đơn, Giới hạn thời gian, Tự động chốt đơn; tải ảnh menu; Chọn món đã từng có; Dán text; danh sách món (sửa tên, Còn/Hết món, xoá) |
| `bank` | Ngân hàng (có sẵn danh sách BIN), số tài khoản, tên chủ tài khoản, QR xem thử, giá suất, công tắc hostPays và showPaymentToTeam, link chia sẻ |

### 6.4 Kiến trúc code

- Vanilla JS. Toàn bộ trạng thái nằm trong object `S`.
- `render()` vẽ lại toàn bộ `#app` và `#overlay` (sheet), đồng thời giữ lại focus và vị trí con trỏ của ô input đang gõ.
- Sự kiện dùng delegation qua thuộc tính `data-a` (action) và `data-f` (field).
- Trạng thái mở/đóng của thẻ `<details>` lưu trong `S.open`.
- `S.cart` là giỏ hàng nháp, chỉ ghi vào db khi bấm "Xác nhận đặt món".
- QR tạo phía client: payload EMVCo VietQR (`vietqr()` có CRC16), vẽ bằng `qrcode-generator@1.4.4` từ cdnjs. Không dùng ảnh từ img.vietqr.io vì CSP chặn ảnh ngoài.

---

## 7. Tiến độ

### Đã xong

- Cài đặt ngân hàng, xem thử QR; giá suất chỉnh được.
- Tạo đơn nhóm kiểu Grab: giới hạn thời gian, tự chốt, tên trưởng nhóm, tên quán.
- Menu từ ảnh (AI), từ thư viện món, copy thực đơn đơn trước, dán text; đánh dấu hết món.
- Nhiều đơn nhóm trong một ngày; lịch sử "Đơn nhóm gần đây" để thu tiền đơn cũ.
- Chọn món theo suất, tính giá theo số món, số lượng, ghi chú.
- Đặt hộ cho mọi người, tab theo từng người, thanh toán gộp.
- Bắt buộc chọn thanh toán trước khi xác nhận.
- QR VietQR có số tiền và nội dung; nút "Tôi đã chuyển khoản".
- Quản lý của host: tổng suất, tổng tiền, đã nhận, tiền mặt cần thu, chuyển khoản chưa xác nhận; tổng món gửi quán (tính theo phần, có mục "Theo người"); copy danh sách chưa trả; xác nhận hoặc hoàn tác thanh toán; sửa/xoá đơn; chốt, mở lại, xoá đơn nhóm.
- Tuỳ chọn cho team xem trạng thái thanh toán của nhau.
- Giao diện trắng, đen, cam; hộp xác nhận tự làm.

### Giới hạn đã biết (do chạy trong Claude artifact)

- Người dùng phải đăng nhập Claude trong cùng tổ chức.
- **Không mở được ứng dụng ngoài** từ trong app: đã thử trên Android Chrome, Zalo intent, Teams, Facebook đều không mở. `navigator.share` cũng bị chặn. Hiện app chỉ copy tin nhắn mời.
- Trình duyệt chặn `confirm()` và `alert()`.
- Chưa tự đối soát chuyển khoản; host phải bấm xác nhận tay.
- Có dữ liệu cũ từ các bản trước: session không có `hostName` hay `deadlineAt`, order không có `qty`, `guests`, `for`. Code đã xử lý tương thích ngược (`qtyOf`, `deadlineAt()`, giá trị mặc định).

### Chưa kiểm chứng

- Đọc ảnh menu với ảnh thật (xem mục 5).

---

## 8. Kế hoạch chuyển sang Vercel + Supabase

**Giữ nguyên:** giao diện, cách tính giá, VietQR, luồng đặt nhóm, đặt hộ.

**Cần thay:**

1. **Lưu dữ liệu:** `claude.use("db")` thay bằng Supabase. Bốn bảng: `config`, `sessions`, `orders` (nên tách thành bảng `orders` và `order_sets`, bỏ kiểu map `days`), `dishes`. Cập nhật realtime dùng Supabase Realtime.
2. **Nhận diện người dùng:** `user.id()` thay bằng Supabase anonymous sign-in, hoặc một uuid lưu trong localStorage, kèm tên tự nhập.
3. **Quyền host:** thay bằng PIN hoặc link quản lý bí mật. Row Level Security: thành viên chỉ sửa đơn của mình; bảng `config`, `sessions`, `dishes` và `payStatus = confirmed` chỉ host ghi được.
4. **Đọc ảnh:** `sample.json` thay bằng API route `/api/read-menu` gọi Anthropic API; key đặt trong biến môi trường.
5. **Chia sẻ:**
   - Dùng `navigator.share` (bảng chia sẻ của máy, có Zalo).
   - Trên Android có thể mở thẳng Zalo bằng intent: `intent:#Intent;action=android.intent.action.SEND;type=text/plain;package=com.zing.zalo;S.android.intent.extra.TEXT=...;end`.
   - Teams: `https://teams.microsoft.com/share?href=...&msgText=...`
   - Facebook: `https://www.facebook.com/sharer/sharer.php?u=...`
   - Link chia sẻ đổi `ARTIFACT_URL` thành domain Vercel.
6. **Hộp xác nhận:** có thể giữ `ask()`.
7. **Có thể thêm sau:** tự đối soát chuyển khoản qua webhook SePay hoặc Casso, dựa trên nội dung `COMddmm TEN`.

---

## 9. Chạy thử ngoài Claude

1. Chèn `mock-runtime.js` trước script chính, ví dụ Playwright `add_init_script(path="mock-runtime.js")`, rồi mở `com-trua.html`.
2. Mock giả lập `db` (lưu trong bộ nhớ, có `onSnapshot`), `user` (id `u1`, là host) và `sample` (trả về 2 món mẫu).
3. Khi test tự động: bấm theo selector `[data-a=...]`. Hộp xác nhận là sheet, nút đồng ý có `data-a="ask-ok"`.

---

## 10. Lịch sử yêu cầu của người dùng (để không lặp lại lỗi)

1. Ban đầu giá tính 1,5 suất cho 3 món, tối đa 3 món. Người dùng sửa lại: tính theo số món, 17.500đ mỗi món, làm tròn (3 món là 53k), không giới hạn số món.
2. Hai lần bị nhắc **nền phải trắng**: không dùng khối hero màu cam, không đổi theo dark mode.
3. Luồng và bố cục phải giống Grab.
4. Nút "Đặt đơn nhóm mới" từng không hoạt động vì `confirm()` bị chặn. Đã sửa bằng `ask()`.
5. Đặt hộ: hỏi số người, nhập tên, người đặt trả hộ, dùng cho cả host lẫn thành viên, mỗi người có món và ghi chú riêng (tab).
6. Người dùng muốn nút Zalo mở màn chia sẻ của Zalo. Không làm được trong artifact, đây là lý do chính để chuyển sang Vercel.
