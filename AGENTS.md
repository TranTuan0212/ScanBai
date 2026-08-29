# CardLink Broadcast - Agent & Workspace Guidelines

Tệp này quy định các nguyên tắc, kiến trúc và quy trình bắt buộc đối với mọi AI Coding Agent khi làm việc trong workspace này.

---

## 1. NGUYÊN TẮC BẮT BUỘC: PHASE 0 VALIDATION GATE

**AI KHÔNG ĐƯỢC PHÉP VIẾT MÃ NGUỒN (CODE) CHO ĐẾN KHI HOÀN THÀNH PHASE 0 VALIDATION:**

1. **Ant Media SDK 2.6.2 & CameraX Pipeline**:
   - Kiểm tra file AAR thực tế tại `app/libs/ant-media-android-sdk-*.aar` hoặc khai báo maven repository tương ứng.
   - Nếu chưa có file AAR và chưa có repository hợp lệ: **DỪNG LẠI và thông báo cho User cung cấp file AAR vào `app/libs/`**.
   - Xác minh class/method thực tế (`WebRTCClient`, `MODE_PUBLISH`, `MODE_PLAY`, video capturer/source API).
   - Xác minh khả năng cấp frame từ CameraX cho cả TFLite (`ImageAnalysis`) và WebRTC publish dùng chung 1 camera session. Không được mở 2 camera session đồng thời.
2. **Android Background Camera Lifecycle**:
   - CameraX trong chế độ Live **BẮT BUỘC** phải bind vào `LifecycleOwner` của `LiveForegroundService` (hoặc `ProcessLifecycleOwner`). **TUYỆT ĐỐI KHÔNG** bind vào Activity Lifecycle.
   - Khi tắt màn hình (Activity `onStop`), chỉ detach UI `PreviewView`, giữ nguyên `ImageAnalysis` (TFLite) và WebRTC capturer.
3. **Role vs Device Logic**:
   - `User.role` là quyền tài khoản. Broadcaster là thiết bị sở hữu active session (nắm Redis Lock). Các thiết bị khác (dù role `live`) đều là Viewer.
4. **Device Identifier**:
   - `deviceId` là UUID v4 sinh 1 lần khi install, lưu trong `SharedPreferences`. Không dùng hardware ID.

---

## 2. KIẾN TRÚC & NGUYÊN TẮC KỸ THUẬT

### 2.1. Backend (Node.js + Prisma + PostgreSQL + Redis + Socket.IO)
- **Source of Truth**: Server là nơi duy nhất lưu trữ và xử lý `cardStack`. Android chỉ gửi event `card_detected({ sessionId, label })`.
- **Concurrency Serialization**: Mọi cập nhật `cardStack` phải được bọc trong **Redis Distributed Mutex** (`mutex:session:{sessionId}`).
- **Atomic Lock**:
  - Key: `live_lock:{userId}`, Value: `lockToken` (UUIDv4), TTL: 15s.
  - Mọi thao tác gia hạn hoặc giải phóng lock phải dùng **Lua script verify `lockToken`**.
- **Graceful Stop (`DELETE /sessions/:sessionId`)**:
  - Cập nhật DB: `status = 'ended'`, `endedAt = now()`.
  - Giải phóng Redis lock `live_lock:{userId}` bằng Lua script ngay lập tức.
  - Emit ngay event `live_ended(sessionId)` tới Socket.IO room.
  - Xóa Redis Set `room:{sessionId}:viewers`.
- **Viewer Tracking**:
  - Quản lý bằng Redis Set `room:{sessionId}:viewers` (lưu `deviceId`).
  - `viewer_count` = `SCARD` loại trừ broadcaster `deviceId`.
- **Account Expiration**:
  - Middleware API và Socket.IO auth kiểm tra `expiredAt > now()`.
  - Nếu `POST /sessions/heartbeat` phát hiện tài khoản hết hạn: trả về 403, tự động release lock, cập nhật `ended` và broadcast `live_ended`.

### 2.2. Android (Kotlin + Compose + CameraX + TFLite + Hilt + WebRTC)
- **Foreground Service**: Khai báo `android:foregroundServiceType="camera"`. Khởi động service khi app đang ở foreground.
- **TFLite Debounce & Chống nhiễu**:
  - Bổ sung **Flicker Filter**: Label mới phải xuất hiện liên tiếp tối thiểu **3 frame** (hoặc ≥ 100ms) với `confidence ≥ 0.75`.
  - State Machine: `NoCard` ↔ `CardActive(label)`. Khi không thấy thẻ liên tục 1.5s → chuyển về `NoCard`.
- **Runtime Camera Switch**: Đổi camera trước/sau trong lúc live mà không ngắt session WebRTC và không làm gián đoạn CardStack.

---

## 3. DANH SÁCH FILE CHÍNH THỨC CỦA DỰ ÁN

Mọi mã nguồn tạo mới phải tuân thủ đúng cấu trúc file đã được quy định trong `SPECIFICATION.md` hoặc skill `cardlink-broadcast`.
