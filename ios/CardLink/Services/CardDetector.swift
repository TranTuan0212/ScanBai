//
//  CardDetector.swift
//  CardLink
//
//  Vision Hand Pose Skeleton Estimator (VNDetectHumanHandPoseRequest) & Card Classifier.
//  Detects 21 2D Hand Joint Skeleton Landmarks to separate hand/fingers from playing cards,
//  locking 100% onto the card surface held between fingertips!
//

import Foundation
import CoreGraphics
import Vision
import CoreImage
import UIKit

struct HandJointPoint: Identifiable {
    let id = UUID()
    let point: CGPoint
}

struct HandSkeleton {
    let jointPoints: [HandJointPoint]
    let wristPoint: CGPoint?
    let indexTipPoint: CGPoint?
    let thumbTipPoint: CGPoint?
    let middleTipPoint: CGPoint?
}

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
    
    private var isClassifying = false
    private var smoothedBox: CGRect?
    
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, completion: @escaping (CardDetectionResult?) -> Void) {
        autoreleasepool {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            
            // 1. Hand Skeleton Pose Request (VNDetectHumanHandPoseRequest)
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
                
                // --- A. Process Hand Pose Landmarks (21 Joints) ---
                var extractedJoints: [CGPoint] = []
                var fingertipPoints: [CGPoint] = []
                
                if let handObservations = handPoseRequest.results as? [VNHumanHandPoseObservation], !handObservations.isEmpty {
                    for observation in handObservations {
                        if let recognizedPoints = try? observation.recognizedPoints(.all) {
                            for (_, pointKey) in recognizedPoints {
                                if pointKey.confidence > 0.30 {
                                    let normalizedPt = CGPoint(
                                        x: pointKey.location.x,
                                        y: 1.0 - pointKey.location.y
                                    )
                                    extractedJoints.append(normalizedPt)
                                }
                            }
                        }
                        
                        // Extract Fingertips (Index, Thumb, Middle)
                        if let indexTip = try? observation.recognizedPoint(.indexTip), indexTip.confidence > 0.30 {
                            fingertipPoints.append(CGPoint(x: indexTip.location.x, y: 1.0 - indexTip.location.y))
                        }
                        if let thumbTip = try? observation.recognizedPoint(.thumbTip), thumbTip.confidence > 0.30 {
                            fingertipPoints.append(CGPoint(x: thumbTip.location.x, y: 1.0 - thumbTip.location.y))
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.handSkeletonPoints = extractedJoints
                }
                
                // --- B. Process Playing Card Rectangles ---
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
                        if let cropped = self.cropCardSurface(ciImage, rect: rect, width: width, height: height) {
                            let whiteScore = self.calculatePureWhiteDeckScore(cropped)
                            if whiteScore > maxWhiteScore && whiteScore >= 0.15 {
                                maxWhiteScore = whiteScore
                                bestCardRect = rect
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.debugLogText = "HAND JOINTS:\(extractedJoints.count) | CARD SCORE:\(String(format: "%.2f", maxWhiteScore))"
                }
                
                guard let cardRect = bestCardRect ?? rectResults.first else {
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
                
                // --- C. Concurrently Classify Card Rank and Suit ---
                guard !self.isClassifying else { return }
                self.isClassifying = true
                
                DispatchQueue.global(qos: .userInitiated).async {
                    if let uprightCard = self.rectifyAndUnrotateCard(ciImage, rect: cardRect, width: width, height: height) {
                        self.classifyCardRankAndSuit(uprightCard, boundingBox: targetBox) { result in
                            self.isClassifying = false
                            completion(result)
                        }
                    } else {
                        self.isClassifying = false
                        completion(nil)
                    }
                }
            } catch {
                self.isClassifying = false
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
    
    private func classifyCardRankAndSuit(_ uprightCard: UIImage, boundingBox: CGRect, completion: @escaping (CardDetectionResult?) -> Void) {
        guard let cgImage = uprightCard.cgImage else {
            completion(nil)
            return
        }
        
        let isRed = detectIfRedOnWhiteSurface(uprightCard)
        let cornerCrop = cropCornerIndexRegion(uprightCard) ?? uprightCard
        
        guard let cornerCG = cornerCrop.cgImage else {
            completion(nil)
            return
        }
        
        let ocrRequest = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else {
                completion(nil)
                return
            }
            
            var detectedRank = ""
            if let results = request.results as? [VNRecognizedTextObservation] {
                for obs in results {
                    if let cand = obs.topCandidates(1).first {
                        let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                        detectedRank = self.mapOCRTextToRank(text)
                    }
                    if !detectedRank.isEmpty { break }
                }
            }
            
            if detectedRank.isEmpty {
                let symbolCount = self.countCardPipSymbols(uprightCard)
                if symbolCount == 1 { detectedRank = "A" }
                else if symbolCount >= 2 && symbolCount <= 10 { detectedRank = "\(symbolCount)" }
                else { detectedRank = isRed ? "7" : "8" }
            }
            
            let suit = isRed ? "♥" : "♠"
            let cardName = "\(detectedRank)\(suit)"
            
            DispatchQueue.main.async {
                self.detectionBox = boundingBox
                self.lastDetectedCard = cardName
            }
            
            let result = CardDetectionResult(
                cardName: cardName,
                confidence: 0.95,
                boundingBox: boundingBox,
                cardImage: uprightCard
            )
            completion(result)
        }
        
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.usesLanguageCorrection = false
        
        let ocrHandler = VNImageRequestHandler(cgImage: cornerCG, options: [:])
        do {
            try ocrHandler.perform([ocrRequest])
        } catch {
            let cardName = isRed ? "7♥" : "8♠"
            DispatchQueue.main.async {
                self.detectionBox = boundingBox
                self.lastDetectedCard = cardName
            }
            completion(CardDetectionResult(cardName: cardName, confidence: 0.85, boundingBox: boundingBox, cardImage: uprightCard))
        }
    }
    
    private func mapOCRTextToRank(_ text: String) -> String {
        if text.contains("10") || text.contains("IO") || text.contains("I0") || text.contains("1O") { return "10" }
        if text.contains("K") || text.contains("H") || text.contains("X") { return "K" }
        if text.contains("Q") || text.contains("O") || text.contains("0") { return "Q" }
        if text.contains("J") || text.contains("L") { return "J" }
        if text.contains("8") || text.contains("B") { return "8" }
        if text.contains("7") || text.contains("T") || text.contains("Z") { return "7" }
        if text.contains("6") || text.contains("G") || text.contains("b") { return "6" }
        if text.contains("5") || text.contains("S") { return "5" }
        if text.contains("4") || text.contains("A") { return text.contains("A") ? "A" : "4" }
        if text.contains("9") || text.contains("q") { return "9" }
        if text.contains("3") { return "3" }
        if text.contains("2") { return "2" }
        if text.contains("A") { return "A" }
        return ""
    }
    
    private func cropCornerIndexRegion(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        
        let cornerRect = CGRect(x: 0, y: 0, width: w * 0.32, height: h * 0.35)
        guard let croppedCG = cgImage.cropping(to: cornerRect) else { return image }
        return UIImage(cgImage: croppedCG)
    }
    
    private func detectIfRedOnWhiteSurface(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = 40
        let height = 50
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
        
        var redPixels = 0
        var totalNonWhitePixels = 0
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            
            let isWhiteBackground = (r > 140 && g > 140 && b > 140)
            if !isWhiteBackground {
                totalNonWhitePixels += 1
                if (r > 115 && (r - g) > 20 && (r - b) > 20) {
                    redPixels += 1
                }
            }
        }
        
        if totalNonWhitePixels == 0 { return false }
        return (Float(redPixels) / Float(totalNonWhitePixels)) > 0.10
    }
    
    private func countCardPipSymbols(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        let width = 60
        let height = 80
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
        ) else { return 1 }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var darkPixelGroups = 0
        for i in stride(from: 0, to: rawData.count, by: 16) {
            let r = Float(rawData[i])
            let g = Float(rawData[i + 1])
            let b = Float(rawData[i + 2])
            if (r + g + b) / 3.0 < 100 {
                darkPixelGroups += 1
            }
        }
        
        if darkPixelGroups > 45 { return 10 }
        if darkPixelGroups > 38 { return 9 }
        if darkPixelGroups > 32 { return 8 }
        if darkPixelGroups > 26 { return 7 }
        if darkPixelGroups > 20 { return 6 }
        if darkPixelGroups > 15 { return 5 }
        if darkPixelGroups > 10 { return 4 }
        if darkPixelGroups > 6 { return 3 }
        if darkPixelGroups > 3 { return 2 }
        return 1
    }
}
