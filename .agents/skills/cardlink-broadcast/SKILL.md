---
name: cardlink-broadcast
description: >-
  Comprehensive guide, specification, and implementation workflow for the CardLink Broadcast system (Android Kotlin, Node.js Express, PostgreSQL Prisma, Redis, Socket.IO, Ant Media WebRTC).
  Activate this skill when creating, modifying, validating, or implementing the CardLink Broadcast project.
---

# CardLink Broadcast System - Technical Skill & Implementation Guide

Tài liệu hướng dẫn triển khai toàn diện hệ thống CardLink Broadcast theo đặc tả V7.4.

---

## 1. QUY TRÌNH THỰC HIỆN PHASE 0 (VALIDATION GATE)

Trước khi viết bất kỳ file code nào, agent phải thực hiện lần lượt các bước kiểm tra sau:

### Bước 1: Kiểm tra Artifact Ant Media SDK 2.6.2
1. Quét tìm file AAR tại `app/libs/ant-media-android-sdk-*.aar` hoặc các repository được cấu hình trong `settings.gradle.kts`.
2. Nếu không tìm thấy artifact:
   - **DỪNG LẠI và thông báo cho người dùng**: *"Cần cung cấp file SDK `ant-media-android-sdk-*.aar` vào thư mục `app/libs/` trước khi tiến hành viết code Android."*
3. Nếu đã có artifact:
   - Xác minh public API: `WebRTCClient`, `IWebRTCClient.MODE_PUBLISH`, `IWebRTCClient.MODE_PLAY`, `init()`, `startStream()`, `stopStream()`.
   - Xác minh custom `VideoCapturer` hoặc cơ chế nhận frame từ CameraX.

### Bước 2: Kiểm tra Android CameraX & Foreground Service
- Xác minh `LiveForegroundService` quản lý `LifecycleOwner` riêng cho CameraX.
- Đảm bảo khi Activity bị dừng (màn hình tắt), CameraX vẫn duy trì phiên camera để stream và nhận diện TFLite.

---

## 2. KIẾN TRÚC VÀ CÁC THÀNH PHẦN

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

---

## 3. PRISMA SCHEMA (PostgreSQL)

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

Partial Unique Index Migration SQL:
```sql
CREATE UNIQUE INDEX "Session_one_active_per_user"
ON "Session" ("userId")
WHERE "status" = 'active';
```

---

## 4. API & SOCKET.IO SPECIFICATIONS

### REST Endpoints
- `POST /api/auth/login`: `{ email, password, deviceId }` -> `{ user, token }`
- `GET /api/users/me`: Headers `Authorization: Bearer <token>` -> User info (check `expiredAt`)
- `POST /api/sessions/start`: `{ rounds: 2..9 }` -> `{ sessionId, antMediaWebSocketUrl, streamId }` (409 nếu lock conflict)
- `POST /api/sessions/heartbeat`: `{ sessionId }` -> Gia hạn lock TTL 15s (nếu hết hạn -> 403)
- `DELETE /api/sessions/:sessionId`: Cập nhật `status = 'ended'`, xóa Redis lock bằng Lua script, emit `live_ended` ngay lập tức
- `GET /api/sessions/active`: Danh sách các session đang live
- `GET /api/admin/dashboard`: Stats cho admin
- `GET/POST /api/admin/users`: Danh sách / Tạo user mới (với `duration` và `durationUnit`: day, month, year)
- `DELETE /api/admin/users/:id`: Xóa user (409 nếu user đang có active live session)
- `PUT /api/admin/users/:id/renew`: Gia hạn tài khoản

### Socket.IO Protocol
- Auth: JWT token truyền trong `handshake.auth.token`.
- `join_room(sessionId)`: Server xác định Broadcaster vs Viewer qua Redis `live_lock:{userId}` và PostgreSQL `Session.lockToken`. Viewer được thêm vào Redis Set `room:{sessionId}:viewers`.
- `card_detected({ sessionId, label })`: Chỉ broadcaster được gửi; xử lý qua Redis Mutex `mutex:session:{sessionId}`.
- `card_state(cardStack)`: Broadcast cho mọi client trong room.
- `viewer_count(count)`: Số lượng unique viewer `deviceId` (loại trừ broadcaster).
- `live_ended(sessionId)`: Broadcast khi session kết thúc.

---

## 5. ANDROID ARCHITECTURE & ALGORITHMS

### 5.1. CameraX Service-Level Lifecycle
```kotlin
// CameraX phải được bind vào LifecycleOwner của LiveForegroundService
class LiveForegroundService : LifecycleService() {
    // Quản lý use-cases (Preview, ImageAnalysis, WebRTC VideoSource)
    // Tách PreviewView khi Activity onStop, nhưng giữ ImageAnalysis và WebRTC
}
```

### 5.2. Card Detection & 3-Frame Debounce Machine
- **Flicker Rejection**: Label mới chỉ hợp lệ khi xuất hiện liên tục tối thiểu 3 frame với `confidence >= 0.75`.
- **Debounce State Machine**:
  - `NoCard` ↔ `CardActive(currentLabel)`.
  - Timer 1.5s không nhận diện được card để reset về `NoCard`.

---

## 6. CHECKLIST KIỂM THỬ (ACCEPTANCE TESTS)
1. **Atomic Lock**: 2 máy cùng start live -> 1 máy 200, 1 máy 409.
2. **Graceful Stop**: Bấm Stop live -> DB update `ended`, Redis lock giải phóng ngay, viewer nhận `live_ended` ngay.
3. **Screen OFF Live**: Khởi động live, bấm tắt màn hình điện thoại Broadcaster -> Viewer vẫn nhận video và nhận diện lá bài bình thường.
4. **Flicker Filter**: 1 frame nhòe không tạo lá bài sai.
5. **Switch Camera**: Chuyển camera trước/sau lúc runtime mượt mà, không ngắt stream.
6. **Card Stacking**: Nhận diện đúng vòng tròn $N$ cột bài.
7. **Viewer Count**: Đếm chính xác unique `deviceId` viewer qua Redis Set.
