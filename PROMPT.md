# 📡 PROMPT V7.4 – BẢN ĐẶC TẢ CHÍNH THỨC (FINAL)

*Phiên bản V7.4 hoàn thiện: Tích hợp đầy đủ cơ chế CameraX Service Lifecycle chống tắt camera khi tắt màn hình, quy trình giải phóng Lock tức thì khi DELETE session, bộ lọc nhiễu 3-frame cho TFLite, và quản lý Viewer qua Redis Set.*

---

## PHASE 0: VALIDATION BẮT BUỘC (KHÔNG ĐƯỢC BỎ QUA)

**AI KHÔNG ĐƯỢC PHÉP BẮT ĐẦU XUẤT MÃ CHO ĐẾN KHI HOÀN THÀNH CÁC BƯỚC SAU. NẾU BẤT KỲ BƯỚC NÀO KHÔNG PASS, PHẢI DỪNG VÀ BÁO CÁO CHI TIẾT.**

### Bước 1: Xác minh Ant Media Android SDK 2.6.2 và pipeline CameraX

**AI PHẢI xác minh từ source code/AAR/artifact thực tế của đúng version 2.6.2:**

1. **Xác định artifact chính xác**:
   - Vị trí tìm kiếm: `app/libs/*.aar`, hoặc cấu hình maven/jitpack trong `settings.gradle.kts` / `build.gradle.kts`.
   - Nếu 2.6.2 không có Maven artifact public và chưa có file trong `app/libs/`: AI phải **FAIL Phase 0** và báo rõ cần đặt file AAR vào đường dẫn `app/libs/` cụ thể.
   - **QUAN TRỌNG**: Agent chỉ có thể PASS nếu có quyền truy cập artifact thực tế. Nếu không, phải FAIL và báo cáo. Đây là nguyên tắc bắt buộc, không được PASS Phase 0 nếu chưa kiểm tra artifact thực tế.

2. **Xác minh class/method thực tế** (từ SDK đã tải):
   - `WebRTCClient` (hoặc tên tương đương)
   - `IWebRTCClient.MODE_PUBLISH` và `MODE_PLAY`
   - `init(url, streamId, mode, token)`
   - `startStream()`, `stopStream()`
   - `switchCamera()`, `setOpenFrontCamera()`
   - Các API liên quan đến video source/capturer.

3. **Xác minh camera architecture thực tế của SDK**:
   - SDK sử dụng capturer nào? (có public API không?)
   - Có hỗ trợ **custom `VideoCapturer`** hay không?
   - Có API để nhận `Surface` / `SurfaceTexture` / `Image` từ bên ngoài không?
   - Có API để lấy frame từ camera của SDK cho TFLite không?

4. **Xác minh pipeline bắt buộc** (phải chứng minh được khả thi):
   - **Pipeline A (mong muốn nhất)**: CameraX cung cấp frame cho cả TFLite và WebRTC publish, **dùng chung một camera session**.
     - CameraX → `Preview` (hiển thị UI)
     - CameraX → `ImageAnalysis` → TFLite
     - CameraX → `Surface` / `VideoSource` → Ant Media WebRTC publish
   - **Pipeline B (fallback)**: Ant Media SDK tự quản camera, nhưng có API để lấy frame cho TFLite và vẫn dùng chung camera (không mở hai camera).

5. **Cấm suy luận sai**:
   - **Không được** suy luận rằng `WebRTCClient.switchCamera()` có nghĩa là tích hợp được CameraX.
   - **Không được** suy luận rằng `CameraX Preview Surface` có thể truyền trực tiếp vào Ant Media mà không cần xác minh.
   - **Không được** cho rằng vì SDK có `startStream()` nên pipeline camera đã được giải quyết.

6. **Nếu không xác minh được pipeline A hoặc B**:
   - **FAIL Phase 0**.
   - **DỪNG toàn bộ Android media implementation**.
   - **KHÔNG viết `AntMediaManager.kt`**.
   - **KHÔNG viết CameraX/WebRTC integration giả lập**.
   - Báo cáo chính xác API/artifact nào còn thiếu.

