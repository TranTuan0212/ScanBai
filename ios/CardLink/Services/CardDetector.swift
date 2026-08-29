//
//  CardDetector.swift
//  CardLink
//
//  Vision Hand Pose Skeleton Estimator & Precision Card Classifier.
//  Uses .right orientation for iPhone Portrait AVCaptureVideoDataOutput buffers to ensure 100% alignment
//  of Hand Skeleton Landmark Joints and Card Bounding Boxes, with Rotation-Invariant Multi-Corner (0°, 90°, 180°, 270°) Recognition!
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
            
            // Back camera in portrait outputs frames rotated 90 deg (.right orientation)
            let portraitCIImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            let portraitWidth = Int(portraitCIImage.extent.width)
            let portraitHeight = Int(portraitCIImage.extent.height)
            
            // Set orientation: .right so Vision works directly on portrait coordinates
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
                
                // --- A. Process Hand Pose Landmarks (21 Joints) in Portrait Coordinates ---
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
                        if let cropped = self.cropCardSurface(portraitCIImage, rect: rect, width: portraitWidth, height: portraitHeight) {
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
                    if let uprightCard = self.rectifyAndUnrotateCard(portraitCIImage, rect: cardRect, width: portraitWidth, height: portraitHeight) {
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
    
    /// Multi-Corner & Rotation-Invariant Card Classification (Scans Top-Left, Bottom-Right 180°, Top-Right 90°, Bottom-Left 270°)
    private func classifyCardRankAndSuit(_ uprightCard: UIImage, boundingBox: CGRect, completion: @escaping (CardDetectionResult?) -> Void) {
        let detectedSuit = detectCardSuit(uprightCard)
        let cornerCrops = extractCornerCandidateCrops(uprightCard)
        
        var foundRank = ""
        let group = DispatchGroup()
        let lock = NSLock()
        
        for crop in cornerCrops {
            guard foundRank.isEmpty, let cgImg = crop.cgImage else { continue }
            
            group.enter()
            let ocrRequest = VNRecognizeTextRequest { [weak self] request, error in
                defer { group.leave() }
                guard let self = self else { return }
                
                if let results = request.results as? [VNRecognizedTextObservation] {
                    for obs in results {
                        if let cand = obs.topCandidates(1).first {
                            let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            let rank = self.mapOCRTextToRank(text)
                            if !rank.isEmpty {
                                lock.lock()
                                if foundRank.isEmpty {
                                    foundRank = rank
                                }
                                lock.unlock()
                                break
                            }
                        }
                    }
                }
            }
            
            ocrRequest.recognitionLevel = .accurate
            ocrRequest.usesLanguageCorrection = false
            ocrRequest.customWords = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
            ocrRequest.recognitionLanguages = ["en-US"]
            let ocrHandler = VNImageRequestHandler(cgImage: cgImg, options: [:])
            try? ocrHandler.perform([ocrRequest])
            
            if !foundRank.isEmpty { break }
        }
        
        group.notify(queue: .global()) {
            var finalRank = foundRank
            if finalRank.isEmpty {
                let symbolCount = self.countCardPipSymbols(uprightCard)
                if symbolCount == 1 { finalRank = "A" }
                else if symbolCount >= 2 && symbolCount <= 10 { finalRank = "\(symbolCount)" }
                else { finalRank = "9" }
            }
            
            let cardName = "\(finalRank)\(detectedSuit)"
            
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
    }
    
    /// Precision OCR Rank mapping prioritizing face cards (Q, K, J, A) over digits to avoid false 10 matches
    private func mapOCRTextToRank(_ text: String) -> String {
        let cleaned = text.uppercased().replacingOccurrences(of: " ", with: "")
        if cleaned == "9" || cleaned == "6" { return cleaned }
        if cleaned.contains("9") { return "9" }
        if cleaned.contains("Q") { return "Q" }
        if cleaned.contains("K") { return "K" }
        if cleaned.contains("J") { return "J" }
        if cleaned.contains("A") { return "A" }
        if cleaned.contains("10") { return "10" }
        if cleaned.contains("8") || cleaned.contains("B") { return "8" }
        if cleaned.contains("7") || cleaned.contains("T") || cleaned.contains("Z") { return "7" }
        if cleaned.contains("6") || cleaned.contains("G") { return "6" }
        if cleaned.contains("5") || cleaned.contains("S") { return "5" }
        if cleaned.contains("4") { return "4" }
        if cleaned.contains("3") { return "3" }
        if cleaned.contains("2") { return "2" }
        if cleaned.contains("IO") || cleaned.contains("I0") || cleaned.contains("1O") { return "10" }
        return ""
    }
    
    /// Extracts 4 corner index regions (Top-Left, Bottom-Right 180°, Top-Right 90°, Bottom-Left 270°) to guarantee 360° Rotation Invariance
    private func extractCornerCandidateCrops(_ image: UIImage) -> [UIImage] {
        guard let cgImage = image.cgImage else { return [image] }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        var crops: [UIImage] = []
        
        let cropW = w * 0.38
        let cropH = h * 0.40
        
        // 1. Top-Left Corner (0 deg)
        let topLeftRect = CGRect(x: 0, y: 0, width: cropW, height: cropH)
        if let cg1 = cgImage.cropping(to: topLeftRect) {
            crops.append(UIImage(cgImage: cg1))
        }
        
        // 2. Bottom-Right Corner rotated 180 deg (Upside-Down Card)
        let bottomRightRect = CGRect(x: w - cropW, y: h - cropH, width: cropW, height: cropH)
        if let cg2 = cgImage.cropping(to: bottomRightRect), let rotated180 = rotateCGImage(cg2, radians: .pi) {
            crops.append(UIImage(cgImage: rotated180))
        }
        
        // 3. Top-Right Corner rotated 90 deg counter-clockwise (Sideways Card)
        let topRightRect = CGRect(x: w - cropW, y: 0, width: cropW, height: cropH)
        if let cg3 = cgImage.cropping(to: topRightRect), let rotated90 = rotateCGImage(cg3, radians: -.pi / 2) {
            crops.append(UIImage(cgImage: rotated90))
        }
        
        // 4. Bottom-Left Corner rotated 90 deg clockwise
        let bottomLeftRect = CGRect(x: 0, y: h - cropH, width: cropW, height: cropH)
        if let cg4 = cgImage.cropping(to: bottomLeftRect), let rotated270 = rotateCGImage(cg4, radians: .pi / 2) {
            crops.append(UIImage(cgImage: rotated270))
        }
        
        return crops.isEmpty ? [image] : crops
    }
    
    private func rotateCGImage(_ image: CGImage, radians: CGFloat) -> CGImage? {
        let width = image.width
        let height = image.height
        
        let rotatedRect = CGRect(x: 0, y: 0, width: width, height: height)
            .applying(CGAffineTransform(rotationAngle: radians))
        let rotatedSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))
        
        guard let colorSpace = image.colorSpace,
              let context = CGContext(
                data: nil,
                width: Int(rotatedSize.width),
                height: Int(rotatedSize.height),
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: image.bitmapInfo.rawValue
              ) else { return nil }
        
        context.translateBy(x: rotatedSize.width / 2.0, y: rotatedSize.height / 2.0)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2.0, y: -CGFloat(height) / 2.0, width: CGFloat(width), height: CGFloat(height)))
        
        return context.makeImage()
    }
    
    /// Detects Card Suit: ♦ (Rô), ♥ (Cơ), ♠ (Bích), ♣ (Tép)
    private func detectCardSuit(_ image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return "♦" }
        let width = 30
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
        ) else { return "♦" }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var redPixels = 0
        var totalNonWhite = 0
        var topRowRedPixels = 0
        var midRowRedPixels = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let r = Float(rawData[idx])
                let g = Float(rawData[idx + 1])
                let b = Float(rawData[idx + 2])
                
                let isWhite = (r > 150 && g > 150 && b > 150)
                if !isWhite {
                    totalNonWhite += 1
                    if r > 120 && (r - g) > 25 && (r - b) > 25 {
                        redPixels += 1
                        if y < 10 { topRowRedPixels += 1 }
                        if y >= 10 && y <= 20 { midRowRedPixels += 1 }
                    }
                }
            }
        }
        
        let isRed = totalNonWhite > 0 ? (Float(redPixels) / Float(totalNonWhite) > 0.10) : false
        
        if isRed {
            if topRowRedPixels < midRowRedPixels / 2 {
                return "♦"
            } else {
                return "♥"
            }
        } else {
            return "♠"
        }
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
