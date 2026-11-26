import Cocoa

/// Студийное окно пакетного переименования с живым предпросмотром «Было → Станет».
///
/// Поддерживает 4 режима:
/// 1) Найти и заменить (с опцией учёта регистра)
/// 2) Шаблон и нумерация (`{name}`, `{n}`, `{01}`, `{001}`, `{date}`)
/// 3) Префикс / Суффикс (расширения файлов сохраняются)
/// 4) Регистр и очистка пробелов/подчёркиваний
final class FPBatchRenameController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Mode: Int, CaseIterable {
        case replace = 0
        case template = 1
        case affix = 2
        case transform = 3

        var title: String {
            switch self {
            case .replace: return "Замена"
            case .template: return "Шаблон"
            case .affix: return "Префикс / Суффикс"
            case .transform: return "Регистр"
            }
        }
    }

    enum TextTransform: Int, CaseIterable {
        case lower = 0
        case upper = 1
        case title = 2
        case spacesToUnderscores = 3
        case underscoresToSpaces = 4

        var title: String {
            switch self {
            case .lower: return "нижний регистр"
            case .upper: return "ВЕРХНИЙ РЕГИСТР"
            case .title: return "Как В Заголовках"
            case .spacesToUnderscores: return "Пробелы → _"
            case .underscoresToSpaces: return "_ → пробелы"
            }
        }
    }

    struct PreviewRow {
        let item: FileItem
        let newName: String
        let destination: URL
        let changed: Bool
        let error: String?
    }

    private let targets: [FileItem]
    private let onApply: ([(item: FileItem, destination: URL)]) -> Void

    private let modeControl = NSSegmentedControl(
        labels: Mode.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let controlsHost = NSView()
    private let previewTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let applyButton = NSButton()
    private let cancelButton = NSButton()

    // Поля режима 1: Замена
    private let findField = NSTextField(string: "")
    private let replaceField = NSTextField(string: "")
    private let caseSensitiveCheck = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)

    // Поля режима 2: Шаблон
    private let templateField = NSTextField(string: "{name}_{001}")
    private let startNumberField = NSTextField(string: "1")

    // Поля режима 3: Префикс / Суффикс
    private let prefixField = NSTextField(string: "")
    private let suffixField = NSTextField(string: "")

    // Поля режима 4: Регистр / Очистка
    private let transformPopup = NSPopUpButton()

    private var previewRows: [PreviewRow] = []
    private var currentMode: Mode = .replace
    private var activeFormView: NSView?

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(items: [FileItem], onApply: @escaping ([(item: FileItem, destination: URL)]) -> Void) {
        self.targets = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.onApply = onApply

        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Пакетное переименование"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 540, height: 390)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
        selectMode(.replace)
        recomputePreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(over parentWindow: NSWindow?) {
        showWindow(nil)
        if let parentWindow {
            let pf = parentWindow.frame
            if let w = window {
                let x = pf.midX - w.frame.width / 2
                let y = pf.midY - w.frame.height / 2
                w.setFrameOrigin(NSPoint(x: x, y: y))
            }
        } else {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(findField)
    }

    private func buildUI() {
        guard let window else { return }
        let root = FPAuxiliaryBackdrop(frame: window.contentRect(forFrameRect: window.frame))
        root.translatesAutoresizingMaskIntoConstraints = true
        window.contentView = root

        let headerTitle = NSTextField(labelWithString: "Пакетное переименование")
        headerTitle.font = FPStyle.displayFont(ofSize: 17, weight: .semibold)
        headerTitle.textColor = FPStyle.text
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        let countBadge = NSTextField(labelWithString: "\(targets.count) объектов")
        countBadge.font = FPStyle.monoMetaFont(ofSize: 10.8, weight: .medium)
        countBadge.textColor = FPStyle.dimText
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [headerTitle, countBadge, NSView()])
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        modeControl.selectedSegment = 0
        modeControl.segmentStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        controlsHost.translatesAutoresizingMaskIntoConstraints = false

        configureTextField(findField, placeholder: "Что найти в имени…")
        configureTextField(replaceField, placeholder: "На что заменить (можно пусто)…")
        caseSensitiveCheck.target = self
        caseSensitiveCheck.action = #selector(inputDidChange(_:))
        caseSensitiveCheck.font = FPStyle.bodyFont(ofSize: 11.8, weight: .medium)

        configureTextField(templateField, placeholder: "{name}_{001}")
        configureTextField(startNumberField, placeholder: "1")
        startNumberField.widthAnchor.constraint(equalToConstant: 72).isActive = true

        configureTextField(prefixField, placeholder: "Например: SC21_")
        configureTextField(suffixField, placeholder: "Например: _final")

        transformPopup.removeAllItems()
        for t in TextTransform.allCases {
            transformPopup.addItem(withTitle: t.title)
        }
        transformPopup.target = self
        transformPopup.action = #selector(inputDidChange(_:))

        // Таблица живого превью «Было → Станет»
        let oldCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("old"))
        oldCol.title = "Исходное имя"
        oldCol.width = 270
        oldCol.resizingMask = .autoresizingMask

        let arrowCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("arrow"))
        arrowCol.title = ""
        arrowCol.width = 24
        arrowCol.minWidth = 24
        arrowCol.maxWidth = 24

        let newCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
        newCol.title = "Новое имя"
        newCol.width = 285
        newCol.resizingMask = .autoresizingMask

        previewTable.addTableColumn(oldCol)
        previewTable.addTableColumn(arrowCol)
        previewTable.addTableColumn(newCol)
        previewTable.headerView = QyvroTableHeaderView()
        previewTable.backgroundColor = .clear
        previewTable.rowHeight = 26
        previewTable.usesAlternatingRowBackgroundColors = false
        previewTable.selectionHighlightStyle = .none
        previewTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        previewTable.dataSource = self
        previewTable.delegate = self

        let tableContainer = FPLayerView(
            color: NSColor(calibratedWhite: 0.02, alpha: 0.44),
            cornerRadius: 12,
            borderColor: FPStyle.stroke.withAlphaComponent(0.75),
            borderWidth: 0.75
        )
        let scroll = NSScrollView()
        scroll.documentView = previewTable
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scroll)

        statusLabel.font = FPStyle.bodyFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = FPStyle.dimText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.title = "Отмена"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        applyButton.title = "Переименовать"
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyPressed(_:))

        let footerRow = NSStackView(views: [statusLabel, NSView(), cancelButton, applyButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerRow)
        root.addSubview(modeControl)
        root.addSubview(controlsHost)
        root.addSubview(tableContainer)
        root.addSubview(footerRow)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            modeControl.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 12),
            modeControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            modeControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            controlsHost.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            controlsHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            controlsHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            tableContainer.topAnchor.constraint(equalTo: controlsHost.bottomAnchor, constant: 12),
            tableContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tableContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tableContainer.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -14),

            scroll.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: tableContainer.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: -4),

            footerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footerRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
    }

    private func configureTextField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = FPStyle.bodyFont(ofSize: 12.5, weight: .regular)
        field.textColor = FPStyle.text
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func formRow(_ label: String, control: NSView, trailing: NSView? = nil) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)
        lbl.textColor = FPStyle.dimText
        lbl.alignment = .right
        lbl.widthAnchor.constraint(equalToConstant: 92).isActive = true
        var views: [NSView] = [lbl, control]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func tokenButton(_ token: String) -> NSButton {
        let btn = NSButton(title: token, target: self, action: #selector(insertTokenPressed(_:)))
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 7
        btn.layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.16).cgColor
        btn.attributedTitle = NSAttributedString(
            string: "  \(token)  ",
            attributes: [
                .font: FPStyle.monoMetaFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: FPStyle.accent
            ]
        )
        btn.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return btn
    }

    private func selectMode(_ mode: Mode) {
        currentMode = mode
        activeFormView?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch mode {
        case .replace:
            stack.addArrangedSubview(formRow("Найти", control: findField, trailing: caseSensitiveCheck))
            stack.addArrangedSubview(formRow("Заменить на", control: replaceField))
        case .template:
            let startLbl = NSTextField(labelWithString: "Старт:")
            startLbl.font = FPStyle.bodyFont(ofSize: 11.5, weight: .medium)
            startLbl.textColor = FPStyle.dimText
            let startGroup = NSStackView(views: [startLbl, startNumberField])
            startGroup.orientation = .horizontal
            startGroup.spacing = 6
            startGroup.alignment = .centerY
            stack.addArrangedSubview(formRow("Шаблон", control: templateField, trailing: startGroup))

            let tokens = ["{name}", "{n}", "{01}", "{001}", "{date}"].map { tokenButton($0) }
            let tokenBar = NSStackView(views: tokens + [NSView()])
            tokenBar.orientation = .horizontal
            tokenBar.spacing = 6
            tokenBar.alignment = .centerY
            stack.addArrangedSubview(formRow("Токены", control: tokenBar))
        case .affix:
            stack.addArrangedSubview(formRow("Префикс", control: prefixField))
            stack.addArrangedSubview(formRow("Суффикс", control: suffixField))
        case .transform:
            stack.addArrangedSubview(formRow("Правило", control: transformPopup))
        }

        controlsHost.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controlsHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlsHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controlsHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controlsHost.bottomAnchor)
        ])
        activeFormView = stack
        recomputePreview()

        let firstField: NSView?
        switch mode {
        case .replace: firstField = findField
        case .template: firstField = templateField
        case .affix: firstField = prefixField
        case .transform: firstField = transformPopup
        }
        if let firstField {
            window?.makeFirstResponder(firstField)
        }
    }

    private func recomputePreview() {
        let fm = FileManager.default
        let sourcePaths = Set(targets.map { $0.url.standardizedFileURL.path })
        let todayStamp = Self.dateStampFormatter.string(from: Date())
        let startNumber = Int(startNumberField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1
        var seenDestinations = Set<String>()
        var rows: [PreviewRow] = []
        rows.reserveCapacity(targets.count)

        for (offset, item) in targets.enumerated() {
            let ext = item.isDirectory ? "" : item.url.pathExtension
            let base = (item.isDirectory || ext.isEmpty)
                ? item.name
                : item.url.deletingPathExtension().lastPathComponent

            var newBase: String
            switch currentMode {
            case .replace:
                let needle = findField.stringValue
                if needle.isEmpty {
                    newBase = base
                } else {
                    let options: String.CompareOptions = caseSensitiveCheck.state == .on ? [] : [.caseInsensitive]
                    newBase = base.replacingOccurrences(of: needle, with: replaceField.stringValue, options: options)
                }
            case .template:
                let tpl = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let num = startNumber + offset
                if tpl.isEmpty {
                    newBase = base
                } else {
                    newBase = tpl
                        .replacingOccurrences(of: "{name}", with: base)
                        .replacingOccurrences(of: "{001}", with: String(format: "%03d", num))
                        .replacingOccurrences(of: "{01}", with: String(format: "%02d", num))
                        .replacingOccurrences(of: "{n}", with: "\(num)")
                        .replacingOccurrences(of: "{date}", with: todayStamp)
                }
            case .affix:
                newBase = prefixField.stringValue + base + suffixField.stringValue
            case .transform:
                let rule = TextTransform(rawValue: transformPopup.indexOfSelectedItem) ?? .lower
                switch rule {
                case .lower: newBase = base.lowercased()
                case .upper: newBase = base.uppercased()
                case .title: newBase = base.capitalized
                case .spacesToUnderscores: newBase = base.replacingOccurrences(of: " ", with: "_")
                case .underscoresToSpaces: newBase = base.replacingOccurrences(of: "_", with: " ")
                }
            }

            newBase = newBase
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let candidateName = (!item.isDirectory && !ext.isEmpty) ? "\(newBase).\(ext)" : newBase
            let dest = item.url.deletingLastPathComponent().appendingPathComponent(candidateName)
            let destPath = dest.standardizedFileURL.path
            let changed = candidateName != item.name

            var errorText: String? = nil
            if newBase.isEmpty {
                errorText = "Пустое имя"
            } else if candidateName.contains("/") {
                errorText = "Символ / запрещён"
            } else if !seenDestinations.insert(destPath.lowercased()).inserted {
                errorText = "Дубликат имени"
            } else if changed, fm.fileExists(atPath: destPath), !sourcePaths.contains(destPath) {
                errorText = "Уже существует"
            }

            rows.append(PreviewRow(
                item: item,
                newName: candidateName,
                destination: dest,
                changed: changed,
                error: errorText
            ))
        }

        previewRows = rows
        previewTable.reloadData()

        let changedCount = rows.filter(\.changed).count
        let errorRows = rows.filter { $0.error != nil }
        if let firstErr = errorRows.first, let msg = firstErr.error {
            statusLabel.stringValue = "Конфликт (\(errorRows.count)): \(msg) — «\(firstErr.newName)»"
            statusLabel.textColor = NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.44, alpha: 1)
            applyButton.isEnabled = false
            applyButton.title = "Переименовать"
        } else if changedCount == 0 {
            statusLabel.stringValue = "Введите параметры — превью обновится сразу"
            statusLabel.textColor = FPStyle.dimText
            applyButton.isEnabled = false
            applyButton.title = "Переименовать"
        } else {
            statusLabel.stringValue = "Будет переименовано: \(changedCount) из \(rows.count) (отменяется ⌘Z)"
            statusLabel.textColor = FPStyle.accent
            applyButton.isEnabled = true
            applyButton.title = "Переименовать \(changedCount)"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        recomputePreview()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard let mode = Mode(rawValue: sender.selectedSegment) else { return }
        selectMode(mode)
    }

    @objc private func inputDidChange(_ sender: Any?) {
        recomputePreview()
    }

    @objc private func insertTokenPressed(_ sender: NSButton) {
        let token = sender.title.trimmingCharacters(in: .whitespaces)
        templateField.stringValue += token
        recomputePreview()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        close()
    }

    @objc private func applyPressed(_ sender: Any?) {
        guard previewRows.allSatisfy({ $0.error == nil }) else { NSSound.beep(); return }
        let pairs = previewRows
            .filter(\.changed)
            .map { (item: $0.item, destination: $0.destination) }
        guard !pairs.isEmpty else { return }
        close()
        onApply(pairs)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { previewRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previewRows.indices.contains(row), let colID = tableColumn?.identifier.rawValue else { return nil }
        let entry = previewRows[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        switch colID {
        case "old":
            label.stringValue = entry.item.name
            label.font = FPStyle.bodyFont(ofSize: 11.8, weight: .regular)
            label.textColor = entry.changed ? FPStyle.dimText : FPStyle.dimText.withAlphaComponent(0.55)
        case "arrow":
            label.stringValue = entry.changed ? "→" : "·"
            label.alignment = .center
            label.font = FPStyle.monoMetaFont(ofSize: 11, weight: .semibold)
            label.textColor = entry.error != nil
                ? NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.44, alpha: 1)
                : (entry.changed ? FPStyle.accent : FPStyle.dimText.withAlphaComponent(0.35))
        default:
            label.stringValue = entry.error != nil ? "\(entry.newName)  [\(entry.error!)]" : entry.newName
            label.font = FPStyle.bodyFont(ofSize: 11.8, weight: entry.changed ? .medium : .regular)
            label.textColor = entry.error != nil
                ? NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.44, alpha: 1)
                : (entry.changed ? FPStyle.text : FPStyle.dimText.withAlphaComponent(0.55))
        }

        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
