//
//  CardSlowMoSlicer.swift
//  CardLink
//
//  Real-Life Dealing State Machine & 240 FPS Motion Slicer.
//  Tracks Hand/Player index (Tụ 1..N), Card index (Lá 1..3), Game Round (Ván #1, #2...),
//  and detects exact deal motion flick + static settlement to extract the #1 sharpest frame!
//

import Foundation
import UIKit
import CoreGraphics

final class CardSlowMoSlicer: ObservableObject {
    
    @Published var gameRoundNumber: Int = 1       // Ván bài #1, #2...
    @Published var currentHandIndex: Int = 1       // Tụ #1..N
    @Published var currentCardIndex: Int = 1       // Lá #1..3
    @Published var totalHands: Int = 3             // Tổng số tụ (Ví dụ: 3 Tụ)
    @Published var totalDealtCardsInRound: Int = 0  // Số lá đã chia trong ván hiện tại (0..9)
    @Published var totalDealtCardsGlobal: Int = 0   // Tổng số lá chia tất cả ván
    @Published var lastExtractedSharpness: Float = 0.0
    @Published var isRoundJustCompleted: Bool = false
    @Published var statusBannerText: String = "🎴 ĐANG CHIA: TỤ 1 - LÁ 1 (VÁN #1)"
    
    // State Machine
    private var isCardActive: Bool = false
    private var consecutiveFrameCount: Int = 0
    private var absentFrameCount: Int = 0
    private var lastSeenTime: Date = Date()
    private var lastEmitTime: Date = Date.distantPast
    private var activeFrames: [UIImage] = []
    
    var onCardExtracted: ((Int, Int, Int, Int, Bool, String) -> Void)?
    
    init(totalHands: Int = 3, onCardExtracted: ((Int, Int, Int, Int, Bool, String) -> Void)? = nil) {
        self.totalHands = totalHands
        self.onCardExtracted = onCardExtracted
        updateStatusBanner()
    }
    
    convenience init(totalRounds: Int, onCardExtracted: ((Int, Int, Int, Int, Bool, String) -> Void)? = nil) {
        self.init(totalHands: totalRounds, onCardExtracted: onCardExtracted)
    }
    
    /// Reset counter & state machine for new game
    func reset() {
        gameRoundNumber = 1
        currentHandIndex = 1
        currentCardIndex = 1
        totalDealtCardsInRound = 0
        totalDealtCardsGlobal = 0
        isCardActive = false
        isRoundJustCompleted = false
        consecutiveFrameCount = 0
        absentFrameCount = 0
        activeFrames.removeAll()
        lastEmitTime = Date.distantPast
        updateStatusBanner()
    }
    
    /// Updates status banner description
    private func updateStatusBanner() {
        let maxCardsInRound = totalHands * 3
        if isRoundJustCompleted {
            statusBannerText = "🏆 KẾT THÚC VÁN #\(gameRoundNumber) (\(maxCardsInRound)/\(maxCardsInRound) LÁ) -> CHUẨN BỊ VÁN MỚI"
        } else {
            statusBannerText = "🎴 VÁN #\(gameRoundNumber) | TỤ #\(currentHandIndex)/\(totalHands) - LÁ #\(currentCardIndex)/3 (LÁ BÀI SỐ \(totalDealtCardsInRound + 1)/\(maxCardsInRound))"
        }
    }
    
    /// Processes incoming 240 FPS frame with white card ratio and confidence
    func processFrame(_ image: UIImage, whitePaperRatio: Float, confidence: Float = 0.80) {
        let now = Date()
        let isValidCardPresence = whitePaperRatio >= 0.08 || confidence >= 0.50
        
        if isValidCardPresence {
            consecutiveFrameCount += 1
            absentFrameCount = 0
            lastSeenTime = now
            activeFrames.append(image)
            
            if activeFrames.count > 30 {
                activeFrames.removeFirst()
            }
            
            // Requires 3 consecutive frames (~12ms) to confirm deal motion
            if consecutiveFrameCount >= 3 {
                isCardActive = true
            }
        } else {
            consecutiveFrameCount = 0
            if isCardActive {
                absentFrameCount += 1
                
                // Requires 4 consecutive absent frames (~16ms departure) to finalize card deal
                if absentFrameCount >= 4 {
                    isCardActive = false
                    absentFrameCount = 0
                    
                    // Cooldown check: At least 0.4 seconds (400ms) between deal emissions
                    if now.timeIntervalSince(lastEmitTime) >= 0.4 {
                        lastEmitTime = now
                        if !activeFrames.isEmpty {
                            let sharpestImage = findSharpestFrame(in: activeFrames) ?? image
                            extractAndEmitCard(sharpestImage)
                            activeFrames.removeAll()
                        }
                    } else {
                        activeFrames.removeAll()
                    }
                }
            } else {
                absentFrameCount = 0
                if now.timeIntervalSince(lastSeenTime) > 1.5 {
                    activeFrames.removeAll()
                }
            }
        }
    }
    
