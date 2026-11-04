import Foundation
import MangaCore
import Observation

/// App 的设置，保存在 UserDefaults；API Key 单独存在钥匙串里，这里只记录有没有
@Observable
final class AppSettings {
    private enum Keys {
        static let sourceLanguage = "sourceLanguage"
        static let sendImage = "sendImage"
        static let dryRun = "dryRun"
    }

    var sourceLanguage: SourceLanguage {
        didSet { UserDefaults.standard.set(sourceLanguage.rawValue, forKey: Keys.sourceLanguage) }
    }
    /// 把带编号框的截图发给模型；关掉后只发识别出的文字
    var sendImage: Bool {
        didSet { UserDefaults.standard.set(sendImage, forKey: Keys.sendImage) }
    }
    /// 试运行：不调用 DeepSeek，直接在原位置显示识别出的原文，用来检查识别效果
    var dryRun: Bool {
        didSet { UserDefaults.standard.set(dryRun, forKey: Keys.dryRun) }
    }
    private(set) var hasAPIKey: Bool

    init() {
        let defaults = UserDefaults.standard
        sourceLanguage = defaults.string(forKey: Keys.sourceLanguage).flatMap(SourceLanguage.init(rawValue:)) ?? .japanese
        sendImage = defaults.object(forKey: Keys.sendImage) as? Bool ?? true
        dryRun = defaults.bool(forKey: Keys.dryRun)
        hasAPIKey = KeychainStore.load() != nil
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try KeychainStore.save(trimmed)
        hasAPIKey = true
    }

    func deleteAPIKey() {
        KeychainStore.delete()
        hasAPIKey = false
    }
}
