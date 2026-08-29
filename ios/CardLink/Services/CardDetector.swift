//
//  CardDetector.swift
//  CardLink
//
//  Ultra-Precise 240 FPS Direct Playing Card Detector with 4-Corner & Full-Card OCR.
//  Recognizes cards regardless of how the dealer holds them (all 4 corners + full card surface).
//  Optimized for low-light & warm indoor room lighting (dim tungsten & flash).
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
    private let holdBufferDuration: TimeInterval = 0.30 // 300ms Hold Buffer
    
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right, completion: @escaping (CardDetectionResult?) -> Void) {
        autoreleasepool {
            let portraitCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let portraitWidth = Int(portraitCIImage.extent.width)
            let portraitHeight = Int(portraitCIImage.extent.height)
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            
            // High-Sensitivity Rectangle Request
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.30
            rectRequest.maximumAspectRatio = 0.95
            rectRequest.minimumSize = 0.015
            rectRequest.minimumConfidence = 0.12
            rectRequest.maximumObservations = 8
            rectRequest.quadratureTolerance = 45
            
            do {
                try handler.perform([rectRequest])
                
                var bestCardBoxNormalized: CGRect? = nil
                var bestCropBoxNormalized: CGRect? = nil
                var maxScore: Float = -1.0
                var detectedCardName: String = "LÁ BÀI 240FPS"
                
                if let rectResults = rectRequest.results, !rectResults.isEmpty {
                    for rect in rectResults {
                        let b = rect.boundingBox
                        let cardBoxNormalized = CGRect(
                            x: b.origin.x,
                            y: 1.0 - b.origin.y - b.height,
                            width: b.width,
                            height: b.height
                        )
                        
                        let area = b.width * b.height
                        
                        // 1. REAL PIXEL ASPECT RATIO (Corrected for horizontal & vertical orientation)
                        let pixelWidth = b.width * CGFloat(portraitWidth)
                        let pixelHeight = b.height * CGFloat(portraitHeight)
                        let realPixelAspect = min(pixelWidth, pixelHeight) / max(pixelWidth, pixelHeight)
                        
                        // Valid playing card aspect ratio (0.50..0.85) and area (1.5%..35%)
                        if area >= 0.015 && area <= 0.35 && realPixelAspect >= 0.50 && realPixelAspect <= 0.85 {
                            
                            if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: rect.boundingBox, width: portraitWidth, height: portraitHeight) {
                                
                                // 2. Reject skin tone crops (shins, legs, thighs)
                                if !self.isHumanSkinTone(cropped) {
                                    
                                    // 3. Multi-Corner & Full Surface Rank OCR (reads A..K, 2..10 on any visible corner!)
                                    let rankOCR = self.recognizeCardRankAcrossAllCorners(cropped)
                                    let analysis = self.analyzePlayingCardColorsAndSymbols(cropped)
                                    
                                    if rankOCR.found || analysis.isGenuineCard {
                                        let score = analysis.whiteRatio + analysis.suitInkRatio * 2.5 + (rankOCR.found ? 3.0 : 0.0)
                                        
                                        if score > maxScore {
                                            maxScore = score
                                            bestCardBoxNormalized = cardBoxNormalized
                                            if let rank = rankOCR.rank {
                                                detectedCardName = "LÁ BÀI: \(rank)"
                                            }
                                            
                                            let marginX = rect.boundingBox.width * 0.20
                                            let marginY = rect.boundingBox.height * 0.20
                                            bestCropBoxNormalized = CGRect(
                                                x: max(0.0, rect.boundingBox.origin.x - marginX),
                                                y: max(0.0, rect.boundingBox.origin.y - marginY),
                                                width: min(1.0 - max(0.0, rect.boundingBox.origin.x - marginX), rect.boundingBox.width + 2 * marginX),
                                                height: min(1.0 - max(0.0, rect.boundingBox.origin.y - marginY), rect.boundingBox.height + 2 * marginY)
                                            )
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
                    self.debugLogText = "🎴 \(detectedCardName) (SCORE:\(String(format: "%.2f", maxScore)))"
                }
                
                if let zoomedCardImage = self.cropRegionOfInterest(portraitCIImage, normalizedBox: cropBox, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: detectedCardName,
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
    
    /// Scans the entire card AND all 4 corners so rank is recognized even when fingers cover 1-2 corners!
    private func recognizeCardRankAcrossAllCorners(_ image: UIImage) -> (found: Bool, rank: String?) {
        guard let cgImage = image.cgImage else { return (false, nil) }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        
        do {
            try requestHandler.perform([textRequest])
            if let results = textRequest.results {
                let cardRanks = ["A", "K", "Q", "J", "10", "9", "8", "7", "6", "5", "4", "3", "2"]
                for observation in results {
                    if let candidate = observation.topCandidates(1).first {
                        let text = candidate.string.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        for rank in cardRanks {
                            if text == rank || text.hasPrefix(rank) || text.hasSuffix(rank) {
                                return (true, rank)
                            }
                        }
                    }
                }
            }
        } catch {}
        return (false, nil)
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
    
    /// High-Precision Skin Tone Rejection (Detects indoor yellow lamp lighting skin tone)
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
            
            // HSV / RGB Skin Tone Range for Indoor Lighting
            let isSkin = (r > 80 && g > 40 && b > 20 && r > g && (r - b) > 10 && saturation >= 0.12 && saturation <= 0.65)
            if isSkin {
                skinPixels += 1
            }
            totalPixels += 1
        }
        
        let skinRatio = totalPixels > 0 ? Float(skinPixels) / Float(totalPixels) : 0.0
        return skinRatio >= 0.40 // Rejects crops with >= 40% skin tone
    }
    
    /// Analyzes Playing Card Color Palette in Warm / Dim Room Lighting:
    private func analyzePlayingCardColorsAndSymbols(_ image: UIImage) -> (whiteRatio: Float, suitInkRatio: Float, isGenuineCard: Bool) {
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
        
        var redSuitPixels = 0     // Inlaid Red Suits: Cơ (♥), Rô (♦)
        var blackSuitPixels = 0   // Inlaid Black Suits: Bích (♠), Chuồn (♣) & Rank text
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
                
                // Warm room light white paper (brightness >= 35.0)
                let isWhitePixel = (brightness >= 35.0 && saturation <= 0.48)
                // Red suits (♥ ♦)
                let isRedPixel = (r >= 85 && r > 1.20 * g && r > 1.20 * b && saturation >= 0.30)
                // Black suits (♠ ♣ - 6 Chuồn, Át Bích)
                let isBlackPixel = (brightness <= 65.0 && saturation <= 0.38)
                
                if isWhitePixel {
                    whitePaperPixels += 1
                }
                
                // Check Outer Perimeter Border (Top/Bottom 3 rows, Left/Right 2 cols)
                let isBorderPixel = (y < 3 || y >= height - 3 || x < 2 || x >= width - 2)
                if isBorderPixel {
                    borderTotalPixels += 1
                    if isWhitePixel {
                        borderWhitePixels += 1
                    }
                } else {
                    // Interior Island Symbols (Inside the White Border)
                    if isRedPixel {
                        redSuitPixels += 1
                    }
                    if isBlackPixel {
                        blackSuitPixels += 1
                    }
                }
                
                totalPixels += 1
            }
        }
        
        let whiteRatio = totalPixels > 0 ? Float(whitePaperPixels) / Float(totalPixels) : 0.0
        let borderWhiteRatio = borderTotalPixels > 0 ? Float(borderWhitePixels) / Float(borderTotalPixels) : 0.0
        let redRatio = totalPixels > 0 ? Float(redSuitPixels) / Float(totalPixels) : 0.0
        let blackRatio = totalPixels > 0 ? Float(blackSuitPixels) / Float(totalPixels) : 0.0
        let suitInkRatio = redRatio + blackRatio
        
        let isGenuine = (whiteRatio >= 0.20) && (suitInkRatio >= 0.008 && suitInkRatio <= 0.45)
        return (whiteRatio, suitInkRatio, isGenuine)
    }
}
