import Cocoa

/// Окно переименования файла.
///
/// Прежде здесь был системный `NSAlert` с прикреплённым полем: он не
/// поддаётся оформлению, оставляет много пустого места и выглядит чужим
/// рядом с остальным интерфейсом. Своё окно решает и то, и другое, а
/// заодно даёт мелочи, которых у диалога не было: расширение не выделяется,
/// имя проверяется по ходу набора, Esc отменяет.
final class FPRenameSheet: NSObject, NSTextFieldDelegate {
    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 176),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    private let backdrop = NSVisualEffectView()
    /// Тёмная основа под градиентом. Без неё градиент темы работал не тоном,
    /// а всем фоном — окно уходило в лиловый и выпадало из оформления.
    private let base = FPLayerView(color: .clear)
    private let gradient = FPBackgroundGradientView()
    private let fieldBox = FPLayerView(color: .clear, cornerRadius: 9)
    private let heading = NSTextField(labelWithString: "ПЕРЕИМЕНОВАТЬ")
    private let currentName = NSTextField(labelWithString: "")
    private let field = NSTextField(string: "")
    private let hint = NSTextField(labelWithString: "")
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()
    private var completion: ((String?) -> Void)?
    private var originalName = ""

    override init() {
        super.init()
        buildLayout()
    }

    private func buildLayout() {
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let content = NSView(frame: panel.contentLayoutRect)
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        gradient.translatesAutoresizingMaskIntoConstraints = false

        heading.font = FPStyle.headingFont(ofSize: 13, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        currentName.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        currentName.lineBreakMode = .byTruncatingMiddle
        currentName.translatesAutoresizingMaskIntoConstraints = false
        currentName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.font = FPStyle.bodyFont(ofSize: 14, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle

        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.layer?.borderWidth = 1

        hint.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        hint.translatesAutoresizingMaskIntoConstraints = false

        for (button, title) in [(confirmButton, "Переименовать"), (cancelButton, "Отмена")] {
            button.title = title
            button.isBordered = false
            button.bezelStyle = .inline
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        confirmButton.action = #selector(confirm)
        cancelButton.action = #selector(cancel)
        // Enter подтверждает, Esc отменяет — как в системных диалогах.
        confirmButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"

        content.addSubview(backdrop)
        content.addSubview(base)
        content.addSubview(gradient)
        content.addSubview(heading)
        content.addSubview(currentName)
        content.addSubview(fieldBox)
        fieldBox.addSubview(field)
        content.addSubview(hint)
        content.addSubview(cancelButton)
        content.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            base.topAnchor.constraint(equalTo: content.topAnchor),
            base.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            base.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            base.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            gradient.topAnchor.constraint(equalTo: content.topAnchor),
            gradient.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            gradient.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gradient.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            currentName.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 10),
            currentName.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            currentName.firstBaselineAnchor.constraint(equalTo: heading.firstBaselineAnchor),

            fieldBox.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            fieldBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            fieldBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fieldBox.heightAnchor.constraint(equalToConstant: 38),
            field.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),

            hint.topAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            confirmButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            confirmButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            confirmButton.widthAnchor.constraint(equalToConstant: 150),
            cancelButton.trailingAnchor.constraint(equalTo: confirmButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: confirmButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 90)
        ])
        panel.contentView = content
        applyTheme()
        // Окно должно перекрашиваться вместе со всем остальным, а не
        // оставаться в цветах той темы, при которой было создано.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: .fpThemeDidChange,
            object: nil
        )
    }

    @objc private func themeChanged() {
        applyTheme()
    }

    private func applyTheme() {
        let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
        // Те же значения, что у окна проводника: градиент читается тоном
        // поверх тёмной основы, а не заливает окно целиком.
        let gradientOpacity = min(0.75, 0.50 + opacity * 0.25)
        base.setColor(FPStyle.window.withAlphaComponent(0.92))
        gradient.setColors(
            FPStyle.gradientEnabled
                ? [
                    FPStyle.gradientStart.withAlphaComponent(gradientOpacity),
                    FPStyle.gradientEnd.withAlphaComponent(gradientOpacity)
                ]
                : [
                    FPStyle.window.withAlphaComponent(gradientOpacity),
                    FPStyle.window.withAlphaComponent(gradientOpacity)
                ]
        )
        heading.textColor = FPStyle.text
        currentName.textColor = FPStyle.dimText
        hint.textColor = FPStyle.dimText.withAlphaComponent(0.7)
        field.textColor = FPStyle.text
        fieldBox.layer?.backgroundColor = FPStyle.control.cgColor
        fieldBox.layer?.borderColor = FPStyle.stroke.withAlphaComponent(0.9).cgColor
        // Главная кнопка в акцентном цвете темы, а не в оранжевом: акцент —
        // это то, чем окрашены действия во всём приложении.
        confirmButton.layer?.backgroundColor = FPStyle.accent.cgColor
        confirmButton.layer?.borderWidth = 0
        confirmButton.attributedTitle = NSAttributedString(
            string: "Переименовать",
            attributes: [
                .font: FPStyle.headingFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.88)
            ]
        )
        cancelButton.layer?.backgroundColor = FPStyle.control.cgColor
        cancelButton.layer?.borderColor = FPStyle.stroke.withAlphaComponent(0.8).cgColor
        cancelButton.layer?.borderWidth = 1
        cancelButton.attributedTitle = NSAttributedString(
            string: "Отмена",
            attributes: [
                .font: FPStyle.headingFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: FPStyle.text
            ]
        )
    }

    /// Показывает окно как лист над проводником.
    func present(name: String, over window: NSWindow, completion: @escaping (String?) -> Void) {
        applyTheme()
        self.completion = completion
        originalName = name
        currentName.stringValue = name
        field.stringValue = name
        hint.stringValue = ""

        window.beginSheet(panel) { _ in }
        panel.makeFirstResponder(field)
        // Выделяется только имя без расширения: менять обычно надо именно
        // его, а точку с расширением человек всё равно вернул бы руками.
        if let editor = field.currentEditor() {
            let base = (name as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ошибка показывается по ходу набора, а не после нажатия: иначе
        // человек узнаёт о косой черте в имени, только потеряв ввод.
        if value.isEmpty {
            hint.stringValue = "ИМЯ НЕ МОЖЕТ БЫТЬ ПУСТЫМ"
            confirmButton.isEnabled = false
        } else if value.contains("/") {
            hint.stringValue = "КОСАЯ ЧЕРТА В ИМЕНИ НЕДОПУСТИМА"
            confirmButton.isEnabled = false
        } else if value.hasPrefix(".") {
            hint.stringValue = "ИМЯ С ТОЧКИ СКРОЕТ ФАЙЛ"
            confirmButton.isEnabled = true
        } else {
            hint.stringValue = ""
            confirmButton.isEnabled = true
        }
    }

    @objc private func confirm() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/") else { return }
        finish(value == originalName ? nil : value)
    }

    @objc private func cancel() {
        finish(nil)
    }

    private func finish(_ result: String?) {
        guard let sheetParent = panel.sheetParent else { return }
        sheetParent.endSheet(panel)
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}
