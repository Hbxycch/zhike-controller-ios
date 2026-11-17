import Foundation
import UIKit

/// 检查 GitHub Release 是否有新版本。
///
/// CI 在每次推送后会把未签名 ipa 发布为 Release（tag 形如 v1.1-b5），
/// App 通过公开的 releases/latest 接口拿最新 tag，比较构建号。
/// 有新版时引导用户去 Safari 下载 ipa，再用 Sideloadly/AltStore 覆盖安装。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "Hbxycch/zhike-controller-ios"
    static let releasesURL = "https://github.com/\(repo)/releases/latest"

    enum State: Equatable {
        case idle
        case checking
        case upToDate(currentBuild: Int)
        case available(tag: String, build: Int, notes: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    static var currentVersionText: String { Bundle.main.appVersion }

    /// "v1.1-b5" → 5；解析失败返回 nil
    static func build(fromTag tag: String) -> Int? {
        guard let range = tag.range(of: "-b") else { return nil }
        return Int(tag[range.upperBound...])
    }

    func check() async {
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            state = .failed("内部错误：URL 无效")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                state = .failed("仓库还没有发布过版本")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed("GitHub 接口不可用（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
                return
            }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tag = payload?["tag_name"] as? String else {
                state = .failed("响应格式异常")
                return
            }
            let latestBuild = Self.build(fromTag: tag) ?? 0
            let notes = (payload?["body"] as? String) ?? ""
            if latestBuild > Self.currentBuild {
                state = .available(tag: tag, build: latestBuild, notes: notes)
            } else {
                state = .upToDate(currentBuild: Self.currentBuild)
            }
        } catch {
            state = .failed("网络错误：\(error.localizedDescription)")
        }
    }

    /// 打开 Safari 下载页（ipa 无法在 App 内安装，需要签名工具）
    static func openDownloadPage() {
        if let url = URL(string: releasesURL) {
            UIApplication.shared.open(url)
        }
    }
}