    /// Manual capture trigger button
    func manualCapture(_ image: UIImage) {
        extractAndEmitCard(image)
    }
    
    /// Finds the #1 sharpest image using Laplacian Variance edge sharpness evaluation
    private func findSharpestFrame(in frames: [UIImage]) -> UIImage? {
        guard !frames.isEmpty else { return nil }
        var maxSharpness: Float = -1.0
        var bestFrame: UIImage = frames.last!
        
        for frame in frames {
            let sharpness = computeLaplacianSharpness(frame)
            if sharpness > maxSharpness {
                maxSharpness = sharpness
                bestFrame = frame
            }
        }
        
        DispatchQueue.main.async {
            self.lastExtractedSharpness = maxSharpness
        }
        return bestFrame
    }
    
    /// Calculates Laplacian Variance sharpness score on image
    private func computeLaplacianSharpness(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.0 }
        let width = 64
        let height = 64
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawData = [UInt8](repeating: 0, count: width * height)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0.0 }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var laplacianSum: Double = 0.0
        var pixelCount = 0
        
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(rawData[y * width + x])
                let up     = Double(rawData[(y - 1) * width + x])
                let down   = Double(rawData[(y + 1) * width + x])
                let left   = Double(rawData[y * width + (x - 1)])
                let right  = Double(rawData[y * width + (x + 1)])
                
                let lap = abs(4 * center - up - down - left - right)
                laplacianSum += lap
                pixelCount += 1
            }
        }
        
        return pixelCount > 0 ? Float(laplacianSum / Double(pixelCount)) : 0.0
    }
    
    private func extractAndEmitCard(_ sharpestImage: UIImage) {
        let maxHands = totalHands > 0 ? totalHands : 3
        let currentHand = currentHandIndex
        let currentCard = currentCardIndex
        let currentVan = gameRoundNumber
        
        totalDealtCardsGlobal += 1
        totalDealtCardsInRound += 1
        
        let maxCardsInRound = maxHands * 3
        let isRoundComplete = (totalDealtCardsInRound >= maxCardsInRound)
        
        // Auto-advance hand & card dealing turn:
        // Round-Robin dealing: Tụ 1 -> Tụ 2 -> Tụ 3 for Card 1, then Tụ 1 -> Tụ 2 -> Tụ 3 for Card 2, etc.
        if currentHand < maxHands {
            currentHandIndex += 1
        } else {
            currentHandIndex = 1
            if currentCardIndex < 3 {
                currentCardIndex += 1
            } else {
                // Round Complete! Reset for next game round
                currentCardIndex = 1
                isRoundJustCompleted = true
                gameRoundNumber += 1
                totalDealtCardsInRound = 0
            }
        }
        
        if !isRoundComplete {
            isRoundJustCompleted = false
        }
        
        DispatchQueue.main.async {
            self.updateStatusBanner()
        }
        
        guard let jpegData = sharpestImage.jpegData(compressionQuality: 0.50) else { return }
        let imageBase64 = jpegData.base64EncodedString()
        
        onCardExtracted?(totalDealtCardsGlobal, currentVan, currentHand, currentCard, isRoundComplete, imageBase64)
        print("🃟 [iOS 240FPS Slicer] Emitted dealt card #\(totalDealtCardsGlobal) (Ván #\(currentVan), Tụ \(currentHand)/\(maxHands), Lá \(currentCard)/3)")
    }
}