### Bước 2: Xác minh hành vi Background Camera trên Android
- Foreground Service với `FOREGROUND_SERVICE_TYPE_CAMERA` chỉ được phép start khi app đang foreground và đã có `CAMERA` permission (Android 14+ restriction).
- **Yêu cầu Lifecycle**: CameraX session phải được bind vào `LifecycleOwner` của Service (hoặc `ProcessLifecycleOwner`), **KHÔNG bind trực tiếp vào Activity Lifecycle**. Khi màn hình tắt (Activity rơi vào `onStop`), Service vẫn giữ camera stream.
- Phải test trên thiết bị thật API 24–34 và ghi nhận giới hạn OEM. **Không được tuyên bố thành công nếu chỉ test emulator**. Kết quả phải được báo cáo theo từng API/OEM.

### Bước 3: Xác minh logic Role và Device
- `User.role` là **quyền của tài khoản** (cho phép live hay không), không phải trạng thái thiết bị.
- Một tài khoản `live` có thể có nhiều thiết bị; chỉ thiết bị sở hữu `active session` mới là broadcaster; các thiết bị khác (dù role `live`) đều là viewer.
- Điều này được thực thi bởi Redis lock + Session logic, không phải role.

### Bước 4: Xác minh `deviceId`
- `deviceId` là UUID được tạo một lần khi cài đặt lần đầu, lưu trong `SharedPreferences`.
- Ổn định qua các lần restart app.
- **Không dùng** IMEI, MAC address, Android ID, hoặc bất kỳ hardware identifier nào.
- Uninstall/reinstall có thể tạo `deviceId` mới.

### Chỉ khi tất cả các bước trên PASS, mới bắt đầu xuất code. Nếu bất kỳ bước nào FAIL, DỪNG và báo cáo.

---

## 1. MỤC TIÊU VÀ PHẠM VI

Xây dựng hệ thống **CardLink Broadcast** hoàn chỉnh, đáp ứng **10 yêu cầu**:

1. Hai máy Android đăng nhập cùng tài khoản, một máy `live`, các máy còn lại `view`.
2. Chỉ 1 máy `live` duy nhất, nhiều máy `view`.
3. Máy `live` có thể chuyển camera trước/sau trong khi phát.
4. Máy `view` chỉ xem, không được live.
5. Admin tạo tài khoản với thời hạn theo ngày, tháng, năm.
6. Live và View không cần chung Wi-Fi.
7. Máy `live` chọn số lượt (N), card ghép theo vòng.
8. Máy `live` chạy khi tắt màn hình (tuân thủ Android background restrictions và Service lifecycle).
9. Máy `live` nhận diện lá bài (TFLite) và ghép trực tiếp; máy `view` hiển thị các ô ghép.
10. Truyền phát video mượt qua WebRTC + SFU, hỗ trợ nhiều viewer và mạng khác nhau.

Hệ thống bao gồm:
- **Android App** (Kotlin + Compose + Hilt + CameraX + TFLite + WebRTC)
- **Backend** (Node.js + Express + Prisma + PostgreSQL + Redis + Socket.IO)
- **Admin Dashboard** (React + Vite + TailwindCSS)
- **Media Server** (Ant Media Enterprise Edition 2.6.2 – **chỉ sử dụng sau khi xác minh pipeline camera**)

---

## 2. KIẾN TRÚC HỆ THỐNG **BẮT BUỘC** (KHÔNG THAY ĐỔI)

