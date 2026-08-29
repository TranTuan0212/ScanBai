# 📡 ĐẶC TẢ HỆ THỐNG CARDLINK BROADCAST (V7.4 - OFFICIAL)

Tài liệu đặc tả kiến trúc kỹ thuật, schema cơ sở dữ liệu, API contract và quy trình triển khai ứng dụng CardLink Broadcast.

---

## 1. PHASE 0: VALIDATION BẮT BUỘC (MANDATORY GATE)

**AI KHÔNG ĐƯỢC PHÉP VIẾT MÃ CHO ĐẾN KHI HOÀN THÀNH CÁC BƯỚC VALIDATION:**

### Bước 1: Xác minh Ant Media Android SDK 2.6.2 & CameraX Pipeline
1. Tìm file SDK AAR tại `app/libs/ant-media-android-sdk-*.aar` hoặc remote maven repo. Nếu chưa có: **DỪNG LẠI và thông báo cho người dùng cung cấp file AAR**.
2. Xác minh class/method: `WebRTCClient`, `IWebRTCClient.MODE_PUBLISH`, `MODE_PLAY`, `init()`, `startStream()`, `stopStream()`, `switchCamera()`.
3. Xác minh pipeline: CameraX cấp frame đồng thời cho `ImageAnalysis` (TFLite) và `Surface/VideoSource` (WebRTC publish) trên cùng 1 camera session.

### Bước 2: Xác minh Android Background Camera & Lifecycle
- CameraX trong Live mode **bắt buộc** bind vào `LifecycleOwner` của `LiveForegroundService` (hoặc `ProcessLifecycleOwner`), **không bind vào Activity**.
- Tắt màn hình điện thoại (Activity `onStop`) -> Service vẫn giữ camera stream.

### Bước 3: Xác minh Logic Role & Device
- `User.role`: Quyền tài khoản.
- Broadcaster: Thiết bị sở hữu active session (nắm Redis lock). Các thiết bị khác (dù role `live`) là Viewer.

### Bước 4: Xác minh `deviceId`
- UUID v4 sinh khi cài đặt lần đầu, lưu trong `SharedPreferences`.

---

## 2. KIẾN TRÚC HỆ THỐNG

- **Backend**: Node.js, Express, Prisma ORM, PostgreSQL, Redis, Socket.IO.
- **Media Server**: Ant Media Server Enterprise 2.6.2 (WebRTC SFU, STUN/TURN, Adaptive Bitrate).
- **Admin Dashboard**: React, Vite, TailwindCSS.
- **Android App**: Kotlin, Jetpack Compose, CameraX, TensorFlow Lite, Hilt DI, WebRTC SDK.

---

## 3. DATABASE SCHEMA (Prisma)

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

model User {
  id          String    @id @default(cuid())
  email       String    @unique
  password    String
  role        Role      @default(view)
  expiredAt   DateTime
  createdAt   DateTime  @default(now())
  updatedAt   DateTime  @updatedAt
  sessions    Session[]
}

