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
    @StateObject private var cardSlicer = CardSlowMoSlicer(totalRounds: 3)
    
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
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 8, height: 8)
                        .shadow(color: .cyan, radius: 3)
                        .position(
                            x: cardDetector.handSkeletonPoints[idx].x * geometry.size.width,
                            y: cardDetector.handSkeletonPoints[idx].y * geometry.size.height
                        )
                }
            }
            
            // 3. AI Card Bounding Box Overlay
            if let box = cardDetector.detectionBox {
                GeometryReader { geometry in
                    let rect = CGRect(
                        x: box.origin.x * geometry.size.width,
                        y: box.origin.y * geometry.size.height,
                        width: box.size.width * geometry.size.width,
                        height: box.size.height * geometry.size.height
                    )
                    
                    Rectangle()
                        .path(in: rect)
                        .stroke(Color.green, lineWidth: 3.5)
                        .overlay(
                            VStack {
                                Text(" [AI CARD: \(cardDetector.lastDetectedCard ?? "DETECTED")] ")
                                    .font(.caption2.bold())
                                    .padding(4)
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                    .offset(y: -25)
                                Spacer()
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        )
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
                
                // Round-Robin Deal Counter Banner
                if isLiveActive {
                    HStack(spacing: 12) {
                        Text("ROUND #\(cardSlicer.currentRoundIndex)/\(cardSlicer.totalRounds)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.cyan)
                        
                        Text("CARD #\(cardSlicer.currentCardIndex)/3")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.orange)
                        
                        Text("TOTAL: \(cardSlicer.totalDealtCards)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
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
                        // Torch Button
                        Button(action: {
                            torchOn = cameraManager.toggleTorch()
                        }) {
                            Image(systemName: torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(torchOn ? .yellow : .white)
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.black.opacity(0.6)))
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
            cameraManager.setupAndStartSession { pixelBuffer in
                // 60 FPS Dynamic Motion Tracking & Frame Streaming (every 16ms)
                let now = Date().timeIntervalSince1970
                guard now - self.lastProcessedTime >= 0.016 else { return }
                self.lastProcessedTime = now
                
                autoreleasepool {
                    guard let uiImage = self.pixelBufferToUIImage(pixelBuffer) else { return }
                    DispatchQueue.main.async {
                        self.latestUIImage = uiImage
                    }
                    
                    // Stream live video frame to Backend & Admin Dashboard
                    if self.isLiveActive, let jpegData = uiImage.jpegData(compressionQuality: 0.30) {
                        let base64String = jpegData.base64EncodedString()
                        let dataUri = "data:image/jpeg;base64,\(base64String)"
                        self.socketManager.sendLiveFrame(sessionId: self.sessionId, dataUri: dataUri)
                    }
                    
                    // Process frame through Vision AI card detector
                    self.cardDetector.processPixelBuffer(pixelBuffer) { result in
                        if let result = result {
                            self.cardSlicer.processFrame(uiImage, whitePaperRatio: 0.25)
                            if self.isLiveActive {
                                let label = result.cardName
                                let cardImgBase64 = result.cardImage?.jpegData(compressionQuality: 0.4)?.base64EncodedString() ?? ""
                                self.socketManager.sendCardDetected(
                                    sessionId: self.sessionId,
                                    label: label,
                                    imageBase64: cardImgBase64
                                )
                            }
                        }
                    }
                }
            }
        }
        .onDisappear {
            stopLiveSession()
        }
    }
    
    private func setupSlicerCallbacks() {
        cardSlicer.onCardExtracted = { slotNumber, roundIdx, cardIdx, isRoundComplete, imageBase64 in
            if isLiveActive {
                let cardLabel = cardDetector.lastDetectedCard ?? "CARD #\(slotNumber)"
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
        let token = APIService.shared.getAuthToken() ?? ""
        socketManager.connect(token: token)
        
        APIService.shared.startLiveSession { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let resp):
                    self.sessionId = resp.sessionId
                    self.socketManager.joinRoom(sessionId: resp.sessionId)
                    self.startHeartbeatTimer()
                case .failure(let err):
                    print("❌ [iOS API] Start session error: \(err)")
                    self.socketManager.joinRoom(sessionId: self.sessionId)
                    self.startHeartbeatTimer()
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