```
┌─────────────────────────────────────────────────────────────────┐
│                    PostgreSQL (Users, Sessions)                 │
│                    - cardStack JSONB (initial [[], [], ...])   │
│                    - cardCount INT                             │
│                    - lockToken STRING (unique)                 │
└─────────────────────────▲───────────────────────────────────────┘
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│                    Node.js + Express API                        │
│                    Socket.IO Server (Card sync)                 │
│                    Redis (Atomic Live Lock & Mutex & Viewers)   │
│                    - CardStack là source of truth (server)     │
│                    - Redis-based distributed mutex per session │
│                    - Redis Set room:{sessionId}:viewers         │
└─────────────────┬───────────────────────┬───────────────────────┘
                  │                       │
       REST API & │                       │ WebSocket (Socket.IO)
      JWT Auth    │                       │ Card state / Room events
                  │                       │
                  ▼                       ▼
        ┌─────────────────┐     ┌──────────────────────────┐
        │  Android Live   │     │  Android Viewer(s)       │
        │  (Broadcaster)  │     │                          │
        │  - CameraX      │     │  - nhận card_state       │
        │  - TFLite       │     │  - nhận video            │
        │  - Switch cam   │     │                          │
        │  - Service Life │     │                          │
        └────────┬────────┘     └──────────────────────────┘
                 │
                 │ WebRTC Publish via Ant Media WebSocket (SDK)
                 ▼
        ┌──────────────────────────────────────────────────┐
        │  Ant Media Server (Enterprise 2.6.2)            │
        │  - WebRTC signaling (WebSocket)                 │
        │  - SFU media forwarding                         │
        │  - STUN/TURN, adaptive bitrate                  │
        └────────────────┬─────────────────────────────────┘
                 │
       WebRTC Subscribers (multiple viewers, mạng khác nhau)
```

**Nguyên tắc quan trọng**:
- **Server là source of truth duy nhất cho CardStack**.
- Android chỉ gửi `card_detected(sessionId, label)`; server cập nhật và broadcast `card_state` cho tất cả.
- **Mọi card update phải được serialized** dùng **Redis-based distributed mutex**.
- **Live và Viewer có thể ở các mạng khác nhau** (Internet). WebRTC với STUN/TURN đảm bảo kết nối.
- **Video không đi qua Node.js backend** – Node.js chỉ xử lý signaling, session, card state. Ant Media chịu trách nhiệm media forwarding.

---

## 3. DATABASE SCHEMA (PostgreSQL + Prisma)

**Prisma Schema** (`prisma/schema.prisma`):

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id          String   @id @default(cuid())
  email       String   @unique
  password    String   // bcrypt hash
  role        Role     @default(view)
  expiredAt   DateTime
  createdAt   DateTime @default(now())
  updatedAt   DateTime @updatedAt
  sessions    Session[]
}

model Session {
  id             String   @id @default(cuid())
  userId         String
  user           User     @relation(fields: [userId], references: [id])
  deviceId       String   // UUID ổn định của installation Android
  streamId       String   @unique
  lockToken      String   @unique // UUID v4, dùng để xác thực ownership trong Redis
  rounds         Int      @default(3) // 2-9
  cardStack      Json     // JSONB, List<List<String>>, KHỞI TẠO: [[], [], ...] (số lượng = rounds)
  cardCount      Int      @default(0) // tổng số card đã nhận, để khôi phục state
  status         Status   @default(active)
  startedAt      DateTime @default(now())
  endedAt        DateTime?
  createdAt      DateTime @default(now())
  updatedAt      DateTime @updatedAt

  @@index([userId])
  @@index([userId, status])
}

enum Role {
  live
  view
  admin
}

enum Status {
  active
  ended
}
```

**Migration**:
- Tạo partial unique index:
  ```sql
  CREATE UNIQUE INDEX "Session_one_active_per_user"
  ON "Session" ("userId")
  WHERE "status" = 'active';
  ```

---

## 4. API CONTRACT (REST)

**Base URL**: `https://your-api-domain.com/api`

**Authentication**: Header `Authorization: Bearer <JWT>`. JWT chứa `userId`, `role`, `deviceId`, `exp`.

