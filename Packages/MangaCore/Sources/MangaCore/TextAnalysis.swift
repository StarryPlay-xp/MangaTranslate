import CoreGraphics
import Foundation
import Vision

/// 像素坐标框，原点在图片左上角
public struct Box: Codable, Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(_ rect: CGRect) {
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Vision 识别出的一行（竖排时是一列）文字
public struct TextLine: Codable, Sendable {
    public var text: String
    public var confidence: Double
    public var box: Box
}

public struct TextAnalysis: Sendable {
    /// 识别出内容的文字行
    public var lines: [TextLine]
    /// 检测到的文字区域，与语言无关，认不出字的地方也会有
    public var regions: [CGRect]
    /// 单个字符边长的中位数，用来决定合并文字块时的间距
    public var characterSize: CGFloat
}

public func analyzeText(in image: CGImage, languages: [String]) async throws -> TextAnalysis {
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

/// 识别并合并成按阅读顺序编号的文字块
public func detectTextBlocks(
    in image: CGImage, language: SourceLanguage, gapFactor: Double = 0.6
) async throws -> (analysis: TextAnalysis, blocks: [TextBlock]) {
    let analysis = try await analyzeText(in: image, languages: language.recognitionLanguages)
    return (analysis, groupIntoBlocks(analysis, gapFactor: gapFactor, order: language.readingOrder))
}

public func supportedRecognitionLanguages() -> [String] {
    RecognizeTextRequest().supportedRecognitionLanguages.map(\.maximalIdentifier)
}

private func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
}
