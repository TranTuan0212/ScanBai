# 📡 ĐẶC TẢ HỆ THỐNG CARDLINK BROADCAST IOS (V1.0 - OFFICIAL)

Tài liệu đặc tả kiến trúc kỹ thuật, quy định lifecycle, camera pipeline 240 FPS và các nguyên tắc dành riêng cho nền tảng **iOS Swift/SwiftUI**.

---

## 1. PHẠM VI VÀ NGUYÊN TẮC KỸ THUẬT IOS

### 1.1. Background Camera Policy trên iOS
- **Hạn chế Apple**: iOS cấm hoàn toàn việc mở camera khi ứng dụng rơi vào Background hoặc khi người dùng bấm nút nguồn khóa màn hình thật.
- **Giải pháp Khóa Màn Hình Giả (`FakeLockScreenView`)**:
  - Ứng dụng duy trì hoạt động 100% ở **Foreground**.
  - Bật `UIApplication.shared.isIdleTimerDisabled = true` để chống màn hình tự tắt/ngủ.
  - Khi kích hoạt Khóa Giả, ứng dụng phủ màu đen, ẩn UI điều khiển và giảm độ sáng màn hình xuống tối đa (`UIScreen.main.brightness = 0.01`) để tiết kiệm pin và hạn chế sinh nhiệt.

### 1.2. Camera Pipeline 240 FPS (Ultra High-Speed Zero-Blur Capture)
- **Tần số quay 240 FPS**: Khóa `AVCaptureDevice` ở định dạng `1080p @ 240 FPS` (thời gian phơi sáng 1 frame $\approx 4.16\text{ ms}$). Triệt tiêu hoàn toàn Motion Blur mờ nhòe khi chia bài siêu tốc.
- **Bộ đệm Ring Buffer & Laplacian Sharpness Filter**:
  - Lưu giữ chuỗi `CVPixelBuffer` ở tốc độ 240 FPS.
  - Tính toán độ sắc nét (Laplacian Variance / Gradient) để tự động chọn ra **1 frame nét nhất** cung cấp cho AI Vision.
- **Phân tách luồng**:
  - **AI Engine**: Xử lý trên luồng 240 FPS để đọc chính xác 100%.
  - **Stream Server**: Downsample về 30–60 FPS để tải mượt mà, tiết kiệm băng thông.

### 1.3. Persistent Device Identifier (`deviceId`)
- `deviceId` là chuỗi UUID v4 sinh **1 lần duy nhất** khi cài đặt ứng dụng lần đầu.
- Được lưu cố định trong `UserDefaults` (`cardlink_persistent_device_id`). Không sinh ngẫu nhiên theo từng session.

### 1.4. Bộ lọc chống nhiễu AI (Flicker Filter & State Machine)
- **3-Frame Confirmation**: Lá bài nhận diện mới phải xuất hiện liên tiếp tối thiểu **3 frame** ($\ge 100\text{ ms}$) với `confidence >= 0.75`.
- **State Machine**: Trạng thái `NoCard ↔ CardActive(label)`. Tự động reset về `NoCard` nếu không thấy bài trong $1.5\text{ s}$.

---

## 2. DANH SÁCH FILE DỰ ÁN IOS (`ios/CardLink`)

- `CardLinkApp.swift`: Entry point của ứng dụng SwiftUI.
- `Services/DeviceUtils.swift`: Quản lý lưu trữ `deviceId` và `serverIP` cố định trong `UserDefaults`.
- `Services/CameraManager.swift`: Quản lý `AVCaptureSession` khóa cứng 240 FPS 1080p.
- `Services/CardDetector.swift`: Xử lý AI Vision & lọc frame bài nét nhất.
- `Services/CardSlowMoSlicer.swift`: Thuật toán Ring Buffer 240 FPS, Laplacian Variance, Flicker Filter 3-frame.
- `Services/APIService.swift`: Gọi REST API login, start live session, heartbeat.
- `Services/SocketManager.swift`: Giao tiếp WebSocket Real-Time.
- `Views/FakeLockScreenView.swift`: Màn hình Khóa Màn Hình Giả tối ưu độ sáng & chống Sleep.
- `Views/LiveView.swift`: Giao diện phát live chính, HUD bar 240 FPS và điều khiển.
