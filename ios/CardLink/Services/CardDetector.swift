//
//  CardDetector.swift
//  CardLink
//
//  Ultra High-Speed 240 FPS Surface Detection & Sharp Card Cropper.
//  Focuses 100% on detecting card rect bounds, cropping straightened card surface,
//  and feeding crisp 240 FPS frames to CardSlowMoSlicer for accurate round-robin deal streaming!
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
    @Published var debugLogText: String = "HAND SKELETON IDLE"
    
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
            rectRequest.minimumAspectRatio = 0.30
            rectRequest.maximumAspectRatio = 0.95
            rectRequest.minimumSize = 0.03
            rectRequest.quadratureTolerance = 30
            
            do {
                try handler.perform([handPoseRequest, rectRequest])
                
                // Process Hand Skeleton Joints
                var extractedJoints: [CGPoint] = []
                if let handObservations = handPoseRequest.results as? [VNHumanHandPoseObservation], !handObservations.isEmpty {
                    for observation in handObservations {
                        if let recognizedPoints = try? observation.recognizedPoints(.all) {
                            for (_, pointKey) in recognizedPoints {
                                if pointKey.confidence > 0.30 {
                                    extractedJoints.append(CGPoint(x: pointKey.location.x, y: 1.0 - pointKey.location.y))
                                }
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.handSkeletonPoints = extractedJoints
                }
                
                // Process Card Rectangle
                guard let rectResults = rectRequest.results as? [VNRectangleObservation], !rectResults.isEmpty else {
                    DispatchQueue.main.async {
                        self.detectionBox = nil
                        self.debugLogText = "HAND JOINTS:\(extractedJoints.count) | NO CARD RECT"
                    }
                    completion(nil)
                    return
                }
                
                var bestCardRect: VNRectangleObservation? = nil
                var maxWhiteScore: Float = -1.0
                
                for rect in rectResults {
                    let b = rect.boundingBox
                    let area = b.width * b.height
                    let ratio = min(b.width, b.height) / max(b.width, b.height)
                    
                    if area >= 0.02 && area <= 0.88 && ratio >= 0.30 && ratio <= 0.95 {
                        if let cropped = self.cropCardSurface(portraitCIImage, rect: rect, width: portraitWidth, height: portraitHeight) {
                            let whiteScore = self.calculatePureWhiteDeckScore(cropped)
                            if whiteScore > maxWhiteScore && whiteScore >= 0.25 {
                                maxWhiteScore = whiteScore
                                bestCardRect = rect
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.debugLogText = "HAND JOINTS:\(extractedJoints.count) | CARD SCORE:\(String(format: "%.2f", maxWhiteScore))"
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
                
                // Straighten & Crop sharpest card surface
                if let uprightCard = self.rectifyAndUnrotateCard(portraitCIImage, rect: cardRect, width: portraitWidth, height: portraitHeight) {
                    let result = CardDetectionResult(
                        cardName: "LÁ BÀI SẮC NÉT 240FPS",
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
    
    private func smoothBox(_ newBox: CGRect) -> CGRect {
        guard let prev = smoothedBox else { return newBox }
        let alpha: CGFloat = 0.40
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
    
    private func calculatePureWhiteDeckScore(_ image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 0.0 }
        let width = 24
        let height = 30
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
        
        var whiteDeckPixels = 0
        var totalPixels = 0
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            let saturation = maxRGB > 0 ? (maxRGB - minRGB) / maxRGB : 0.0
            
            if maxRGB >= 130 && saturation <= 0.35 {
                whiteDeckPixels += 1
            }
            totalPixels += 1
        }
        
        return totalPixels > 0 ? Float(whiteDeckPixels) / Float(totalPixels) : 0.0
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
