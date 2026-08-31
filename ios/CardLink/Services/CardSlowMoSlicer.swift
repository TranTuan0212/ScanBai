//
//  CardSlowMoSlicer.swift
//  CardLink
//
//  Ultra High-Speed 240 FPS Deal Slicer with Instant 1-Frame Dealing Trigger.
//  Captures fast card dealing swipes and fills each player's slot sequentially.
//

import Foundation
import UIKit
import CoreGraphics

final class CardSlowMoSlicer: ObservableObject {
    
    @Published var gameRoundNumber: Int = 1       // Ván bài #1, #2...
    @Published var currentHandIndex: Int = 1       // Tụ #1..N
    @Published var currentCardIndex: Int = 1       // Lá #1..3
    @Published var totalHands: Int = 3             // Tổng số tụ (Ví dụ: 3 Tụ)
    @Published var totalDealtCardsInRound: Int = 0  // Số lá đã chia trong ván hiện tại (0..9 hoặc 0..12)
    @Published var totalDealtCardsGlobal: Int = 0   // Tổng số lá chia tất cả ván
    @Published var isDealingActive: Bool = true    // Chế độ: TRUE = ĐANG CHIA BÀI | FALSE = ĐANG XỐC BÀI (KHÓA GỬI)
    @Published var isRoundJustCompleted: Bool = false
    @Published var statusBannerText: String = "🎴 CHUẨN BỊ CHIA: TỤ 1 - LÁ 1 (VÁN #1)"
    
    // State Machine & Ultra-Fast Timing
    private var isCardActive: Bool = false
    private var hasSentCurrentCardSlot: Bool = false
    private var lastEmittedSlotIndex: Int = -1
    private var consecutiveFrameCount: Int = 0
    private var absentFrameCount: Int = 0
    private var lastSeenTime: Date = Date()
    private var lastEmitTime: Date = Date.distantPast
    private var activeFrames: [UIImage] = []
    
    var onCardExtracted: ((Int, Int, Int, Int, Bool, String, String) -> Void)?
    
    init(totalHands: Int = 3, onCardExtracted: ((Int, Int, Int, Int, Bool, String, String) -> Void)? = nil) {
        self.totalHands = totalHands
        self.onCardExtracted = onCardExtracted
        updateStatusBanner()
    }
    
    convenience init(totalRounds: Int, onCardExtracted: ((Int, Int, Int, Int, Bool, String, String) -> Void)? = nil) {
        self.init(totalHands: totalRounds, onCardExtracted: onCardExtracted)
    }
    
    /// Toggle between Shuffling Mode (Xốc bài - Khóa) and Dealing Mode (Chia bài)
    func toggleDealingMode() {
        isDealingActive.toggle()
        updateStatusBanner()
    }
    
    /// Reset counter for a fresh game round
    func reset() {
        gameRoundNumber = 1
        currentHandIndex = 1
        currentCardIndex = 1
        totalDealtCardsInRound = 0
        totalDealtCardsGlobal = 0
        isCardActive = false
        hasSentCurrentCardSlot = false
        lastEmittedSlotIndex = -1
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
        if !isDealingActive {
            statusBannerText = "⏸️ ĐANG XỐC BÀI / SẤP BÀI (TẠM KHÓA GHI NHẬN)"
        } else if isRoundJustCompleted {
            statusBannerText = "🏆 HOÀN THÀNH VÁN #\(gameRoundNumber) (\(maxCardsInRound)/\(maxCardsInRound) LÁ) -> CHUẨN BỊ VÁN TIẾP"
        } else {
            statusBannerText = "🎴 ĐANG CHIA: TỤ #\(currentHandIndex)/\(totalHands) - LÁ #\(currentCardIndex)/3 (LÁ \(totalDealtCardsInRound + 1)/\(maxCardsInRound))"
        }
    }
    
