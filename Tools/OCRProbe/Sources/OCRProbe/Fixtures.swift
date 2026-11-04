import CoreGraphics
import CoreText
import Foundation
import MangaCore

/// 生成合成测试页（日漫竖排气泡、韩漫横排气泡、条漫长图），没有真实样本时用来自测
func makeFixtures(in directory: URL) throws {
    let japanese = directory.appendingPathComponent("ja/synthetic-vertical.png")
    try drawPage(width: 1000, height: 1400, to: japanese) { canvas in
        canvas.panel(CGRect(x: 40, y: 40, width: 920, height: 640))
        canvas.panel(CGRect(x: 40, y: 720, width: 920, height: 640))
        canvas.bubble(CGRect(x: 540, y: 80, width: 360, height: 480),
                      "なんだって！？そんなはずはない", font: "HiraginoSans-W6", size: 42, vertical: true)
        canvas.bubble(CGRect(x: 110, y: 200, width: 300, height: 420),
                      "まさか…本当に来るとは", font: "HiraginoSans-W6", size: 38, vertical: true)
        canvas.caption(CGRect(x: 70, y: 750, width: 430, height: 80),
                       "その頃、東京では――", font: "HiraginoMinchoProN-W3", size: 34)
        canvas.bubble(CGRect(x: 560, y: 860, width: 340, height: 460),
                      "ここは俺に任せて先に行け！", font: "HiraginoSans-W6", size: 40, vertical: true)
    }

    let korean = directory.appendingPathComponent("ko/synthetic-horizontal.png")
    try drawPage(width: 800, height: 1400, to: korean) { canvas in
        canvas.panel(CGRect(x: 30, y: 30, width: 740, height: 1340))
        canvas.bubble(CGRect(x: 90, y: 90, width: 620, height: 260),
                      "정말이야? 믿을 수가 없어!", font: "AppleSDGothicNeo-Bold", size: 44, vertical: false)
        canvas.bubble(CGRect(x: 140, y: 480, width: 520, height: 240),
                      "내가 거짓말할 것 같아?", font: "AppleSDGothicNeo-Bold", size: 40, vertical: false)
        canvas.caption(CGRect(x: 70, y: 900, width: 660, height: 110),
                       "그날 밤, 모든 것이 바뀌었다.", font: "AppleSDGothicNeo-Regular", size: 36)
    }

    // 条漫长图：800×4000，会被切成 5 段；第 2～5 个气泡都跨过上一段的切口，用来检查切段去重
    let long = directory.appendingPathComponent("ko/synthetic-long.png")
    try drawPage(width: 800, height: 4000, to: long) { canvas in
        canvas.panel(CGRect(x: 30, y: 30, width: 740, height: 1900))
        canvas.panel(CGRect(x: 30, y: 2000, width: 740, height: 1970))
        canvas.bubble(CGRect(x: 150, y: 200, width: 500, height: 220),
                      "오늘은 날씨가 정말 좋네.", font: "AppleSDGothicNeo-Bold", size: 40, vertical: false)
        canvas.bubble(CGRect(x: 120, y: 1060, width: 560, height: 240),
                      "이 말풍선은 경계에 걸쳐 있어.", font: "AppleSDGothicNeo-Bold", size: 40, vertical: false)
        canvas.bubble(CGRect(x: 180, y: 1900, width: 480, height: 220),
                      "끝까지 읽어 줘서 고마워.", font: "AppleSDGothicNeo-Bold", size: 38, vertical: false)
        canvas.bubble(CGRect(x: 140, y: 2800, width: 520, height: 220),
                      "다음에 또 만나자!", font: "AppleSDGothicNeo-Bold", size: 40, vertical: false)
        canvas.caption(CGRect(x: 160, y: 3600, width: 480, height: 110),
                       "다음 화에 계속", font: "AppleSDGothicNeo-Regular", size: 36)
    }

    print("已生成测试页：\n  \(japanese.path)\n  \(korean.path)\n  \(long.path)")
}

private func drawPage(width: Int, height: Int, to url: URL, _ draw: (Canvas) -> Void) throws {
    let context = try makeContext(width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(Canvas(context: context, pageHeight: CGFloat(height)))
    guard let image = context.makeImage() else { throw ProbeError("生成测试页失败") }
    try writeImage(image, to: url, format: .png)
}

/// 以左上角为原点的简易画布
private struct Canvas {
    let context: CGContext
    let pageHeight: CGFloat

    private var black: CGColor { CGColor(gray: 0, alpha: 1) }
    private var white: CGColor { CGColor(gray: 1, alpha: 1) }

    func panel(_ rect: CGRect) {
        context.setStrokeColor(black)
        context.setLineWidth(5)
        context.stroke(flipped(rect, pageHeight: pageHeight))
    }

    /// 椭圆气泡，文字放在内切区域里
    func bubble(_ rect: CGRect, _ text: String, font: String, size: CGFloat, vertical: Bool) {
        let shape = flipped(rect, pageHeight: pageHeight)
        context.setFillColor(white)
        context.fillEllipse(in: shape)
        context.setStrokeColor(black)
        context.setLineWidth(4)
        context.strokeEllipse(in: shape)
        draw(text, in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.14),
             font: font, size: size, vertical: vertical)
    }

    /// 方框旁白，横排
    func caption(_ rect: CGRect, _ text: String, font: String, size: CGFloat) {
        let shape = flipped(rect, pageHeight: pageHeight)
        context.setFillColor(white)
        context.fill(shape)
        context.setStrokeColor(black)
        context.setLineWidth(3)
        context.stroke(shape)
        draw(text, in: rect.insetBy(dx: 16, dy: 14), font: font, size: size, vertical: false)
    }

    private func draw(_ text: String, in rect: CGRect, font: String, size: CGFloat, vertical: Bool) {
        let string = attributedText(text, fontName: font, size: size, color: black, vertical: vertical)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: flipped(rect, pageHeight: pageHeight), transform: nil)
        let frameAttributes = vertical ? verticalFrameAttributes() : nil
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, frameAttributes)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}