| Endpoint | Method | Request Body | Response | HTTP Status | Ghi chú |
|----------|--------|--------------|----------|-------------|---------|
| `/auth/login` | POST | `{ email, password, deviceId }` | `{ user: { id, role, expiredAt }, token }` | 200, 403 (hết hạn), 401 (sai pass) | `expiredAt` là ISO timestamp |
| `/users/me` | GET | - | `{ id, email, role, expiredAt }` | 200, 403 (nếu hết hạn) | Middleware chặn nếu `expiredAt <= now` |
| `/sessions/start` | POST | `{ rounds: 2..9 }` | `{ sessionId, antMediaWebSocketUrl, streamId }` | 200, 409 (lock conflict), 403 (hết hạn), 400 | `streamId = sessionId` |
| `/sessions/heartbeat` | POST | `{ sessionId }` | `{ success }` | 200, 403 (hết hạn tài khoản), 404 | Nếu 403/404: tự giải phóng lock và mark `ended` |
| `/sessions/:sessionId` | DELETE | - | `{ success }` | 200, 403, 404 | **Graceful Stop**: Cập nhật `status = 'ended'`, xóa Redis lock ngay, broadcast `live_ended` ngay |
| `/sessions/active` | GET | - | `[{ sessionId, streamId, antMediaWebSocketUrl, deviceId, startedAt, rounds }]` | 200 | Danh sách session đang live |
| `/admin/dashboard` | GET | - | `{ totalUsers, activeLives }` | 200 | Chỉ admin |
| `/admin/users` | GET | - | `[{ id, email, role, expiredAt, createdAt }]` | 200 | Danh sách user |
| `/admin/users` | POST | `{ email, password, role, duration, durationUnit }` | `{ user }` | 201 | `durationUnit`: `day`, `month`, `year` |
| `/admin/users/:id` | DELETE | - | `{ success }` | 200, 409 (user có active session) | Đang live không được xóa |
| `/admin/users/:id/renew` | PUT | `{ duration, durationUnit }` | `{ newExpiredAt }` | 200 | Gia hạn thời gian |

---

## 5. SOCKET.IO EVENTS & VIEWER TRACKING

### 5.1. Authentication Middleware
```javascript
io.use((socket, next) => {
    const token = socket.handshake.auth.token;
    if (!token) return next(new Error('missing token'));
    try {
        const decoded = jwt.verify(token, JWT_SECRET);
        if (decoded.exp * 1000 <= Date.now()) return next(new Error('token expired'));
        socket.userId = decoded.userId;
        socket.role = decoded.role;
        socket.deviceId = decoded.deviceId;
        socket.exp = decoded.exp;
        next();
    } catch (err) {
        next(new Error('invalid token'));
    }
});
```

### 5.2. Events & Room Management
- `join_room(sessionId)`:
  - Kiểm tra session `status === 'active'`.
  - Server tra cứu `Session.lockToken` và Redis `live_lock:{userId}`. Nếu khớp token và khớp `socket.userId` + `socket.deviceId`, đánh dấu `socket.isBroadcaster = true`. Ngược lại `socket.isBroadcaster = false`.
  - Nếu là viewer: thêm vào Redis Set `SADD room:{sessionId}:viewers {deviceId}`.
  - Server tính `viewerCount = SCARD room:{sessionId}:viewers` (nếu broadcaster vô tình có trong set thì loại trừ), sau đó emit `viewer_count(count)` cho toàn room.
  - Gửi `card_state(cardStack)` hiện tại cho socket vừa join.
- `leave_room(sessionId)` / `disconnect`:
  - Nếu là viewer: `SREM room:{sessionId}:viewers {deviceId}`.
  - Broadcast `viewer_count` mới.
- `card_detected({ sessionId, label })`:
  - **Chỉ broadcaster (`socket.isBroadcaster === true`)** mới được phép gửi.
  - Sử dụng Redis mutex: `mutex:session:{sessionId}` (TTL 3s) để serialize.
  - Đọc `cardStack`, thêm `label` vào index vòng `(cardCount % rounds)`, tăng `cardCount`, cập nhật DB, phát `card_state(cardStack)` cho room.
- `live_ended(sessionId)`: Phát khi session kết thúc (do DELETE, crash, hoặc hết hạn). Xóa key Redis Set `room:{sessionId}:viewers`.

---

## 6. REDIS LOCK VÀ ĐỒNG BỘ SESSION

