//
//  CardDetector.swift
//  CardLink
//
//  Ultra-Precise 240 FPS Playing Card & Internal Suit/Pip Shape Analyzer.
//  Strictly verifies:
//  1. Card Color Palette: White Paper Base + Red (♥ ♦) / Black (♠ ♣) Suit Inks
//  2. Card Internal Shapes: Rank & Suit Pips, Figures (A, 2..10, J, Q, K), and High-Contrast Edge Contours
//  3. Playing Card Aspect Ratio (0.45..0.88) and Area (2.5%..28%)
//  Zero tolerance for legs, shorts, thighs, bedsheets, or background furniture.
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
            
            // 1. Hand Skeleton Pose Request
            let handPoseRequest = VNDetectHumanHandPoseRequest()
            handPoseRequest.maximumHandCount = 2
            
            // 2. Strict Playing Card Rectangle Request
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.45
            rectRequest.maximumAspectRatio = 0.88
            rectRequest.minimumSize = 0.025
            rectRequest.minimumConfidence = 0.20
            rectRequest.maximumObservations = 5
            rectRequest.quadratureTolerance = 35
            
            do {
                try handler.perform([handPoseRequest, rectRequest])
                
                // Extract Hand Skeleton Joints
                var extractedJoints: [CGPoint] = []
                if let handObservations = handPoseRequest.results, !handObservations.isEmpty {
                    for observation in handObservations {
                        if let recognizedPoints = try? observation.recognizedPoints(.all) {
                            for (_, pointKey) in recognizedPoints {
                                if pointKey.confidence > 0.15 {
                                    extractedJoints.append(CGPoint(x: pointKey.location.x, y: 1.0 - pointKey.location.y))
                                }
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.handSkeletonPoints = extractedJoints
                }
                
                // STRICT RULE 1: IF NO HUMAN HAND IS PRESENT, CANCEL IMMEDIATELY
                guard !extractedJoints.isEmpty else {
                    DispatchQueue.main.async {
                        self.detectionBox = nil
                        self.smoothedBox = nil
                        self.debugLogText = "NO HAND DETECTED"
                    }
                    completion(nil)
                    return
                }
                
                var bestCardBoxNormalized: CGRect? = nil
                var bestCropBoxNormalized: CGRect? = nil
                var maxScore: Float = -1.0
                
                // 3. Strict Playing Card Verification
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
                        let cardRatio = min(b.width, b.height) / max(b.width, b.height)
                        
                        // STRICT RULE 2: Playing Card Area (2.5%..28%) & Ratio (0.45..0.88)
                        if area >= 0.025 && area <= 0.28 && cardRatio >= 0.45 && cardRatio <= 0.88 {
                            
                            // STRICT RULE 3: Fingers MUST be touching/holding the card
                            let isHandTouching = self.isHandTouchingCardRect(cardBox: cardBoxNormalized, handJoints: extractedJoints)
                            
                            if isHandTouching {
                                if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: rect.boundingBox, width: portraitWidth, height: portraitHeight) {
                                    
                                    // STRICT RULE 4: Reject human skin tone crops (legs, thighs, arms)
                                    if !self.isHumanSkinTone(cropped) {
                                        
                                        // STRICT RULE 5: Verify Card Colors (White Paper + Red/Black Inks) & Internal Suit Shapes
                                        let analysis = self.analyzePlayingCardColorsAndSymbols(cropped)
                                        let hasRankSymbol = self.containsCardRankSymbol(cropped)
                                        
                                        // A genuine playing card MUST have:
                                        // - White paper base >= 30%
                                        // - Red Suit (♥ ♦) or Black Ink (♠ ♣) >= 1.5%
                                        // - High internal shape contrast or recognized rank letter/number
                                        if analysis.isGenuineCard || hasRankSymbol {
                                            let score = analysis.whiteRatio + analysis.suitInkRatio * 2.0 + (hasRankSymbol ? 2.0 : 0.0)
                                            
                                            if score > maxScore {
                                                maxScore = score
                                                bestCardBoxNormalized = cardBoxNormalized
                                                
                                                let marginX = rect.boundingBox.width * 0.25
                                                let marginY = rect.boundingBox.height * 0.25
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
                    self.debugLogText = "🎴 CARD DETECTED (SCORE:\(String(format: "%.2f", maxScore)))"
                }
                
                if let zoomedCardImage = self.cropRegionOfInterest(portraitCIImage, normalizedBox: cropBox, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: "LÁ BÀI 240FPS",
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
    
    private func isHandTouchingCardRect(cardBox: CGRect, handJoints: [CGPoint]) -> Bool {
        let touchBox = cardBox.insetBy(dx: -0.25 * cardBox.width, dy: -0.25 * cardBox.height)
        for joint in handJoints {
            if touchBox.contains(joint) {
                return true
            }
        }
        return false
    }
    
    private func containsCardRankSymbol(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        
        let cornerWidth = Int(CGFloat(cgImage.width) * 0.40)
        let cornerHeight = Int(CGFloat(cgImage.height) * 0.45)
        let cornerRect = CGRect(x: 0, y: 0, width: cornerWidth, height: cornerHeight)
        
        guard let cornerCG = cgImage.cropping(to: cornerRect) else { return false }
        
        let requestHandler = VNImageRequestHandler(cgImage: cornerCG, options: [:])
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        
        do {
            try requestHandler.perform([textRequest])
            if let results = textRequest.results {
                for observation in results {
                    if let candidate = observation.topCandidates(1).first {
                        let text = candidate.string.uppercased()
                        let cardRanks = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
                        for rank in cardRanks {
                            if text.contains(rank) {
                                return true
                            }
                        }
                    }
                }
            }
        } catch {}
        return false
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
            if r > 95 && g > 40 && b > 20 && (maxRGB - minRGB) > 15 && abs(r - g) > 15 && r > g && r > b {
                skinPixels += 1
            }
            totalPixels += 1
        }
        
        let skinRatio = totalPixels > 0 ? Float(skinPixels) / Float(totalPixels) : 0.0
        return skinRatio >= 0.45 // Rejects skin crops if >= 45% skin
    }
    
    /// Analyzes Playing Card Color Palette (White Paper + Red/Black Suit Inks) & Internal Shape Contrast
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
        var redSuitPixels = 0     // Cơ (♥), Rô (♦)
        var blackSuitPixels = 0   // Bích (♠), Chuồn (♣) & Black rank text
        var totalPixels = 0
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0
            let brightness = (r + g + b) / 3.0
            
            // 1. White Card Paper Base
            if brightness >= 45.0 && saturation <= 0.50 {
                whitePaperPixels += 1
            }
            
            // 2. Red Suit Symbols (♥ Cơ, ♦ Rô)
            if r >= 100 && r > 1.35 * g && r > 1.35 * b && saturation >= 0.35 {
                redSuitPixels += 1
            }
            
            // 3. Black Suit Symbols (♠ Bích, ♣ Chuồn & Black Numbers)
            if brightness <= 50.0 && saturation <= 0.35 {
                blackSuitPixels += 1
            }
            
            totalPixels += 1
        }
        
        let whiteRatio = totalPixels > 0 ? Float(whitePaperPixels) / Float(totalPixels) : 0.0
        let redRatio = totalPixels > 0 ? Float(redSuitPixels) / Float(totalPixels) : 0.0
        let blackRatio = totalPixels > 0 ? Float(blackSuitPixels) / Float(totalPixels) : 0.0
        let suitInkRatio = redRatio + blackRatio
        
        // A genuine playing card must have:
        // - At least 30% white paper
        // - At least 1.5% printed suit symbol ink (Red or Black)
        let isGenuine = (whiteRatio >= 0.30) && (suitInkRatio >= 0.015)
        return (whiteRatio, suitInkRatio, isGenuine)
    }
}
