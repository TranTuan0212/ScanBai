//
//  CardSlowMoSlicer.swift
//  CardLink
//
//  240 FPS High-Speed Ring Buffer & Sharpness-Based Slicer for iOS.
//  1. Accumulates 240 FPS high-speed motion frames.
//  2. Computes Laplacian Variance (Edge Sharpness) to select the #1 crispest frame.
//  3. Implements 3-Frame Flicker Filter & State Machine (NoCard <-> CardActive).
//  4. Manages Round-Robin N tụ x 3 cards auto-cycle counters.
//

import Foundation
import UIKit
import CoreGraphics

final class CardSlowMoSlicer: ObservableObject {
    
    @Published var currentRoundIndex: Int = 1
    @Published var currentCardIndex: Int = 1
    @Published var totalRounds: Int = 3
    @Published var totalDealtCards: Int = 0
    @Published var lastExtractedSharpness: Float = 0.0
    
    // State Machine
    private var isCardActive: Bool = false
    private var consecutiveFrameCount: Int = 0
    private var lastSeenTime: Date = Date()
    private var activeFrames: [UIImage] = []
    
    var onCardExtracted: ((Int, Int, Int, Bool, String) -> Void)?
    
    init(totalRounds: Int = 3, onCardExtracted: ((Int, Int, Int, Bool, String) -> Void)? = nil) {
        self.totalRounds = totalRounds
        self.onCardExtracted = onCardExtracted
    }
    
    /// Processes incoming 240 FPS frame with white card ratio and confidence
    func processFrame(_ image: UIImage, whitePaperRatio: Float, confidence: Float = 0.80) {
        let now = Date()
        let isValidCardPresence = whitePaperRatio >= 0.12 && confidence >= 0.75
        
        if isValidCardPresence {
            consecutiveFrameCount += 1
            lastSeenTime = now
            activeFrames.append(image)
            
            // Limit ring buffer to maximum 30 frames (at 240 FPS, 30 frames = 125ms motion slice)
            if activeFrames.count > 30 {
                activeFrames.removeFirst()
            }
            
            // 3-Frame Flicker Confirmation Gate
            if consecutiveFrameCount >= 3 {
                isCardActive = true
            }
        } else {
            // Check if card left frame and state was active
            if isCardActive {
                isCardActive = false
                consecutiveFrameCount = 0
                if !activeFrames.isEmpty {
                    let sharpestImage = findSharpestFrame(in: activeFrames) ?? image
                    extractAndEmitCard(sharpestImage)
                    activeFrames.removeAll()
                }
            } else {
                // Reset state machine if card absent for more than 1.5 seconds
                if now.timeIntervalSince(lastSeenTime) > 1.5 {
                    consecutiveFrameCount = 0
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
        print("🔍 [iOS 240FPS Slicer] Selected sharpest frame out of \(frames.count) frames (Sharpness Score: \(String(format: "%.1f", maxSharpness)))")
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
        
        // 3x3 Laplacian Filter Kernel: [0, 1, 0; 1, -4, 1; 0, 1, 0]
        var laplacianValues: [Float] = []
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Float(rawData[y * width + x])
                let top = Float(rawData[(y - 1) * width + x])
                let bottom = Float(rawData[(y + 1) * width + x])
                let left = Float(rawData[y * width + (x - 1)])
                let right = Float(rawData[y * width + (x + 1)])
                
                let lap = top + bottom + left + right - (4.0 * center)
                laplacianValues.append(lap)
            }
        }
        
        // Calculate Variance of Laplacian
        guard !laplacianValues.isEmpty else { return 0.0 }
        let mean = laplacianValues.reduce(0, +) / Float(laplacianValues.count)
        let variance = laplacianValues.reduce(0) { $0 + pow($1 - mean, 2) } / Float(laplacianValues.count)
        return variance
    }
    
    private func extractAndEmitCard(_ image: UIImage) {
        totalDealtCards += 1
        
        let slotNumber = totalDealtCards
        let roundIdx = currentRoundIndex
        let cardIdx = currentCardIndex
        let isRoundComplete = (cardIdx == 3)
        
        // Convert to JPEG Base64
        guard let jpegData = image.jpegData(compressionQuality: 0.65) else { return }
        let base64String = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        
        print("🎬 [iOS Slicer] Extracted Slot #\(slotNumber) (Tụ \(roundIdx) - Lá \(cardIdx))")
        onCardExtracted?(slotNumber, roundIdx, cardIdx, isRoundComplete, base64String)
        
        // Advance Round-Robin Counters
        if cardIdx >= 3 {
            currentCardIndex = 1
            if roundIdx >= totalRounds {
                currentRoundIndex = 1 // Auto-cycle rounds
            } else {
                currentRoundIndex += 1
            }
        } else {
            currentCardIndex += 1
        }
    }
    
    func reset() {
        currentRoundIndex = 1
        currentCardIndex = 1
        totalDealtCards = 0
        isCardActive = false
        consecutiveFrameCount = 0
        activeFrames.removeAll()
    }
}
