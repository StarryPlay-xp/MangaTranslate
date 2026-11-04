import CoreGraphics
import Foundation
import Vision

/// 像素坐标框，原点在图片左上角
struct Box: Codable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Vision 识别出的一行（竖排时是一列）文字
struct TextLine: Codable, Sendable {
    var text: String
    var confidence: Double
    var box: Box
}

struct TextAnalysis: Sendable {
    /// 识别出内容的文字行
    var lines: [TextLine]
    /// 检测到的文字区域，与语言无关，认不出字的地方也会有
    var regions: [CGRect]
    /// 单个字符边长的中位数，用来决定合并文字块时的间距
    var characterSize: CGFloat
}

func analyzeText(in image: CGImage, languages: [String]) async throws -> TextAnalysis {
    let size = CGSize(width: image.width, height: image.height)

    var recognize = RecognizeTextRequest()
    recognize.recognitionLevel = .accurate
    recognize.usesLanguageCorrection = true
    recognize.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }

    var detect = DetectTextRectanglesRequest()
    detect.reportCharacterBoxes = true

    let recognized = try await recognize.perform(on: image)
    let detected = try await detect.perform(on: image)

    let lines = recognized.compactMap { observation -> TextLine? in
        guard let best = observation.topCandidates(1).first else { return nil }
        let rect = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        return TextLine(text: best.string, confidence: Double(best.confidence), box: Box(rect))
    }
    let regions = detected.map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
    let characterSides = detected
        .flatMap { $0.characterBoxes ?? [] }
        .map { box in
            let rect = box.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            return max(rect.width, rect.height)
        }
    // 没检测到字符框时，退而用文字行的短边估计字号
    let fallbackSides = lines.map { min($0.box.rect.width, $0.box.rect.height) }
    let characterSize = median(characterSides) ?? median(fallbackSides) ?? 20

    return TextAnalysis(lines: lines, regions: regions, characterSize: characterSize)
}

func printSupportedLanguages() {
    let request = RecognizeTextRequest()
    print("Vision 文字识别支持的语言：")
    for language in request.supportedRecognitionLanguages {
        print("  \(language.maximalIdentifier)")
    }
}

private func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}
