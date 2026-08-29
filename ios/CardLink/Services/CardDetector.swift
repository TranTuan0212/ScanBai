//
//  CardDetector.swift
//  CardLink
//
//  Ultra High-Speed 240 FPS Motion-Blur Resilient Card & Hand Detector.
//  Uses ROI Magnification (Zoom-In 40% Expanded Crop) around detected card & hand
//  for crystal-clear zoomed-in card pictures on Web Viewers.
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
            rectRequest.minimumSize = 0.025
            rectRequest.maximumObservations = 5
            rectRequest.quadratureTolerance = 30
            
            do {
                try handler.perform([handPoseRequest, rectRequest])
                
                // Extract Hand Skeleton Joints
                var extractedJoints: [CGPoint] = []
                if let handObservations = handPoseRequest.results as? [VNHumanHandPoseObservation], !handObservations.isEmpty {
                    for observation in handObservations {
                        if let recognizedPoints = try? observation.recognizedPoints(.all) {
                            for (_, pointKey) in recognizedPoints {
                                if pointKey.confidence > 0.20 {
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
                        self.debugLogText = "JOINTS:\(extractedJoints.count) | NO RECT"
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
                    
                    // Card Rect Size & Aspect Ratio Filter
                    if area >= 0.025 && area <= 0.75 && ratio >= 0.40 && ratio <= 0.95 {
                        let isHandTouchingCard = self.isHandTouchingCardRect(cardBox: cardBoxNormalized, handJoints: extractedJoints)
                        
                        if isHandTouchingCard {
                            if let cropped = self.cropRegionOfInterest(portraitCIImage, normalizedBox: rect.boundingBox, width: portraitWidth, height: portraitHeight) {
                                
                                // REJECT SKIN CROPS: Ignore rectangle if it is human finger / wrist skin!
                                if !self.isHumanSkinTone(cropped) {
                                    let whitePaperScore = self.calculatePlayingCardWhiteScore(cropped)
                                    if whitePaperScore >= 0.15 && whitePaperScore > maxCardWhiteScore {
                                        maxCardWhiteScore = whitePaperScore
                                        bestCardRect = rect
                                    }
                                }
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.debugLogText = "JOINTS:\(extractedJoints.count) | CARD SCORE:\(String(format: "%.2f", maxCardWhiteScore))"
                }
                
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
                
                // Expand card bounding box by 40% margin around card to crop & zoom in on card + hand!
                let marginX = cardRect.boundingBox.width * 0.40
                let marginY = cardRect.boundingBox.height * 0.40
                
                let expandedCropBox = CGRect(
                    x: max(0.0, cardRect.boundingBox.origin.x - marginX),
                    y: max(0.0, cardRect.boundingBox.origin.y - marginY),
                    width: min(1.0 - max(0.0, cardRect.boundingBox.origin.x - marginX), cardRect.boundingBox.width + 2 * marginX),
                    height: min(1.0 - max(0.0, cardRect.boundingBox.origin.y - marginY), cardRect.boundingBox.height + 2 * marginY)
                )
                
                // Crop zoomed region of interest from portrait CIImage
                if let zoomedCardImage = self.cropRegionOfInterest(portraitCIImage, normalizedBox: expandedCropBox, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: "LÁ BÀI PHÓNG TO 240FPS",
                        confidence: 0.98,
                        boundingBox: targetBox,
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
    
    /// Checks if any human hand joint physically touches / overlaps the card rectangle
    private func isHandTouchingCardRect(cardBox: CGRect, handJoints: [CGPoint]) -> Bool {
        let expandedBox = cardBox.insetBy(dx: -0.25 * cardBox.width, dy: -0.25 * cardBox.height)
        for joint in handJoints {
            if expandedBox.contains(joint) {
                return true
            }
        }
        return false
    }
    
    private func smoothBox(_ newBox: CGRect) -> CGRect {
        guard let prev = smoothedBox else { return newBox }
        let alpha: CGFloat = 0.60
        return CGRect(
            x: prev.origin.x * (1 - alpha) + newBox.origin.x * alpha,
            y: prev.origin.y * (1 - alpha) + newBox.origin.y * alpha,
            width: prev.size.width * (1 - alpha) + newBox.size.width * alpha,
            height: prev.size.height * (1 - alpha) + newBox.size.height * alpha
        )
    }
    
    /// Crops a normalized region of interest (ROI) from CIImage
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
    
    /// Detects if the cropped image is predominantly human skin tone (finger, wrist, palm)
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
            
            // Standard Human Skin Tone RGB heuristic
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            if r > 95 && g > 40 && b > 20 && (maxRGB - minRGB) > 15 && abs(r - g) > 15 && r > g && r > b {
                skinPixels += 1
            }
            totalPixels += 1
        }
        
        let skinRatio = totalPixels > 0 ? Float(skinPixels) / Float(totalPixels) : 0.0
        return skinRatio >= 0.55
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
            
            if brightness >= 80.0 && saturation <= 0.50 {
                whitePaperPixels += 1
            }
            totalPixels += 1
        }
        
        return totalPixels > 0 ? Float(whitePaperPixels) / Float(totalPixels) : 0.0
    }
}