### 6.1. Redis Live Lock
- Key: `live_lock:{userId}`, Value: `lockToken` (UUIDv4), TTL: 15s.
- Acquire: `SET live_lock:{userId} {lockToken} NX EX 15`.
- Heartbeat (mỗi 5s): Lua script kiểm tra `lockToken` và `EXPIRE 15`. Nếu `User.expiredAt <= now()`, Lua hủy key và báo hết hạn.
- Release: Lua script kiểm tra đúng `lockToken` mới được `DEL`.

### 6.2. Flow `/sessions/start`
1. Validate JWT, kiểm tra `user.expiredAt > now()`, `rounds (2..9)`.
2. Sinh `sessionId` (CUID/UUID) và `lockToken` (UUIDv4).
3. Acquire Redis lock: `SET live_lock:{userId} {lockToken} NX EX 15`. Nếu fail → trả về 409.
4. Bắt đầu DB transaction:
   - Kiểm tra active session cũ của user: Nếu có và lock Redis vẫn hợp lệ → rollback, trả về 409. Nếu lock cũ đã mất → cập nhật session cũ `status = 'ended'`.
   - Tạo Session mới với `cardStack = [[], [], ...]` (N danh sách rỗng tương ứng `rounds`), `cardCount = 0`, `status = 'active'`, `lockToken = lockToken`.
5. Commit transaction. Nếu fail (DB conflict) → chạy Lua script giải phóng Redis lock, trả về 409.
6. Trả về 200 + credentials stream.

### 6.3. Graceful Stop (`DELETE /sessions/:sessionId`)
1. Kiểm tra session thuộc về user hiện tại.
2. Cập nhật DB: `status = 'ended'`, `endedAt = now()`.
3. Giải phóng Redis lock `live_lock:{userId}` bằng Lua script verify `lockToken`.
4. Phát ngay Socket.IO event `live_ended(sessionId)` đến toàn bộ room.
5. Dọn dẹp Redis Set `room:{sessionId}:viewers`.

### 6.4. Reconciliation Cron (mỗi 30s)
- Quét các session đang có `status = 'active'`.
- Kiểm tra Redis key `live_lock:{userId}`. Nếu key mất hoặc token không khớp:
  - Cập nhật `status = 'ended'`, `endedAt = now()`.
  - Phát `live_ended(sessionId)`.

---

## 7. ANDROID IMPLEMENTATION

### 7.1. Role vs Device Logic
- `User.role`: Quyền tài khoản.
- Tài khoản role `live` có thể login trên nhiều máy. Nhưng tại 1 thời điểm, chỉ máy nào gọi `/sessions/start` thành công và nắm giữ Redis lock mới là Broadcaster. Các máy khác tự động chuyển sang chế độ Viewer.

### 7.2. CameraX & Background Service Lifecycle
- **Quy tắc cốt lõi**: `CameraXManager` phải được bind vào **Lifecycle của `LiveForegroundService`** (hoặc `ProcessLifecycleOwner`), **tuyệt đối KHÔNG bind vào Activity Lifecycle**.
- Khi Activity mở: Gắn `PreviewView.surfaceProvider` vào CameraX `Preview` use-case.
- Khi tắt màn hình (Activity `onStop`): Chỉ tách `PreviewView`, giữ nguyên use-case `ImageAnalysis` (cho TFLite) và `Surface/VideoCapturer` (cho WebRTC).
- Chuyển camera runtime: Unbind CameraX use-cases, đổi `CameraSelector` (Front/Back), bind lại vào Service Lifecycle, tiếp tục stream mà không ngắt session WebRTC.

### 7.3. Foreground Service (`LiveForegroundService`)
- Bắt buộc start khi app đang ở Foreground và đã có quyền `CAMERA`.
- Khai báo manifest: `android:foregroundServiceType="camera"`.
- Giữ `WakeLock` và `WifiLock` hợp lệ để duy trì truyền phát khi màn hình tắt.
- Xử lý intent tắt stream từ notification hoặc từ UI.

