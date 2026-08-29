//
//  LiveView.swift
//  CardLink
//
//  Main Broadcaster Live Screen with Camera Viewfinder, AI Card Overlay,
//  Slow-Motion Card Slicer, Round-Robin Deal Counter, Heartbeat Renewal,
//  and Stealth Fake Lock Screen ("Khóa Màn Hình Giả").
//

import SwiftUI
import AVFoundation

struct LiveView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var cardDetector = CardDetector()
    @StateObject private var socketManager = iOSSocketManager.shared
    @StateObject private var cardSlicer = CardSlowMoSlicer(totalHands: 3)
    
    @State private var isLiveActive = false
    @State private var isFakeLocked = false
    @State private var sessionId: String = "LIVE_\(Int(Date().timeIntervalSince1970))"
    @State private var torchOn = false
    @State private var selectedRounds: Int = 3
    
    @State private var heartbeatTimer: Timer?
    @State private var latestUIImage: UIImage?
    @State private var lastProcessedTime: TimeInterval = 0
    
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    
    var body: some View {
        ZStack {
            // Dark Background
            Color.black.ignoresSafeArea()
            
            // 1. Live Camera Viewfinder
            CameraPreviewHolder(cameraManager: cameraManager)
                .ignoresSafeArea()
            // 2. Real-Time Hand Pose Skeleton Landmark Overlay (Cyan Joints)
            GeometryReader { geometry in
                ForEach(cardDetector.handSkeletonPoints.indices, id: \.self) { idx in
                    let pt = aspectFillPoint(cardDetector.handSkeletonPoints[idx], in: geometry.size)
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 8, height: 8)
                        .shadow(color: .cyan, radius: 3)
                        .position(pt)
                }
            }
            
            // 3. Card Bounding Box Overlay (Bright Glowing Green Frame with Badge)
            if let box = cardDetector.detectionBox {
                GeometryReader { geometry in
                    let rect = aspectFillRect(box, in: geometry.size)
                    
                    ZStack(alignment: .topLeading) {
                        // Glowing Green Bounding Box Line
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green, lineWidth: 3.5)
                            .shadow(color: .green.opacity(0.8), radius: 6)
                            .frame(width: rect.width, height: rect.height)
                        
                        // Card Detection Badge
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                            Text("LÁ BÀI 240FPS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green))
                        .offset(x: 4, y: -22)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
            
            // 3. Top HUD Bar (Status, FPS, Resolution & Round-Robin Counter)
            VStack {
                HStack {
                    // LIVE Status Tag
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isLiveActive ? Color.red : Color.gray)
                            .frame(width: 10, height: 10)
                        
                        Text(isLiveActive ? "LIVE BROADCAST" : "STANDBY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    
                    Spacer()
                    
                    // Hardware FPS & Resolution Info Tag
                    Text("\(Int(cameraManager.currentFPS)) FPS | \(cameraManager.activeResolution)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Dynamic Deal Progress Banner
                if isLiveActive {
                    HStack(spacing: 8) {
                        Text(cardSlicer.statusBannerText)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(cardSlicer.isRoundJustCompleted ? .yellow : .cyan)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.80)))
                    .overlay(Capsule().stroke(cardSlicer.isRoundJustCompleted ? Color.yellow : Color.cyan, lineWidth: 1))
                    .padding(.top, 4)
                }
                
                // Real-Time On-Screen Debug Console Overlay
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("🌐 SERVER:")
                        Text("\(APIService.shared.serverIP):3000")
                            .bold()
                    }
                    HStack {
                        Text("🔌 SOCKET:")
                        Text(socketManager.isConnected ? "CONNECTED ✅" : "DISCONNECTED ❌")
                            .bold()
                            .foregroundColor(socketManager.isConnected ? .green : .red)
                    }
                    HStack {
                        Text("📡 SESSION:")
                        Text(sessionId)
                            .bold()
                    }
                    HStack {
                        Text("🔍 VISION LOG:")
                        Text(cardDetector.debugLogText)
                            .bold()
                            .foregroundColor(.cyan)
                    }
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                
                Spacer()
                
                // 4. Bottom Control Bar (Manual Capture, Torch, Switch Camera, Lock, Start/Stop)
                VStack(spacing: 14) {
                    // Manual Capture Button ("Nút Bóc Bài Thủ Công")
                    if isLiveActive {
                        Button(action: {
                            if let img = latestUIImage {
                                cardSlicer.manualCapture(img)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.aperture")
                                    .font(.system(size: 16, weight: .bold))
                                Text("BÓC BÀI THỦ CÔNG")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.yellow))
                            .shadow(color: .yellow.opacity(0.4), radius: 6, x: 0, y: 3)
                        }
                    }
                    
                    HStack(spacing: 20) {
                        // Enhanced Flash / Torch Toggle Button ("ĐÈN FLASH")
                        Button(action: {
                            torchOn = cameraManager.toggleTorch()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                                    .font(.system(size: 16, weight: .bold))
                                Text(torchOn ? "TẮT FLASH" : "BẬT FLASH")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(torchOn ? .black : .yellow)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(torchOn ? Color.yellow : Color.black.opacity(0.70)))
                            .overlay(Capsule().stroke(Color.yellow, lineWidth: 1.5))
                            .shadow(color: torchOn ? .yellow.opacity(0.6) : .clear, radius: 8)
                        }
                        
                        // Switch Camera Button
                        Button(action: {
                            cameraManager.switchCamera()
                        }) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        
                        // Stealth Lock Button ("KHÓA MÀN HÌNH GIẢ")
                        Button(action: {
                            isFakeLocked = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("KHÓA")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.purple))
                            .shadow(color: .purple.opacity(0.5), radius: 6, x: 0, y: 3)
                        }
                        
                        // Start / Stop Live Session Button
                        Button(action: toggleLiveSession) {
                            Image(systemName: isLiveActive ? "square.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 54, height: 54)
                                .background(Circle().fill(isLiveActive ? Color.red : Color.green))
                                .shadow(color: (isLiveActive ? Color.red : Color.green).opacity(0.5), radius: 8, x: 0, y: 4)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            
            // 5. STEALTH FAKE LOCK SCREEN OVERLAY
            if isFakeLocked {
                FakeLockScreenView(isLocked: $isFakeLocked)
                    .transition(.opacity)
                    .zIndex(999)
            }
        }
        .onAppear {
            setupSlicerCallbacks()
            cameraManager.setupAndStartSession { pixelBuffer, orientation in
                autoreleasepool {
                    guard let uiImage = self.pixelBufferToUIImage(pixelBuffer) else { return }
                    DispatchQueue.main.async {
                        self.latestUIImage = uiImage
                    }
                    
                    // 1. Stream live video frame to Backend downsampled to 10 FPS (~100ms) with lightweight 360p compression (12KB)
                    let now = Date().timeIntervalSince1970
                    if self.isLiveActive && (now - self.lastProcessedTime >= 0.100) {
                        self.lastProcessedTime = now
                        let resized = self.resizeImageForStream(uiImage, targetWidth: 360)
                        if let jpegData = resized.jpegData(compressionQuality: 0.20) {
                            let base64String = jpegData.base64EncodedString()
                            let dataUri = "data:image/jpeg;base64,\(base64String)"
                            self.socketManager.sendLiveFrame(sessionId: self.sessionId, dataUri: dataUri)
                        }
                    }
                    
                    // 2. Full 240 FPS AI Motion & Card Slicer processing with DYNAMIC ORIENTATION!
                    self.cardDetector.processPixelBuffer(pixelBuffer, orientation: orientation) { result in
                        if let zoomedCrop = result?.cardImage, (result?.confidence ?? 0.0) >= 0.70 {
                            // Pass the zoomed-in ROI photo focusing on card & hand!
                            self.cardSlicer.processFrame(zoomedCrop, whitePaperRatio: 0.50, confidence: result?.confidence ?? 0.98)
                        } else {
                            self.cardSlicer.processFrameNoCard()
                        }
                    }
                }
            }
        }
        .onAppear {
            setupSlicerCallbacks()
            let token = APIService.shared.getAuthToken() ?? ""
            socketManager.connect(token: token)
        }
        .onDisappear {
            stopLiveSession()
        }
    }
    
    private func setupSlicerCallbacks() {
        cardSlicer.onCardExtracted = { totalSlot, vanIdx, handIdx, cardIdx, isRoundComplete, imageBase64 in
            if isLiveActive {
                let cardLabel = "VÁN #\(vanIdx) | TỤ #\(handIdx) - LÁ #\(cardIdx)"
                socketManager.sendCardDetected(
                    sessionId: sessionId,
                    label: cardLabel,
                    imageBase64: imageBase64
                )
            }
        }
    }
    
    private func toggleLiveSession() {
        isLiveActive.toggle()
        if isLiveActive {
            startLiveSession()
        } else {
            stopLiveSession()
        }
    }
    
    private func startLiveSession() {
        cardSlicer.reset()
        if !socketManager.isConnected {
            let token = APIService.shared.getAuthToken() ?? ""
            socketManager.connect(token: token)
        }
        socketManager.joinRoom(sessionId: self.sessionId)
        
        APIService.shared.startLiveSession { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    self.sessionId = resp.sessionId
                    self.socketManager.joinRoom(sessionId: resp.sessionId)
                    self.startHeartbeatTimer()
                case .failure(let err):
                    print("⚠️ [iOS API] Start session API fallback: \(err)")
                    self.socketManager.joinRoom(sessionId: self.sessionId)
                }
            }
        }
    }
    
    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            APIService.shared.sendHeartbeat(sessionId: self.sessionId) { success in
                if !success {
                    print("⚠️ [iOS Heartbeat] Expired or invalid session")
                }
            }
        }
    }
    
    private func stopLiveSession() {
        heartbeatTimer?.invalidate()
        socketManager.disconnect()
        cardSlicer.reset()
    }
    
    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = LiveView.sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    private func aspectFillPoint(_ normPt: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0 && size.height > 0 else { return .zero }
        let cameraAspect: CGFloat = 16.0 / 9.0 // 1080p / 1920x1080 portrait aspect ratio
        let viewAspect = size.height / size.width
        
        if viewAspect > cameraAspect {
            let renderedWidth = size.height / cameraAspect
            let offsetX = (renderedWidth - size.width) / 2.0
            let x = normPt.x * renderedWidth - offsetX
            let y = normPt.y * size.height
            return CGPoint(x: x, y: y)
        } else {
            let renderedHeight = size.width * cameraAspect
            let offsetY = (renderedHeight - size.height) / 2.0
            let x = normPt.x * size.width
            let y = normPt.y * renderedHeight - offsetY
            return CGPoint(x: x, y: y)
        }
    }
    
    private func aspectFillRect(_ normRect: CGRect, in size: CGSize) -> CGRect {
        let topLeft = aspectFillPoint(normRect.origin, in: size)
        let bottomRight = aspectFillPoint(CGPoint(x: normRect.maxX, y: normRect.maxY), in: size)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }
    
    private func resizeImageForStream(_ image: UIImage, targetWidth: CGFloat = 360) -> UIImage {
        let size = image.size
        guard size.width > targetWidth else { return image }
        let scale = targetWidth / size.width
        let targetHeight = size.height * scale
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

// UIKit AVCaptureVideoPreviewLayer Wrapper for SwiftUI
struct CameraPreviewHolder: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager
    
    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.setupPreviewLayer(session: cameraManager.captureSession)
        return view
    }
    
    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.updateSession(session: cameraManager.captureSession)
    }
}

final class CameraPreviewUIView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
    
    func setupPreviewLayer(session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)
        self.previewLayer = layer
    }
    
    func updateSession(session: AVCaptureSession) {
        if previewLayer?.session != session {
            previewLayer?.session = session
        }
    }
}
