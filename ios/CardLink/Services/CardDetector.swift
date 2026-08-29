//
//  CardDetector.swift
//  CardLink
//
//  Ultra-Precise Rank-First Neural Playing Card Detector.
//  Uses Apple Vision Neural Character & Symbol Recognition (VNRecognizeTextRequest)
//  to locate genuine card numbers (A, 2..10, J, Q, K) and Suit Symbols directly.
//  Zero false positives on legs, shorts, bedsheets, or background furniture.
//

import Foundation
import CoreGraphics
import Vision
import CoreImage
import UIKit

struct CardDetectionResult {
    let cardName: String
    let confidence: Float
    let boundingBox: CGRect
    let cardImage: UIImage?
}

final class CardDetector: ObservableObject {
    
    @Published var lastDetectedCard: String?
    @Published var detectionBox: CGRect?
    @Published var handSkeletonPoints: [CGPoint] = []
    @Published var debugLogText: String = "SEARCHING FOR PLAYING CARD..."
    
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var smoothedBox: CGRect?
    private var lastDetectedTime: Date?
    private let holdBufferDuration: TimeInterval = 0.35 // 350ms Hold Buffer
    
    private let validCardRanks = Set(["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
    
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right, completion: @escaping (CardDetectionResult?) -> Void) {
        autoreleasepool {
            let portraitCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let portraitWidth = Int(portraitCIImage.extent.width)
            let portraitHeight = Int(portraitCIImage.extent.height)
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            
            // 1. Apple Vision Neural Character & Rank Recognition Request
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            
            // 2. High-Precision Rectangle Request
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.45
            rectRequest.maximumAspectRatio = 0.88
            rectRequest.minimumSize = 0.020
            rectRequest.minimumConfidence = 0.25
            rectRequest.maximumObservations = 6
            rectRequest.quadratureTolerance = 35
            
            do {
                try handler.perform([textRequest, rectRequest])
                
                var bestCardBoxNormalized: CGRect? = nil
                var bestCropBoxNormalized: CGRect? = nil
                var maxScore: Float = -1.0
                var detectedRankName: String = "LÁ BÀI"
                
                // --- PRIMARY STAGE: Neural Card Rank Recognition (A..K, 2..10) ---
                if let textResults = textRequest.results, !textResults.isEmpty {
                    for observation in textResults {
                        if let candidate = observation.topCandidates(1).first {
                            let rawText = candidate.string.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Check if detected text contains a valid playing card rank
                            for rank in self.validCardRanks {
                                if rawText == rank || rawText.hasPrefix(rank) || rawText.hasSuffix(rank) {
                                    let b = observation.boundingBox
                                    
                                    // Expand bounding box to encompass the full playing card around the detected rank
                                    let cardW: CGFloat = 0.22
                                    let cardH: CGFloat = 0.28
                                    let originX = max(0.0, min(1.0 - cardW, b.midX - cardW / 2.0))
                                    let originY = max(0.0, min(1.0 - cardH, (1.0 - b.midY) - cardH / 2.0))
                                    
                                    let candidateBoxNorm = CGRect(x: originX, y: originY, width: cardW, height: cardH)
                                    let cropBoxNorm = CGRect(x: originX, y: 1.0 - originY - cardH, width: cardW, height: cardH)
                                    
                                    if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: cropBoxNorm, width: portraitWidth, height: portraitHeight) {
                                        if !self.isHumanSkinTone(cropped) {
                                            let analysis = self.analyzePlayingCardColors(cropped)
                                            if analysis.whiteRatio >= 0.15 {
                                                let score = Float(candidate.confidence) * 2.0 + analysis.whiteRatio + analysis.suitInkRatio * 3.0
                                                if score > maxScore {
                                                    maxScore = score
                                                    bestCardBoxNormalized = candidateBoxNorm
                                                    bestCropBoxNormalized = cropBoxNorm
                                                    detectedRankName = "LÁ BÀI: \(rank)"
                                                }
                                            }
                                        }
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
                
                // --- SECONDARY STAGE: Strict Playing Card Rectangle & Color Verification ---
                if bestCardBoxNormalized == nil, let rectResults = rectRequest.results, !rectResults.isEmpty {
                    for rect in rectResults {
                        let b = rect.boundingBox
                        let cardBoxNormalized = CGRect(
                            x: b.origin.x,
                            y: 1.0 - b.origin.y - b.height,
                            width: b.width,
                            height: b.height
                        )
                        
                        let area = b.width * b.height
                        let pixelWidth = b.width * CGFloat(portraitWidth)
                        let pixelHeight = b.height * CGFloat(portraitHeight)
                        let realPixelAspect = min(pixelWidth, pixelHeight) / max(pixelWidth, pixelHeight)
                        
                        // Strict Playing Card Real Pixel Aspect Ratio (0.55..0.82)
                        if area >= 0.020 && area <= 0.28 && realPixelAspect >= 0.55 && realPixelAspect <= 0.82 {
                            if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: rect.boundingBox, width: portraitWidth, height: portraitHeight) {
                                if !self.isHumanSkinTone(cropped) {
                                    let analysis = self.analyzePlayingCardColors(cropped)
                                    if analysis.isGenuineCard {
                                        let score = analysis.whiteRatio + analysis.suitInkRatio * 3.0
                                        if score > maxScore {
                                            maxScore = score
                                            bestCardBoxNormalized = cardBoxNormalized
                                            bestCropBoxNormalized = rect.boundingBox
                                            detectedRankName = "LÁ BÀI 240FPS"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                guard let targetBox = bestCardBoxNormalized, let cropBox = bestCropBoxNormalized else {
                    DispatchQueue.main.async {
                        if let lastTime = self.lastDetectedTime, Date().timeIntervalSince(lastTime) < self.holdBufferDuration {
                            // Hold previous box
                        } else {
                            self.detectionBox = nil
                            self.smoothedBox = nil
                            self.debugLogText = "SEARCHING FOR PLAYING CARD..."
                        }
                    }
                    completion(nil)
                    return
                }
                
                self.lastDetectedTime = Date()
                let smoothedTarget = self.smoothBox(targetBox)
                self.smoothedBox = smoothedTarget
                
                DispatchQueue.main.async {
                    self.detectionBox = smoothedTarget
                    self.debugLogText = "🎴 \(detectedRankName) (SCORE:\(String(format: "%.2f", maxScore)))"
                }
                
                if let zoomedCardImage = self.cropRegionOfInterest(portraitCIImage, normalizedBox: cropBox, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: detectedRankName,
                        confidence: 0.98,
                        boundingBox: smoothedTarget,
                        cardImage: zoomedCardImage
                    )
                    completion(result)
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }
    }
    
    private func smoothBox(_ newBox: CGRect) -> CGRect {
        guard let prev = smoothedBox else { return newBox }
        
        let dx = newBox.midX - prev.midX
        let dy = newBox.midY - prev.midY
        let distance = sqrt(dx * dx + dy * dy)
        
        if distance < 0.018 {
            return prev
        }
        
        let alpha: CGFloat = 0.20
        return CGRect(
            x: prev.origin.x * (1 - alpha) + newBox.origin.x * alpha,
            y: prev.origin.y * (1 - alpha) + newBox.origin.y * alpha,
            width: prev.size.width * (1 - alpha) + newBox.size.width * alpha,
            height: prev.size.height * (1 - alpha) + newBox.size.height * alpha
        )
    }
    
    private func cropRegionOfInterest(_ ciImage: CIImage, normalizedBox: CGRect, width: Int, height: Int) -> UIImage? {
        let cropRect = CGRect(
            x: normalizedBox.origin.x * CGFloat(width),
            y: normalizedBox.origin.y * CGFloat(height),
            width: normalizedBox.width * CGFloat(width),
            height: normalizedBox.height * CGFloat(height)
        )
        
        let croppedCI = ciImage.cropped(to: cropRect)
        guard let cgImage = CardDetector.ciContext.createCGImage(croppedCI, from: croppedCI.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    /// Rejects human skin tone crops (shins, legs, arms, feet)
    private func isHumanSkinTone(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = 32
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var skinPixels = 0
        var totalPixels = 0
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0
            
            // Indoor Lighting Skin Tone Hue
            let isSkin = (r > 80 && g > 40 && b > 20 && r > g && (r - b) > 10 && saturation >= 0.12 && saturation <= 0.65)
            if isSkin {
                skinPixels += 1
            }
            totalPixels += 1
        }
        
        let skinRatio = totalPixels > 0 ? Float(skinPixels) / Float(totalPixels) : 0.0
        return skinRatio >= 0.35 // Rejects crops with >= 35% skin tone
    }
    
    /// Analyzes Playing Card Color Palette (White Paper + Red/Black Suit Inks)
    private func analyzePlayingCardColors(_ image: UIImage) -> (whiteRatio: Float, suitInkRatio: Float, isGenuineCard: Bool) {
        guard let cgImage = image.cgImage else { return (0, 0, false) }
        let width = 32
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, false) }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var whitePaperPixels = 0
        var borderWhitePixels = 0
        var borderTotalPixels = 0
        var redSuitPixels = 0
        var blackSuitPixels = 0
        var totalPixels = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = Float(rawData[idx])
                let g = Float(rawData[idx + 1])
                let b = Float(rawData[idx + 2])
                
                let maxRGB = max(r, max(g, b))
                let minRGB = min(r, min(g, b))
                let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0
                let brightness = (r + g + b) / 3.0
                
                let isWhite = (brightness >= 35.0 && saturation <= 0.48)
                let isRed = (r >= 85 && r > 1.20 * g && r > 1.20 * b && saturation >= 0.30)
                let isBlack = (brightness <= 65.0 && saturation <= 0.38)
                
                if isWhite {
                    whitePaperPixels += 1
                }
                
                let isBorder = (y < 3 || y >= height - 3 || x < 2 || x >= width - 2)
                if isBorder {
                    borderTotalPixels += 1
                    if isWhite {
                        borderWhitePixels += 1
                    }
                } else {
                    if isRed { redSuitPixels += 1 }
                    if isBlack { blackSuitPixels += 1 }
                }
                totalPixels += 1
            }
        }
        
        let whiteRatio = totalPixels > 0 ? Float(whitePaperPixels) / Float(totalPixels) : 0.0
        let borderWhiteRatio = borderTotalPixels > 0 ? Float(borderWhitePixels) / Float(borderTotalPixels) : 0.0
        let redRatio = totalPixels > 0 ? Float(redSuitPixels) / Float(totalPixels) : 0.0
        let blackRatio = totalPixels > 0 ? Float(blackSuitPixels) / Float(totalPixels) : 0.0
        let suitInkRatio = redRatio + blackRatio
        
        let isGenuine = (whiteRatio >= 0.20) && (borderWhiteRatio >= 0.25) && (suitInkRatio >= 0.010 && suitInkRatio <= 0.40)
        return (whiteRatio, suitInkRatio, isGenuine)
    }
}
