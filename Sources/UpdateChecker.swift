import Cocoa

/// Silent, user-initiated GitHub Releases update checker (zero background telemetry).
final class QyvroUpdateChecker {
    static let shared = QyvroUpdateChecker()

    struct ReleaseInfo {
        let version: String
        let tagName: String
        let title: String
        let htmlURL: URL
        let notes: String
    }

    enum CheckResult {
        case updateAvailable(ReleaseInfo)
        case upToDate(currentVersion: String)
        case failed(String)
    }

    private let releasesAPIURL = URL(string: "https://api.github.com/repos/MarkiHaval/qyvro/releases/latest")!
    private let releasesPageURL = URL(string: "https://github.com/MarkiHaval/qyvro/releases")!
    private var isChecking = false

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.0"
    }

    func checkForUpdates(interactive: Bool = true, completion: ((CheckResult) -> Void)? = nil) {
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: releasesAPIURL)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Qyvro/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let result: CheckResult
            if let error {
                result = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failed("HTTP \(http.statusCode)")
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let remoteVersion = Self.cleanVersion(tag)
                let htmlString = (json["html_url"] as? String) ?? self.releasesPageURL.absoluteString
                let htmlURL = URL(string: htmlString) ?? self.releasesPageURL
                let name = (json["name"] as? String) ?? tag
                let body = (json["body"] as? String) ?? ""
                if Self.isVersion(remoteVersion, newerThan: self.currentVersion) {
                    result = .updateAvailable(ReleaseInfo(
                        version: remoteVersion,
                        tagName: tag,
                        title: name,
                        htmlURL: htmlURL,
                        notes: body
                    ))
                } else {
                    result = .upToDate(currentVersion: self.currentVersion)
                }
            } else {
                result = .failed(L("Не удалось прочитать ответ GitHub.", "Could not parse GitHub response."))
            }

            DispatchQueue.main.async {
                self.isChecking = false
                completion?(result)
                if interactive {
                    self.presentInteractiveResult(result)
                }
            }
        }.resume()
    }

    private func presentInteractiveResult(_ result: CheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch result {
        case .updateAvailable(let info):
            alert.messageText = L(
                "Доступна новая версия Qyvro \(info.version)",
                "Qyvro \(info.version) is available"
            )
            let previewNotes = info.notes
                .split(separator: "\n")
                .prefix(6)
                .joined(separator: "\n")
            alert.informativeText = L(
                "У вас установлена версия \(currentVersion). Новый релиз «\(info.title)» готов к загрузке на GitHub.\n\n\(previewNotes)",
                "You are running \(currentVersion). Release \"\(info.title)\" is ready to download on GitHub.\n\n\(previewNotes)"
            )
            alert.addButton(withTitle: L("Открыть релиз на GitHub", "Open GitHub Release"))
            alert.addButton(withTitle: L("Позже", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(info.htmlURL)
            }
        case .upToDate(let current):
            alert.messageText = L("У вас актуальная версия", "You're up to date")
            alert.informativeText = L(
                "Qyvro \(current) — последняя опубликованная версия.",
                "Qyvro \(current) is the latest published release."
            )
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = L("Не удалось проверить обновления", "Could not check for updates")
            alert.informativeText = message
            alert.addButton(withTitle: L("Открыть GitHub Releases", "Open GitHub Releases"))
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releasesPageURL)
            }
        }
    }

    static func cleanVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = cleanVersion(lhs).split(separator: ".").map { Int($0) ?? 0 }
        let b = cleanVersion(rhs).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for idx in 0..<count {
            let va = idx < a.count ? a[idx] : 0
            let vb = idx < b.count ? b[idx] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
