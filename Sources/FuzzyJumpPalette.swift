import Cocoa

/// Persistent store of recently visited real directories for instant Fuzzy Jump (`⌘J`).
final class QyvroRecentFoldersStore {
    static let shared = QyvroRecentFoldersStore()

    private let key = "QyvroRecentFolderPaths"
    private let maxEntries = 80
    private var paths: [String] = []

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ url: URL) {
        let normalized = url.standardizedFileURL.path
        guard !normalized.isEmpty else { return }
        paths.removeAll { $0 == normalized }
        paths.insert(normalized, at: 0)
        if paths.count > maxEntries {
            paths.removeLast(paths.count - maxEntries)
        }
        UserDefaults.standard.set(paths, forKey: key)
    }

    func recentURLs() -> [URL] {
        let fm = FileManager.default
        return paths.compactMap { path in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}

/// Studio V4 Fuzzy Folder Jump modal (`⌘J`) — keyboard-first instant navigation
/// across bookmarks, open tabs, recent folders, and nearby subdirectories.
final class QyvroFuzzyJumpController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Candidate {
        enum Source {
            case bookmark
            case openTab
            case recent
            case standard
            case subfolder

            var badge: String {
                switch self {
                case .bookmark: return L("Закладка", "Bookmark")
                case .openTab: return L("Вкладка", "Tab")
                case .recent: return L("Недавняя", "Recent")
                case .standard: return L("Быстрая", "Quick")
                case .subfolder: return L("Папка", "Folder")
                }
            }

            var priorityBonus: Int {
                switch self {
                case .bookmark: return 45
                case .openTab: return 32
                case .recent: return 24
                case .standard: return 16
                case .subfolder: return 8
                }
            }
        }

        let url: URL
        let name: String
        let parentDisplay: String
        let source: Source
        let orderBoost: Int
    }

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "")

    private var allCandidates: [Candidate] = []
    private var filtered: [Candidate] = []
    private var onSelect: ((URL, Bool) -> Void)?
    private var scanGeneration = 0
    private let scanQueue = DispatchQueue(label: "Qyvro.FuzzyJumpScan", qos: .userInitiated)

    init() {
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Быстрый переход", "Fuzzy Jump")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(
        currentFolder: URL,
        openTabURLs: [URL],
        onSelect: @escaping (_ url: URL, _ inNewTab: Bool) -> Void
    ) {
        self.onSelect = onSelect
        window?.title = L("Быстрый переход", "Fuzzy Jump")
        searchField.placeholderString = L(
            "Перейти в папку… (например: sc21, down, code)",
            "Jump to folder… (e.g. down, docs, project)"
        )
        hintLabel.stringValue = L(
            "↑↓ выбор   ·   ↵ открыть   ·   ⌘↵ в новой вкладке   ·   Esc закрыть",
            "↑↓ navigate   ·   ↵ open   ·   ⌘↵ new tab   ·   Esc close"
        )
        (window?.contentView as? FPAuxiliaryBackdrop)?.applyTheme()
        applyTheme()

        searchField.stringValue = ""
        allCandidates = buildImmediateCandidates(currentFolder: currentFolder, openTabURLs: openTabURLs)
        updateFilter()

        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(searchField)

        scanGeneration += 1
        let gen = scanGeneration
        let existingPaths = Set(allCandidates.map { $0.url.standardizedFileURL.path })
        scanQueue.async { [weak self] in
            let extra = Self.discoverNearbySubfolders(currentFolder: currentFolder, excluding: existingPaths)
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == gen, self.window?.isVisible == true else { return }
                self.allCandidates.append(contentsOf: extra)
                self.updateFilter()
            }
        }
    }

    private func buildUI() {
        guard let window else { return }
        let root = FPAuxiliaryBackdrop(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = root

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = FPStyle.headingFont(ofSize: 16, weight: .medium)
        searchField.textColor = FPStyle.text
        searchField.delegate = self

        let searchWrap = FPLayerView(color: FPStyle.control, cornerRadius: 11, borderColor: FPStyle.stroke, borderWidth: 1)
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: nil)
        iconView.contentTintColor = FPStyle.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false

        searchWrap.addSubview(iconView)
        searchWrap.addSubview(searchField)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        col.width = 540
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.selectionHighlightStyle = .regular

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = FPStyle.monoMetaFont(ofSize: 10.2, weight: .medium)
        hintLabel.textColor = FPStyle.dimText
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchWrap)
        root.addSubview(scrollView)
        root.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            searchWrap.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            searchWrap.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchWrap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchWrap.heightAnchor.constraint(equalToConstant: 42),

            iconView.leadingAnchor.constraint(equalTo: searchWrap.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchWrap.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchWrap.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: searchWrap.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            hintLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func applyTheme() {
        searchField.textColor = FPStyle.text
        hintLabel.textColor = FPStyle.dimText
        tableView.reloadData()
    }

    private func buildImmediateCandidates(currentFolder: URL, openTabURLs: [URL]) -> [Candidate] {
        var result: [Candidate] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL

        func append(_ url: URL, source: Candidate.Source, orderBoost: Int) {
            let std = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue else { return }
            guard seen.insert(std.path).inserted else { return }
            let name = std.lastPathComponent.isEmpty ? "/" : std.lastPathComponent
            let parent = std.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
            result.append(Candidate(url: std, name: name, parentDisplay: parent, source: source, orderBoost: orderBoost))
        }

        let bookmarkPaths = UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? []
        for (i, path) in bookmarkPaths.enumerated() {
            append(URL(fileURLWithPath: path, isDirectory: true), source: .bookmark, orderBoost: max(0, 30 - i))
        }
        for (i, url) in openTabURLs.enumerated() {
            append(url, source: .openTab, orderBoost: max(0, 20 - i))
        }
        for (i, url) in QyvroRecentFoldersStore.shared.recentURLs().enumerated() {
            append(url, source: .recent, orderBoost: max(0, 40 - i))
        }
        let standard: [URL] = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Movies"),
            home.appendingPathComponent("Projects"),
            home.appendingPathComponent("Documents/Code"),
            URL(fileURLWithPath: "/Applications"),
            home
        ]
        for (i, url) in standard.enumerated() {
            append(url, source: .standard, orderBoost: max(0, 12 - i))
        }
        // Also immediate children of current folder synchronously (capped at 40).
        if let kids = try? fm.contentsOfDirectory(
            at: currentFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            var added = 0
            for kid in kids {
                guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !kid.pathExtension.lowercased().hasSuffix("app") else { continue }
                append(kid, source: .subfolder, orderBoost: 15)
                added += 1
                if added >= 40 { break }
            }
        }
        return result
    }

    private static func discoverNearbySubfolders(currentFolder: URL, excluding: Set<String>) -> [Candidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        let roots: [(URL, Int)] = [
            (currentFolder, 2),
            (home.appendingPathComponent("Documents"), 2),
            (home.appendingPathComponent("Downloads"), 1),
            (home.appendingPathComponent("Desktop"), 1),
            (home.appendingPathComponent("Projects"), 2),
            (home.appendingPathComponent("Pictures"), 1)
        ]
        var seen = excluding
        var found: [Candidate] = []
        let skipNames: Set<String> = ["node_modules", ".git", "build", "DerivedData", ".build", "Pods", "venv", ".venv"]

        func walk(_ dir: URL, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth, found.count < 260 else { return }
            guard let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls {
                guard found.count < 260 else { break }
                let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard vals?.isDirectory == true, vals?.isPackage != true else { continue }
                let name = url.lastPathComponent
                guard !skipNames.contains(name) else { continue }
                let std = url.standardizedFileURL
                if seen.insert(std.path).inserted {
                    let parent = std.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~")
                    found.append(Candidate(url: std, name: name, parentDisplay: parent, source: .subfolder, orderBoost: max(0, 6 - depth * 2)))
                }
                if depth < maxDepth {
                    walk(std, depth: depth + 1, maxDepth: maxDepth)
                }
            }
        }

        for (root, maxDepth) in roots where fm.fileExists(atPath: root.path) {
            walk(root, depth: 1, maxDepth: maxDepth)
        }
        return found
    }

    static func fuzzyScore(query: String, candidate: Candidate) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return candidate.source.priorityBonus * 10 + candidate.orderBoost
        }
        let nameLower = candidate.name.lowercased()
        let pathLower = "\(candidate.parentDisplay)/\(candidate.name)".lowercased()

        // Fast direct substring match on folder name gets highest weight.
        if let range = nameLower.range(of: q) {
            let prefixBonus = range.lowerBound == nameLower.startIndex ? 260 : 140
            let lengthPenalty = max(0, nameLower.count - q.count)
            return 1000 + prefixBonus - lengthPenalty + candidate.source.priorityBonus * 4 + candidate.orderBoost
        }
        if let score = subsequenceScore(needle: q, haystack: nameLower) {
            return 600 + score + candidate.source.priorityBonus * 3 + candidate.orderBoost
        }
        if let score = subsequenceScore(needle: q, haystack: pathLower) {
            return 220 + score + candidate.source.priorityBonus * 2 + candidate.orderBoost
        }
        return nil
    }

    private static func subsequenceScore(needle: String, haystack: String) -> Int? {
        let nChars = Array(needle)
        let hChars = Array(haystack)
        guard !nChars.isEmpty, nChars.count <= hChars.count else { return nil }
        var ni = 0
        var score = 0
        var consecutive = 0
        let separators: Set<Character> = ["/", "_", "-", " ", "."]
        for (hi, ch) in hChars.enumerated() {
            if ch == nChars[ni] {
                score += 12 + consecutive * 10
                if hi == 0 || separators.contains(hChars[hi - 1]) {
                    score += 18
                }
                consecutive += 1
                ni += 1
                if ni == nChars.count {
                    return score - (hChars.count - nChars.count)
                }
            } else {
                consecutive = 0
            }
        }
        return nil
    }

    private func updateFilter() {
        let query = searchField.stringValue
        filtered = allCandidates
            .compactMap { item -> (Candidate, Int)? in
                guard let score = Self.fuzzyScore(query: query, candidate: item) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(80)
            .map(\.0)
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            commitSelection(inNewTab: newTab)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        if current < 0 {
            next = delta > 0 ? 0 : filtered.count - 1
        } else {
            next = max(0, min(filtered.count - 1, current + delta))
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
        commitSelection(inNewTab: newTab)
    }

    private func commitSelection(inNewTab: Bool) {
        let row = tableView.selectedRow
        let index = (row >= 0 && row < filtered.count) ? row : 0
        guard filtered.indices.contains(index) else { return }
        let chosen = filtered[index]
        close()
        onSelect?(chosen.url, inNewTab)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let item = filtered[row]
        let cellID = NSUserInterfaceItemIdentifier("FuzzyJumpCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            v.identifier = cellID

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.tag = 1

            let title = NSTextField(labelWithString: "")
            title.font = FPStyle.bodyFont(ofSize: 13, weight: .semibold)
            title.lineBreakMode = .byTruncatingMiddle
            title.translatesAutoresizingMaskIntoConstraints = false
            title.tag = 2

            let sub = NSTextField(labelWithString: "")
            sub.font = FPStyle.monoMetaFont(ofSize: 10.2, weight: .regular)
            sub.lineBreakMode = .byTruncatingHead
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.tag = 3

            let badge = NSTextField(labelWithString: "")
            badge.font = FPStyle.monoMetaFont(ofSize: 9.5, weight: .semibold)
            badge.alignment = .right
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.tag = 4

            v.addSubview(icon)
            v.addSubview(title)
            v.addSubview(sub)
            v.addSubview(badge)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24),

                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: v.topAnchor, constant: 5),

                sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                sub.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),

                badge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: v.centerYAnchor)
            ])
            return v
        }()

        if let icon = cell.viewWithTag(1) as? NSImageView {
            icon.image = FPFolderIconRenderer.icon(color: FPStyle.defaultFolder, size: 24)
        }
        if let title = cell.viewWithTag(2) as? NSTextField {
            title.stringValue = item.name
            title.textColor = FPStyle.text
        }
        if let sub = cell.viewWithTag(3) as? NSTextField {
            sub.stringValue = item.parentDisplay
            sub.textColor = FPStyle.dimText
        }
        if let badge = cell.viewWithTag(4) as? NSTextField {
            badge.stringValue = item.source.badge
            badge.textColor = item.source == .bookmark ? FPStyle.orange : FPStyle.dimText
        }
        return cell
    }
}
