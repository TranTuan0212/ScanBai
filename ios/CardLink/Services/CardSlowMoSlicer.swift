//
//  CardSlowMoSlicer.swift
//  CardLink
//
//  Real-Life Dealing State Machine with Shuffling/Squaring Isolation.
//  Distinguishes between Deck Shuffling / Squaring (Xốc Bài / Sấp Bài) and Active Dealing (Chia Bài).
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
    @Published var isDealingActive: Bool = true    // Chế độ: TRUE = ĐANG CHIA BÀI | FALSE = ĐANG XỐC BÀI (KHÓA GỬI)
    @Published var isRoundJustCompleted: Bool = false
    @Published var statusBannerText: String = "🎴 CHUẨN BỊ CHIA: TỤ 1 - LÁ 1 (VÁN #1)"
    
    // State Machine & Strict Timing Controls
    private var isCardActive: Bool = false
    private var hasSentCurrentCardSlot: Bool = false
    private var lastEmittedSlotIndex: Int = -1
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
    
    /// Processes incoming frame with cropped card surface
    func processFrame(_ image: UIImage, whitePaperRatio: Float = 0.50, confidence: Float = 0.98) {
        // STRICT RULE 1: If currently in Shuffling mode, IGNORE EVERYTHING!
        guard isDealingActive else { return }
        
        let now = Date()
        
        // STRICT RULE 2: Minimum 0.8 second interval between dealt cards in real life!
        guard now.timeIntervalSince(lastEmitTime) >= 0.80 else { return }
        
        consecutiveFrameCount += 1
        absentFrameCount = 0
        lastSeenTime = now
        activeFrames.append(image)
        
        if activeFrames.count > 30 {
            activeFrames.removeFirst()
        }
        
        // Require 3 consecutive valid frames (~25ms) to confirm genuine card presentation
        if consecutiveFrameCount >= 3 {
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
            
            // Require 8 consecutive absent frames (~35ms departure) to confirm card left frame
            if absentFrameCount >= 8 {
                isCardActive = false
                hasSentCurrentCardSlot = false // Open gate for next dealt card!
                absentFrameCount = 0
                activeFrames.removeAll()
            }
        } else {
            absentFrameCount = 0
            if now.timeIntervalSince(lastSeenTime) > 0.4 {
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
    
    private func extractAndEmitCard(_ sharpestImage: UIImage) {
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
        
        DispatchQueue.main.async {
            self.updateStatusBanner()
        }
        
        guard let jpegData = sharpestImage.jpegData(compressionQuality: 0.65) else { return }
        let imageBase64 = jpegData.base64EncodedString()
        
        onCardExtracted?(totalDealtCardsGlobal, currentVan, currentHand, currentCard, isRoundComplete, imageBase64)
        print("🃟 [iOS Deal Slicer] Emitted card #\(totalDealtCardsGlobal) (Ván #\(currentVan), Tụ \(currentHand)/\(maxHands), Lá \(currentCard)/3)")
    }
}