model Session {
  id             String    @id @default(cuid())
  userId         String
  user           User      @relation(fields: [userId], references: [id])
  deviceId       String
  streamId       String    @unique
  lockToken      String    @unique
  rounds         Int       @default(3)
  cardStack      Json
  cardCount      Int       @default(0)
  status         Status    @default(active)
  startedAt      DateTime  @default(now())
  endedAt        DateTime?
  createdAt      DateTime  @default(now())
  updatedAt      DateTime  @updatedAt

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

---

## 4. API CONTRACT (REST)

- `POST /api/auth/login`: `{ email, password, deviceId }` -> `{ user, token }`
- `GET /api/users/me`: Headers `Authorization: Bearer <token>` -> User info
- `POST /api/sessions/start`: `{ rounds: 2..9 }` -> `{ sessionId, antMediaWebSocketUrl, streamId }`
- `POST /api/sessions/heartbeat`: `{ sessionId }` -> Gia hạn lock (trả về 403 nếu tài khoản hết hạn)
- `DELETE /api/sessions/:sessionId`: Kết thúc session ngay lập tức (cập nhật `status = 'ended'`, giải phóng Redis lock, emit `live_ended`)
- `GET /api/sessions/active`: Danh sách session active
- `GET /api/admin/dashboard`: Thống kê hệ thống
- `GET/POST /api/admin/users`: Danh sách / Tạo user (với `durationUnit: day/month/year`)
- `DELETE /api/admin/users/:id`: Xóa user (409 nếu user đang live)
- `PUT /api/admin/users/:id/renew`: Gia hạn tài khoản

---

## 5. SOCKET.IO & SYNCHRONIZATION

- Middleware: Xác thực JWT token trong `handshake.auth.token`.
- `join_room(sessionId)`: Server kiểm tra Redis lock và PostgreSQL `lockToken` để gán `socket.isBroadcaster`. Viewer được lưu vào Redis Set `room:{sessionId}:viewers`.
- `card_detected({ sessionId, label })`: Chỉ broadcaster được gửi. Server tuần tự hóa bằng Redis Mutex `mutex:session:{sessionId}` trước khi cập nhật DB và phát `card_state`.
- `viewer_count(count)`: Số lượng unique viewer `deviceId` (không tính broadcaster).
- `live_ended(sessionId)`: Phát khi session kết thúc.

---

## 6. ANDROID CORE LOGIC

1. **CameraX & LiveForegroundService**: Bind use-cases vào Lifecycle của Service. Tách `PreviewView` khi app vào background/tắt màn hình, duy trì phân tích hình ảnh và stream WebRTC.
2. **Card Debounce & Noise Filter**:
   - 3-frame confirmation threshold (conf >= 0.75).
   - State Machine: `NoCard` ↔ `CardActive(label)`.
   - Timeout 1.5s không thấy thẻ để reset state.
3. **Switch Camera**: Chuyển camera runtime không làm đứt kết nối WebRTC.

---

## 7. DANH SÁCH FILE DỰ ÁN

### Backend
- `package.json`, `server.js`, `prisma/schema.prisma`, `prisma/migrations/`
- `src/routes/auth.js`, `src/routes/sessions.js`, `src/routes/admin.js`
- `src/middleware/auth.js`, `src/middleware/admin.js`
- `src/redis/redisClient.js`, `src/redis/lock.js`, `src/redis/mutex.js`, `src/redis/viewers.js`
- `src/websocket/index.js`, `src/utils/cardStack.js`, `src/jobs/reconcile.js`, `.env.example`

### Admin Dashboard
- `package.json`, `vite.config.js`, `index.html`, `src/main.jsx`, `src/App.jsx`
- `src/pages/Login.jsx`, `src/pages/Dashboard.jsx`, `src/pages/Users.jsx`
- `src/api/client.js`, `src/components/Navbar.jsx`, `src/components/UserTable.jsx`

### Android
- `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`, `app/build.gradle.kts`
- `app/proguard-rules.pro`, `app/src/main/AndroidManifest.xml`
- `app/src/main/java/com/cardlink/CardLinkApplication.kt`, `MainActivity.kt`
- `app/src/main/java/com/cardlink/ui/screens/LoginScreen.kt`, `LiveScreen.kt`, `ViewerScreen.kt`, `SelectSessionScreen.kt`
- `app/src/main/java/com/cardlink/camera/CameraXManager.kt`
- `app/src/main/java/com/cardlink/ml/CardDetector.kt`, `MockDetector.kt`, `TFLiteDetector.kt`, `CardDebounce.kt`
- `app/src/main/java/com/cardlink/webrtc/AntMediaManager.kt`
- `app/src/main/java/com/cardlink/network/RetrofitClient.kt`, `SocketManager.kt`
- `app/src/main/java/com/cardlink/service/LiveForegroundService.kt`
- `app/src/main/java/com/cardlink/utils/SharedPrefs.kt`, `AppModule.kt`
