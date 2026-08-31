//
//  VideoTestView.swift
//  CardLink
//
//  Offline Video Testing & Batch Card Extractor View.
//  Allows users to pick any pre-recorded 240 FPS / 60 FPS video clip from the iOS Photo Library,
//  scans every frame offline, draws green bounding boxes over cards, and lists detected cards grouped by player hands.
//

import SwiftUI
import PhotosUI
import AVFoundation

struct DealtCardItem: Identifiable {
    let id = UUID()
    let vanIndex: Int
    let handIndex: Int
    let cardIndex: Int
    let cardName: String
    let imageBase64: String
    let timestamp: Date
}

struct VideoTestView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var isProcessing = false
    @State private var progressText = "CHỌN VIDEO TỪ THƯ VIỆN ĐỂ TEST"
    @State private var progressRatio: Float = 0.0
    
    @State private var currentFrameImage: UIImage? = nil
    @State private var currentDetectionBox: CGRect? = nil
    @State private var currentCardLabel: String? = nil
    
    @State private var detectedCards: [DealtCardItem] = []
    @State private var totalHands: Int = 3
    @State private var isSendingToServer = false
    @State private var serverStatusText = ""
    
    private let cardDetector = CardDetector()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 16) {
                // Header Bar
                HStack {
                    Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Quay Lại")
                        }
                        .foregroundColor(.yellow)
                        .font(.system(size: 14, weight: .bold))
                    }
                    Spacer()
                    Text("🧪 TEST VIDEO THỰC TẾ")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Spacer().frame(width: 60)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                
                // Video Frame Viewfinder Preview with Bounding Box Overlay
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
                        .aspectRatio(16/9, contentMode: .fit)
                    
                    if let img = currentFrameImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(12)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 44))
                                .foregroundColor(.gray)
                            Text("Chưa chọn video")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // Bounding Box Overlay
                    if let box = currentDetectionBox {
                        GeometryReader { geo in
                            let w = box.width * geo.size.width
                            let h = box.height * geo.size.height
                            let x = box.origin.x * geo.size.width
                            let y = box.origin.y * geo.size.height
                            
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.green, lineWidth: 3)
                                    .shadow(color: .green.opacity(0.9), radius: 5)
                                    .frame(width: w, height: h)
                                
                                Text(currentCardLabel ?? "LÁ BÀI")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green))
                                    .offset(x: 2, y: -20)
                            }
                            .offset(x: x, y: y)
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                // Progress Bar
                if isProcessing {
                    VStack(spacing: 6) {
                        ProgressView(value: progressRatio)
                            .progressViewStyle(LinearProgressViewStyle(tint: .yellow))
                            .padding(.horizontal, 16)
                        Text(progressText)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                }
                
                // Controls Bar (Picker & Start Test)
                HStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("CHỌN VIDEO TỪ THƯ VIỆN")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.yellow))
                        .shadow(color: .yellow.opacity(0.4), radius: 6)
                    }
                    .onChange(of: selectedItem) { newItem in
                        Task {
                            if let item = newItem, let movie = try? await item.loadTransferable(type: MovieFile.self) {
                                processSelectedVideo(url: movie.url)
                            }
                        }
                    }
                    
                    if !detectedCards.isEmpty {
                        Button(action: sendResultsToServer) {
                            HStack(spacing: 6) {
                                Image(systemName: "paperplane.fill")
                                Text("GỬI NGUYÊN BẢN LÊN SERVER")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.green))
                            .shadow(color: .green.opacity(0.5), radius: 6)
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                if !serverStatusText.isEmpty {
                    Text(serverStatusText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                }
                
                // List of Extracted Cards Grouped by Player Hands (Tụ 1, Tụ 2, Tụ 3)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("🎴 DANH SÁCH LÁ BÀI VÀ TỤ TRÍCH XUẤT (\(detectedCards.count) LÁ)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    
                    ScrollView {
                        VStack(spacing: 8) {
                            if detectedCards.isEmpty {
                                Text("Chưa có lá bài nào được trích xuất. Hãy chọn video để quét!")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .padding(.top, 20)
                            } else {
                                ForEach(groupedCardsByHand.keys.sorted(), id: \.self) { handKey in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(handKey)
                                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                                            .foregroundColor(.cyan)
                                        
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 10) {
                                                ForEach(groupedCardsByHand[handKey] ?? []) { item in
                                                    VStack(spacing: 4) {
                                                        if let imgData = Data(base64Encoded: item.imageBase64),
                                                           let uiImg = UIImage(data: imgData) {
                                                            Image(uiImage: uiImg)
                                                                .resizable()
                                                                .scaledToFill()
                                                                .frame(width: 54, height: 80)
                                                                .cornerRadius(6)
                                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green, lineWidth: 1.5))
                                                        }
                                                        
                                                        Text(item.cardName)
                                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                            .foregroundColor(.yellow)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
    
    // Group detected cards by Player Hand (e.g. "🖐️ TỤ #1", "🖐️ TỤ #2", "🖐️ TỤ #3")
    private var groupedCardsByHand: [String: [DealtCardItem]] {
        Dictionary(grouping: detectedCards) { item in
            "🖐️ TỤ #\(item.handIndex) (VÁN #\(item.vanIndex))"
        }
    }
    
    // Offline Video Frame Extraction Pipeline using AVAssetReader
    private func processSelectedVideo(url: URL) {
        isProcessing = true
        progressRatio = 0.0
        progressText = "ĐANG ĐỌC TỆP VIDEO SLOW-MOTION..."
        detectedCards.removeAll()
        
        let asset = AVAsset(url: url)
        Task.detached(priority: .userInitiated) {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.progressText = "❌ KHÔNG ĐỌC ĐƯỢC LUỒNG VIDEO"
                }
                return
            }
            
            guard let reader = try? AVAssetReader(asset: asset) else { return }
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(trackOutput)
            reader.startReading()
            
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let videoCGOrientation = self.cgOrientationFromTransform(transform)
            
            let slicer = CardSlowMoSlicer(totalHands: self.totalHands)
            slicer.onCardExtracted = { totalSlot, vanIdx, handIdx, cardIdx, isRoundComplete, imageBase64, cardName in
                let newItem = DealtCardItem(
                    vanIndex: vanIdx,
                    handIndex: handIdx,
                    cardIndex: cardIdx,
                    cardName: cardName,
                    imageBase64: imageBase64,
                    timestamp: Date()
                )
                DispatchQueue.main.async {
                    self.detectedCards.append(newItem)
                }
            }
            
            var frameIndex = 0
            let durationSeconds = (try? await asset.load(.duration))?.seconds ?? 1.0
            let fps: Double = 60.0
            let estimatedTotalFrames = max(1.0, durationSeconds * fps)
            
            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                frameIndex += 1
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                
                // Sample 1 frame every 2 frames for fast offline processing
                if frameIndex % 2 == 0 {
                    let currentRatio = Float(Double(frameIndex) / estimatedTotalFrames)
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let ptsSeconds = pts.isValid ? CMTimeGetSeconds(pts) : Double(frameIndex) / 60.0
                    
                    self.cardDetector.processPixelBuffer(pixelBuffer, orientation: videoCGOrientation) { result in
                        slicer.processDetectionResult(result, timestamp: ptsSeconds)
                        
                        let uiImg = self.pixelBufferToUIImage(pixelBuffer, orientation: videoCGOrientation)
                        DispatchQueue.main.async {
                            self.progressRatio = min(1.0, currentRatio)
                            self.progressText = "ĐANG PHÂN TÍCH FRAME #\(frameIndex) (\(Int(min(1.0, currentRatio) * 100))%)..."
                            if let img = uiImg {
                                self.currentFrameImage = img
                            }
                            self.currentDetectionBox = result?.boundingBox
                            self.currentCardLabel = result?.cardName
                        }
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isProcessing = false
                self.progressRatio = 1.0
                self.progressText = "✅ PHÂN TÍCH HOÀN TẤT! TÌM THẤY \(self.detectedCards.count) LÁ BÀI."
            }
        }
    }
    
    private func cgOrientationFromTransform(_ transform: CGAffineTransform) -> CGImagePropertyOrientation {
        if transform.a == 0 && transform.b == 1.0 && transform.c == -1.0 && transform.d == 0 {
            return .right
        } else if transform.a == 0 && transform.b == -1.0 && transform.c == 1.0 && transform.d == 0 {
            return .left
        } else if transform.a == 1.0 && transform.b == 0 && transform.c == 0 && transform.d == 1.0 {
            return .up
        } else if transform.a == -1.0 && transform.b == 0 && transform.c == 0 && transform.d == -1.0 {
            return .down
        } else {
            return .right
        }
    }
    
    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    private func sendResultsToServer() {
        isSendingToServer = true
        serverStatusText = "Đang gửi \(detectedCards.count) lá bài về Server..."
        
        let sessionId = "LIVE_TEST_\(Int(Date().timeIntervalSince1970))"
        for item in detectedCards {
            let label = "\(item.cardName) (VÁN #\(item.vanIndex) | TỤ #\(item.handIndex) - LÁ #\(item.cardIndex))"
            iOSSocketManager.shared.sendCardDetected(
                sessionId: sessionId,
                label: label,
                imageBase64: item.imageBase64
            )
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isSendingToServer = false
            self.serverStatusText = "✅ ĐÃ GỬI THÀNH CÔNG \(self.detectedCards.count) LÁ BÀI VỀ SERVER!"
        }
    }
}

// Transferable wrapper for PhotosPicker Movie files
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}
