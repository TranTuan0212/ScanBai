//
//  CardDetector.swift
//  CardLink
//
//  240 FPS Vision AI Card Detector & Sharp Card Surface Cropper.
//  STRICT RULE ENFORCED: Must have an active human hand skeleton touching/holding
//  the card rectangle! Without a human hand skeleton, NO card can be detected.
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
    @Published var debugLogText: String = "NO HAND DETECTED"
    
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var smoothedBox: CGRect?
    
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, completion: @escaping (CardDetectionResult?) -> Void) {
        autoreleasepool {
            let portraitCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            let portraitWidth = Int(portraitCIImage.extent.width)
            let portraitHeight = Int(portraitCIImage.extent.height)
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            
            // 1. Hand Skeleton Pose Request
            let handPoseRequest = VNDetectHumanHandPoseRequest()
            handPoseRequest.maximumHandCount = 2
            
            // 2. Rectangle Detection Request for Cards
            let rectRequest = VNDetectRectanglesRequest()
            rectRequest.minimumAspectRatio = 0.40
            rectRequest.maximumAspectRatio = 0.95
            rectRequest.minimumSize = 0.03
            rectRequest.maximumObservations = 5
            rectRequest.quadratureTolerance = 35
            
            do {
                try handler.perform([handPoseRequest, rectRequest])
                
                // Extract Hand Skeleton Joints
                var extractedJoints: [CGPoint] = []
                if let handObservations = handPoseRequest.results as? [VNHumanHandPoseObservation], !handObservations.isEmpty {
                    for observation in handObservations {
                        if let recognizedPoints = try? observation.recognizedPoints(.all) {
                            for (_, pointKey) in recognizedPoints {
                                if pointKey.confidence > 0.25 {
                                    extractedJoints.append(CGPoint(x: pointKey.location.x, y: 1.0 - pointKey.location.y))
                                }
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.handSkeletonPoints = extractedJoints
                }
                
                // MANDATORY RULE: NO HUMAN HAND SKELETON DETECTED -> NO CARD CAN EXIST!
                guard !extractedJoints.isEmpty else {
                    DispatchQueue.main.async {
                        self.detectionBox = nil
                        self.debugLogText = "NO HAND SKELETON -> CARD DISABLED"
                    }
                    completion(nil)
                    return
                }
                
                // Process Card Rectangles
                guard let rectResults = rectRequest.results as? [VNRectangleObservation], !rectResults.isEmpty else {
                    DispatchQueue.main.async {
                        self.detectionBox = nil
                        self.debugLogText = "HAND JOINTS:\(extractedJoints.count) | NO RECT"
                    }
                    completion(nil)
                    return
                }
                
                var bestCardRect: VNRectangleObservation? = nil
                var maxCardWhiteScore: Float = -1.0
                
                for rect in rectResults {
                    let b = rect.boundingBox
                    let cardBoxNormalized = CGRect(
                        x: b.origin.x,
                        y: 1.0 - b.origin.y - b.height,
                        width: b.width,
                        height: b.height
                    )
                    
                    let area = b.width * b.height
                    let ratio = min(b.width, b.height) / max(b.width, b.height)
                    
                    // Standard playing card ratio is ~0.60 - 0.75 (2.5" x 3.5")
                    if area >= 0.015 && area <= 0.80 && ratio >= 0.40 && ratio <= 0.95 {
                        
                        // STRICT RULE: Human hand MUST be physically touching / overlapping this card rectangle!
                        let isHandTouchingCard = self.isHandTouchingCardRect(cardBox: cardBoxNormalized, handJoints: extractedJoints)
                        
                        if isHandTouchingCard {
                            if let cropped = self.cropCardSurface(portraitCIImage, rect: rect, width: portraitWidth, height: portraitHeight) {
                                let whitePaperScore = self.calculatePlayingCardWhiteScore(cropped)
                                
                                // Must pass white paper surface threshold (>= 0.35)
                                if whitePaperScore >= 0.35 && whitePaperScore > maxCardWhiteScore {
                                    maxCardWhiteScore = whitePaperScore
                                    bestCardRect = rect
                                }
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.debugLogText = "HAND JOINTS:\(extractedJoints.count) | CARD SCORE:\(String(format: "%.2f", maxCardWhiteScore))"
                }
                
                // STRICT: If no rectangle was touched by hand or failed white score, return nil!
                guard let cardRect = bestCardRect else {
                    DispatchQueue.main.async {
                        self.detectionBox = nil
                    }
                    completion(nil)
                    return
                }
                
                let rawBox = CGRect(
                    x: cardRect.boundingBox.origin.x,
                    y: 1.0 - cardRect.boundingBox.origin.y - cardRect.boundingBox.height,
                    width: cardRect.boundingBox.width,
                    height: cardRect.boundingBox.height
                )
                
                let targetBox = self.smoothBox(rawBox)
                self.smoothedBox = targetBox
                
                DispatchQueue.main.async {
                    self.detectionBox = targetBox
                }
                
                // Straighten & Crop sharpest card surface
                if let uprightCard = self.rectifyAndUnrotateCard(portraitCIImage, rect: cardRect, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: "LÁ BÀI CÓ KHUNG TAY 240FPS",
                        confidence: 0.98,
                        boundingBox: targetBox,
                        cardImage: uprightCard
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
    
    /// Checks if any human hand joint physically touches / overlaps the card rectangle
    private func isHandTouchingCardRect(cardBox: CGRect, handJoints: [CGPoint]) -> Bool {
        // Expand card box slightly by 20% margin to cover fingers holding edges of the card
        let expandedBox = cardBox.insetBy(dx: -0.20 * cardBox.width, dy: -0.20 * cardBox.height)
        
        for joint in handJoints {
            if expandedBox.contains(joint) {
                return true
            }
        }
        return false
    }
    
    private func smoothBox(_ newBox: CGRect) -> CGRect {
        guard let prev = smoothedBox else { return newBox }
        let alpha: CGFloat = 0.45
        return CGRect(
            x: prev.origin.x * (1 - alpha) + newBox.origin.x * alpha,
            y: prev.origin.y * (1 - alpha) + newBox.origin.y * alpha,
            width: prev.size.width * (1 - alpha) + newBox.size.width * alpha,
            height: prev.size.height * (1 - alpha) + newBox.size.height * alpha
        )
    }
    
    private func cropCardSurface(_ ciImage: CIImage, rect: VNRectangleObservation, width: Int, height: Int) -> UIImage? {
        let cropRect = CGRect(
            x: rect.boundingBox.origin.x * CGFloat(width),
            y: rect.boundingBox.origin.y * CGFloat(height),
            width: rect.boundingBox.width * CGFloat(width),
            height: rect.boundingBox.height * CGFloat(height)
        )
        
        let croppedCI = ciImage.cropped(to: cropRect)
        guard let cgImage = CardDetector.ciContext.createCGImage(croppedCI, from: croppedCI.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    /// Calculates Pure Playing Card White Paper Score
    private func calculatePlayingCardWhiteScore(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.0 }
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
        ) else { return 0.0 }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var whitePaperPixels = 0
        var totalPixels = 0
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0
            let brightness = (r + g + b) / 3.0
            
            if brightness >= 95.0 && saturation <= 0.45 {
                whitePaperPixels += 1
            }
            totalPixels += 1
        }
        
        return totalPixels > 0 ? Float(whitePaperPixels) / Float(totalPixels) : 0.0
    }
    
    private func rectifyAndUnrotateCard(_ ciImage: CIImage, rect: VNRectangleObservation, width: Int, height: Int) -> UIImage? {
        let imageSize = CGSize(width: width, height: height)
        
        let topLeft = CGPoint(x: rect.topLeft.x * imageSize.width, y: rect.topLeft.y * imageSize.height)
        let topRight = CGPoint(x: rect.topRight.x * imageSize.width, y: rect.topRight.y * imageSize.height)
        let bottomLeft = CGPoint(x: rect.bottomLeft.x * imageSize.width, y: rect.bottomLeft.y * imageSize.height)
        let bottomRight = CGPoint(x: rect.bottomRight.x * imageSize.width, y: rect.bottomRight.y * imageSize.height)
        
        guard let perspectiveFilter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        perspectiveFilter.setValue(ciImage, forKey: kCIInputImageKey)
        perspectiveFilter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        perspectiveFilter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        perspectiveFilter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        perspectiveFilter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        
        guard let correctedImage = perspectiveFilter.outputImage else { return nil }
        guard let cgImage = CardDetector.ciContext.createCGImage(correctedImage, from: correctedImage.extent) else { return nil }
        
        return UIImage(cgImage: cgImage)
    }
}
