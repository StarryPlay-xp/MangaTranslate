import CoreGraphics
import Foundation
import MangaCore

func writeImage(_ image: CGImage, to url: URL, format: ImageFormat) throws {
    try writeFile(encodeImage(image, format: format), to: url)
}

func writeFile(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
