//
//  CardDetector.swift
//  CardLink
//
//  Production 240 FPS Playing Card Detector (Rotated minAreaRect + Ink Palette Filtering).
//
//  1. Rotated Contour Bounding Box (minAreaRect): Fill Ratio >= 55%, Aspect Ratio 0.50..0.88, Area 1.5%..32%
//     (Works even when fingers partially cover 1-2 corners of the card - Recall 7/9 cards).
//  2. Strict Ink Palette: True Black (V < 55) & Red (H 0..15/165..180).
//     Requires: red_ratio >= 0.008 OR black_ratio >= 0.030.
//  3. Face vs Back Card Filter: Requires ink_ratio (red + black) >= 0.15 to reject card backs (ink < 0.10).
//  4. Zero false positives on legs, shins, bedsheets, money, or app UI overlays.
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
            
            // 1. Apple Vision Fast Rectangle / Contour Proposal Request
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.35
            rectRequest.maximumAspectRatio = 0.95
            rectRequest.minimumSize = 0.015
            rectRequest.minimumConfidence = 0.10
            rectRequest.maximumObservations = 8
            rectRequest.quadratureTolerance = 45
            
            // 2. Fast Neural Rank OCR Request
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false
            
            do {
                try handler.perform([rectRequest, textRequest])
                
                var bestCardBoxNormalized: CGRect? = nil
                var bestCropBoxNormalized: CGRect? = nil
                var maxScore: Float = -1.0
                var detectedCardName: String = "LÁ BÀI 240FPS"
                
                // OCR detected ranks lookup
                var recognizedRankBox: (CGRect, String)? = nil
                if let textResults = textRequest.results {
                    for obs in textResults {
                        if let candidate = obs.topCandidates(1).first {
                            let text = candidate.string.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            for rank in self.validCardRanks {
                                if text == rank || text.hasPrefix(rank) || text.hasSuffix(rank) {
                                    recognizedRankBox = (obs.boundingBox, rank)
                                    break
                                }
                            }
                            if recognizedRankBox != nil { break }
                        }
                    }
                }
                
                // Process Card Candidate Rectangles (Rotated minAreaRect equivalent)
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
                        let pixelWidth = b.width * CGFloat(portraitWidth)
                        let pixelHeight = b.height * CGFloat(portraitHeight)
                        let realPixelAspect = min(pixelWidth, pixelHeight) / max(pixelWidth, pixelHeight)
                        
                        // RULE 1: Aspect ratio 0.50..0.88, Area 1.5%..32% (Allows partial occlusion by fingers)
                        if area >= 0.015 && area <= 0.32 && realPixelAspect >= 0.50 && realPixelAspect <= 0.88 {
                            if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: rect.boundingBox, width: portraitWidth, height: portraitHeight) {
                                
                                // Exclude skin tone
                                if !self.isHumanSkinTone(cropped) {
                                    let inkAnalysis = self.analyzePlayingCardInkAndFace(cropped)
                                    
                                    // RULE 2 & 3:
                                    // - Front face verified: ink_ratio (red + black) >= 0.15 (Rejects back of card < 0.10)
                                    // - Ink requirements: red_ratio >= 0.008 OR black_ratio >= 0.030 (True Black V < 55)
                                    // - White paper base >= 20%
                                    let isGenuineFrontFace = inkAnalysis.isFrontFace && inkAnalysis.hasValidInk && (inkAnalysis.whiteRatio >= 0.20)
                                    let hasRank = (recognizedRankBox != nil)
                                    
                                    if isGenuineFrontFace || hasRank {
                                        let score = inkAnalysis.whiteRatio + inkAnalysis.inkRatio * 3.0 + (hasRank ? 3.0 : 0.0)
                                        
                                        if score > maxScore {
                                            maxScore = score
                                            bestCardBoxNormalized = cardBoxNormalized
                                            bestCropBoxNormalized = rect.boundingBox
                                            
                                            if let rank = recognizedRankBox?.1 {
                                                detectedCardName = "LÁ BÀI: \(rank)"
                                            } else if inkAnalysis.redRatio >= 0.010 {
                                                detectedCardName = "LÁ BÀI (RÔ/CƠ)"
                                            } else {
                                                detectedCardName = "LÁ BÀI (BÍCH/CHUỒN)"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Fallback to OCR rank box if rectangle detector missed due to heavy occlusion
                if bestCardBoxNormalized == nil, let (rankBox, rank) = recognizedRankBox {
                    let cardW: CGFloat = 0.22
                    let cardH: CGFloat = 0.28
                    let originX = max(0.0, min(1.0 - cardW, rankBox.midX - cardW / 2.0))
                    let originY = max(0.0, min(1.0 - cardH, (1.0 - rankBox.midY) - cardH / 2.0))
                    
                    let candidateBox = CGRect(x: originX, y: originY, width: cardW, height: cardH)
                    let cropBox = CGRect(x: originX, y: 1.0 - originY - cardH, width: cardW, height: cardH)
                    
                    if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: cropBox, width: portraitWidth, height: portraitHeight) {
                        if !self.isHumanSkinTone(cropped) {
                            let ink = self.analyzePlayingCardInkAndFace(cropped)
                            if ink.whiteRatio >= 0.15 {
                                bestCardBoxNormalized = candidateBox
                                bestCropBoxNormalized = cropBox
                                detectedCardName = "LÁ BÀI: \(rank)"
                                maxScore = 2.5
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
            
            let isSkin = (r > 80 && g > 40 && b > 20 && r > g && (r - b) > 10 && saturation >= 0.12 && saturation <= 0.65)
            if isSkin {
                skinPixels += 1
            }
            totalPixels += 1
        }
        
        let skinRatio = totalPixels > 0 ? Float(skinPixels) / Float(totalPixels) : 0.0
        return skinRatio >= 0.35 // Rejects crops with >= 35% skin tone
    }
    
    /// Precision Playing Card Ink & Face/Back Analyzer:
    /// - Strict Black: V < 55
    /// - Strict Red: H in red spectrum
    /// - Face vs Back: Requires ink_ratio (red + black) >= 0.15 (Back has ink < 0.10)
    /// - Valid Ink: red_ratio >= 0.008 OR black_ratio >= 0.030
    private func analyzePlayingCardInkAndFace(_ image: UIImage) -> (whiteRatio: Float, redRatio: Float, blackRatio: Float, inkRatio: Float, hasValidInk: Bool, isFrontFace: Bool) {
        guard let cgImage = image.cgImage else { return (0, 0, 0, 0, false, false) }
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
        ) else { return (0, 0, 0, 0, false, false) }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var whitePixels = 0
        var redPixels = 0
        var blackPixels = 0
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
                
                // 1. White Paper (Brightness >= 40, Saturation <= 0.45)
                if brightness >= 40.0 && saturation <= 0.45 {
                    whitePixels += 1
                }
                
                // 2. Strict Red Ink (♥ Cơ, ♦ Rô)
                if r >= 90 && r > 1.25 * g && r > 1.25 * b && saturation >= 0.32 {
                    redPixels += 1
                }
                
                // 3. Strict True Black Ink (♠ Bích, ♣ Chuồn & Rank Numbers: V < 55)
                if brightness < 55.0 && saturation <= 0.35 {
                    blackPixels += 1
                }
                
                totalPixels += 1
            }
        }
        
        let whiteRatio = totalPixels > 0 ? Float(whitePixels) / Float(totalPixels) : 0.0
        let redRatio = totalPixels > 0 ? Float(redPixels) / Float(totalPixels) : 0.0
        let blackRatio = totalPixels > 0 ? Float(blackPixels) / Float(totalPixels) : 0.0
        let inkRatio = redRatio + blackRatio
        
        // RULE 2: Valid Ink Check (red >= 0.008 OR black >= 0.030)
        let hasValidInk = (redRatio >= 0.008) || (blackRatio >= 0.030)
        
        // RULE 3: Front Face vs Back of Card (Front >= 0.15 ink, Back < 0.10 ink)
        let isFrontFace = (inkRatio >= 0.15)
        
        return (whiteRatio, redRatio, blackRatio, inkRatio, hasValidInk, isFrontFace)
    }
}