### 7.4. Card Detection, 3-Frame Confirmation & Debounce
- Interface: `detect(bitmap): Detection?` với `Detection(label, confidence)`.
- **Flicker/Noise Filter (3-frame threshold)**:
  - Để tránh nhiễu do mờ hình 1-2 frame khi di chuyển lá bài: Một label mới chỉ được chấp nhận nếu nhận diện thấy **liên tiếp ít nhất 3 frame** (hoặc duy trì liên tục trong ≥ 100ms) với `confidence ≥ 0.75`.
- **CardDebounce State Machine**:
  - Trạng thái: `NoCard` ↔ `CardActive(currentLabel)`.
  - Khi phát hiện label mới thỏa mãn bộ lọc 3-frame:
    - Nếu đang `NoCard` → chuyển `CardActive(label)`, kích hoạt callback `onNewCard(label)`.
    - Nếu đang `CardActive(oldLabel)` và `newLabel != oldLabel` → chuyển `CardActive(newLabel)`, kích hoạt `onNewCard(newLabel)`.
  - Khi không thấy lá bài nào (hoặc conf < 0.75) liên tục trong **1.5 giây** → chuyển về `NoCard` (cho phép nhận lại lá bài cùng tên ngay sau đó).
- Khi `onNewCard` kích hoạt: Gửi Socket.IO event `card_detected({ sessionId, label })`.

---

## 8. ADMIN DASHBOARD (React + Vite + TailwindCSS)

- Trang Login: Nhập credentials, lưu JWT vào memory / secure storage.
- Trang Dashboard: Thống kê tổng user, số live stream active.
- Trang Quản lý User:
  - Danh sách user kèm trạng thái hạn dùng (`expiredAt`).
  - Form tạo user: Chọn role (`live`, `view`), nhập `duration` và `durationUnit` (`day`, `month`, `year`).
  - Nút Renew: Tăng thêm hạn dùng theo đơn vị ngày/tháng/năm.
  - Nút Delete: Xóa user (nếu user đang có active session thì báo lỗi 409).

---

## 9. WEBRTC & MẠNG THỰC TẾ (ACCEPTANCE)

- Broadcaster và Viewer kết nối qua Ant Media Server SFU.
- Tự động ICE restart khi thiết bị chuyển mạng (Wi-Fi ↔ 4G) mà không thay đổi `sessionId` và không làm mất `cardStack`.
- Độ trễ < 2 giây trong điều kiện mạng thông thường.

---

## 10. ACCEPTANCE TESTS BẮT BUỘC

1. **Atomic Lock**: 2 thiết bị cùng bấm Start Live → 1 máy 200, 1 máy 409.
2. **Lock Ownership**: Broadcaster mất mạng > 15s → Lock hết hạn → Thiết bị khác start được.
3. **Graceful Delete**: Broadcaster bấm Stop Live → DB chuyển `ended`, Redis lock bị xóa ngay, Viewer nhận `live_ended` ngay lập tức.
4. **Flicker Noise Rejection**: Nhòe hình 1 frame thành `K` trong chuỗi `A` → không kích hoạt thẻ `K`.
5. **Debounce Reset**: Giữ thẻ `A` 10s → chỉ 1 event. Bỏ thẻ ra 2s rồi đặt lại thẻ `A` → nhận tiếp event `A` thứ 2.
6. **Card Stacking (N=3)**: Nhận `A, B, C, D, E` → Server lưu và phát: `[[A, D], [B, E], [C]]`.
7. **Viewer Count chính xác**: 3 viewer join → count = 3; 1 viewer tắt app → count = 2; Broadcaster không được tính vào count.
8. **Screen OFF Background Live**: Khởi động live, bấm tắt màn hình điện thoại Broadcaster → Viewer trên máy khác vẫn xem được video và lá bài quét mới vẫn nhảy vào ô ghép.
9. **Runtime Switch Camera**: Chuyển camera trước/sau khi đang live → Video viewer cập nhật góc quay mới mà không rớt kết nối WebRTC.
10. **Account Expiration**: Hết hạn trong lúc đang live → Heartbeat nhận 403 → Phiên live tự động kết thúc.

---