    /// Processes incoming detection result with multi-frame track accumulation
    func processDetectionResult(_ result: CardDetectionResult?) {
        guard isDealingActive else { return }
        
        guard let detection = result, let image = detection.cardImage, detection.cardConfidence >= 0.70 else {
            processFrameNoCard()
            return
        }
        
        let now = Date()
        guard now.timeIntervalSince(lastEmitTime) >= 0.28 else { return }
        
        consecutiveFrameCount += 1
        absentFrameCount = 0
        lastSeenTime = now
        activeFrames.append(image)
        
        if activeFrames.count > 15 {
            activeFrames.removeFirst()
        }
        
        // Trigger slot emission when track is confirmed (>= 2 hits, good visibility or corner hit)
        if detection.isConfirmed || consecutiveFrameCount >= 2 {
            isCardActive = true
            
            if !hasSentCurrentCardSlot {
                let sharpestImage = image // CardDetector already stores and updates track.bestFrame!
                extractAndEmitCard(sharpestImage, customLabel: detection.cardName)
            }
        }
    }
    
    /// Processes incoming frame (legacy fallback)
    func processFrame(_ image: UIImage, whitePaperRatio: Float = 0.50, confidence: Float = 0.95) {
        guard isDealingActive else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastEmitTime) >= 0.28 else { return }
        
        consecutiveFrameCount += 1
        absentFrameCount = 0
        lastSeenTime = now
        activeFrames.append(image)
        
        if activeFrames.count > 15 {
            activeFrames.removeFirst()
        }
        
        if consecutiveFrameCount >= 2 {
            isCardActive = true
            
            if !hasSentCurrentCardSlot {
                if let sharpestImage = findSharpestFrame(in: activeFrames) ?? activeFrames.last {
                    extractAndEmitCard(sharpestImage)
                }
            }
        }
    }
    
    /// Called when no valid card is detected in frame
    func processFrameNoCard() {
        let now = Date()
        consecutiveFrameCount = 0
        if isCardActive {
            absentFrameCount += 1
            
            // Temporal & Spatial Tracker Tolerance:
            // Require 15 absent frames (~60ms at 240fps) AND at least 0.28s time gap before re-arming for the next card slot!
            // Prevents track breakage / duplicate card IDs when fingers temporarily occlude the card for a few frames.
            if absentFrameCount >= 15 && now.timeIntervalSince(lastSeenTime) >= 0.28 {
                isCardActive = false
                hasSentCurrentCardSlot = false // Re-arm for the genuine next card!
                absentFrameCount = 0
                activeFrames.removeAll()
            }
        } else {
            absentFrameCount = 0
            if now.timeIntervalSince(lastSeenTime) > 0.35 {
                hasSentCurrentCardSlot = false
                activeFrames.removeAll()
            }
        }
    }
    
    /// Manual capture trigger button ("BÓC BÀI THỦ CÔNG")
    func manualCapture(_ image: UIImage) {
        guard isDealingActive else {
            isDealingActive = true
            updateStatusBanner()
            extractAndEmitCard(image)
            return
        }
        extractAndEmitCard(image)
    }
    
    /// Finds the sharpest image using Laplacian Variance edge sharpness
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
        return bestFrame
    }
    
    /// Calculates Laplacian Variance sharpness score
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
    
    private func extractAndEmitCard(_ sharpestImage: UIImage, customLabel: String? = nil) {
        guard !hasSentCurrentCardSlot else { return }
        
        let maxHands = totalHands > 0 ? totalHands : 3
        let currentHand = currentHandIndex
        let currentCard = currentCardIndex
        let currentVan = gameRoundNumber
        
        totalDealtCardsGlobal += 1
        totalDealtCardsInRound += 1
        
        hasSentCurrentCardSlot = true
        lastEmittedSlotIndex = totalDealtCardsGlobal
        lastEmitTime = Date()
        
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
                currentCardIndex = 1
                isRoundJustCompleted = true
                gameRoundNumber += 1
                totalDealtCardsInRound = 0
            }
        }
        
        if !isRoundComplete {
            isRoundJustCompleted = false
        }
        
        let jpegData = sharpestImage.jpegData(compressionQuality: 0.65)
        let imageBase64 = jpegData?.base64EncodedString() ?? ""
        let cardName = customLabel ?? "LÁ BÀI"
        onCardExtracted?(totalDealtCardsGlobal, currentVan, currentHand, currentCard, isRoundComplete, imageBase64, cardName)
        print("🃟 [iOS Fast Slicer] Emitted \(cardName) (Ván #\(currentVan), Tụ \(currentHand)/\(maxHands), Lá \(currentCard)/3)")
    }
}