## 11. FILE LIST ĐẦY ĐỦ

### Backend (Node.js + Prisma + PostgreSQL + Redis)
- `package.json`
- `server.js`
- `prisma/schema.prisma`
- `prisma/migrations/`
- `src/routes/auth.js`
- `src/routes/sessions.js`
- `src/routes/admin.js`
- `src/middleware/auth.js`
- `src/middleware/admin.js`
- `src/redis/redisClient.js`
- `src/redis/lock.js`
- `src/redis/mutex.js`
- `src/redis/viewers.js`
- `src/websocket/index.js`
- `src/utils/cardStack.js`
- `src/jobs/reconcile.js`
- `.env.example`

### Admin Dashboard (React/Vite)
- `package.json`
- `vite.config.js`
- `index.html`
- `src/main.jsx`
- `src/App.jsx`
- `src/pages/Login.jsx`
- `src/pages/Dashboard.jsx`
- `src/pages/Users.jsx`
- `src/api/client.js`
- `src/components/Navbar.jsx`
- `src/components/UserTable.jsx`

### Android (Kotlin + Hilt + Compose)
- `settings.gradle.kts`
- `build.gradle.kts` (root)
- `gradle.properties`
- `gradle/wrapper/gradle-wrapper.properties`
- `app/build.gradle.kts`
- `app/proguard-rules.pro`
- `app/src/main/AndroidManifest.xml`
- `app/src/main/java/com/cardlink/CardLinkApplication.kt`
- `app/src/main/java/com/cardlink/MainActivity.kt`
- `app/src/main/java/com/cardlink/ui/screens/LoginScreen.kt`
- `app/src/main/java/com/cardlink/ui/screens/LiveScreen.kt`
- `app/src/main/java/com/cardlink/ui/screens/ViewerScreen.kt`
- `app/src/main/java/com/cardlink/ui/screens/SelectSessionScreen.kt`
- `app/src/main/java/com/cardlink/camera/CameraXManager.kt`
- `app/src/main/java/com/cardlink/ml/CardDetector.kt`
- `app/src/main/java/com/cardlink/ml/MockDetector.kt`
- `app/src/main/java/com/cardlink/ml/TFLiteDetector.kt`
- `app/src/main/java/com/cardlink/ml/CardDebounce.kt`
- `app/src/main/java/com/cardlink/webrtc/AntMediaManager.kt` (chỉ viết sau xác minh)
- `app/src/main/java/com/cardlink/network/RetrofitClient.kt`
- `app/src/main/java/com/cardlink/network/SocketManager.kt`
- `app/src/main/java/com/cardlink/service/LiveForegroundService.kt`
- `app/src/main/java/com/cardlink/utils/SharedPrefs.kt`
- `app/src/main/java/com/cardlink/di/AppModule.kt`
- `app/src/main/res/values/strings.xml`
- `app/src/main/res/values/themes.xml`
- `app/src/main/res/drawable/ic_notification.xml`

---

## 12. QUY TẮC DÀNH CHO AI (BẮT BUỘC, KHÔNG NGOẠI LỆ)

1. **BẮT BUỘC thực hiện Phase 0 Validation trước khi xuất bất kỳ code nào.** Nếu không PASS → DỪNG và báo cáo.
2. **Không tự ý bịa API** hoặc dùng code giả lập nếu chưa xác minh được pipeline Ant Media & CameraX.
3. **Tuân thủ đúng Service Lifecycle cho CameraX**: Không bind CameraX vào Activity.
4. **Server là single source of truth** cho `cardStack`. Android chỉ gửi `card_detected`.
5. **Mọi cập nhật `cardStack` phải qua Redis Mutex** để chống race condition.
6. **Mọi thao tác Redis Lock phải dùng Lua script verify token**.
7. **Đúng mã HTTP Status**: 200 (OK), 201 (Created), 400 (Bad Request), 401 (Unauthorized), 403 (Forbidden/Expired), 409 (Conflict).
8. **Chỉ viết đúng các file có trong danh sách Mục 11**, không tạo file thừa thãi.
