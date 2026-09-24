import AppKit
import CodexModelBarCore

/// The floating strip itself.
///
/// It is a **non-activating panel**: clicking a button does not make this app active,
/// so Codex keeps keyboard focus while the switcher operates its model menu.
final class BarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: BarView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        // Floating keeps it above Codex; we hide it whenever Codex is not frontmost,
        // so it never floats over other apps.
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false        // we are never "active"; visibility is managed by AppController
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        // Follow the user across Spaces and sit beside full-screen windows; the tracker
        // hides us when the Codex window is not on the current Space anyway.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none        // instant follow while dragging, no fade lag
    }

    // Never take keyboard focus away from Codex.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Content of the strip: a translucent background with one button per model, plus a
/// short status line on the right for errors and the Accessibility hint.
final class BarView: NSVisualEffectView {
    static let height: CGFloat = 30

    /// Called when a model button is clicked.
    var onSelect: ((CodexModel) -> Void)?
    /// Called when a reasoning tick is chosen.
    var onSelectEffort: ((String) -> Void)?
    /// Called when the status text is clicked (used for "Allow Accessibility access").
    var onStatusClick: (() -> Void)?
    /// Repositions the panel when a status message changes its required width.
    var onSizeChange: (() -> Void)?
    /// Supplies the right-click menu.
    var menuProvider: (() -> NSMenu)?

    private let stack = NSStackView()
    private let contentStack = NSStackView()
    private let reasoningLabel = NSTextField(labelWithString: "Reasoning —")
    private let reasoningSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let separator = NSBox()
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private var buttons: [String: ModelButton] = [:]
    private var models: [CodexModel] = []
    private var catalogModels: [CodexModel] = []
    private var currentModelID: String?
    private var currentEffort: String?
    private var busyReasoning = false
    private var busyModelID: String?
    private var statusHideWork: DispatchWorkItem?

    var currentModelIdentifier: String? { currentModelID }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        contentStack.orientation = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        contentStack.addArrangedSubview(stack)

        separator.boxType = .separator
        NSLayoutConstraint.activate([separator.widthAnchor.constraint(equalToConstant: 1),
                                     separator.heightAnchor.constraint(equalToConstant: 17)])
        contentStack.addArrangedSubview(separator)

        reasoningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        reasoningLabel.textColor = .secondaryLabelColor
        reasoningLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(reasoningLabel)

        reasoningSlider.numberOfTickMarks = 2
        reasoningSlider.allowsTickMarkValuesOnly = true
        reasoningSlider.tickMarkPosition = .below
        reasoningSlider.isContinuous = false
        reasoningSlider.target = self
        reasoningSlider.action = #selector(effortClicked(_:))
        reasoningSlider.toolTip = "Choose reasoning effort"
        reasoningSlider.setAccessibilityLabel("Reasoning effort")
        reasoningSlider.widthAnchor.constraint(equalToConstant: 122).isActive = true
        contentStack.addArrangedSubview(reasoningSlider)
        refreshReasoningControl()

        statusButton.isBordered = false
        statusButton.font = .systemFont(ofSize: 11, weight: .medium)
        statusButton.target = self
        statusButton.action = #selector(statusClicked)
        statusButton.isHidden = true
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(statusButton)

        NSLayoutConstraint.activate([
            // Buttons centred in the strip; they may shrink (truncating titles) but never
            // overlap the status text on the right.
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultLow),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: statusButton.leadingAnchor, constant: -8),
            statusButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Which corners to round depends on where the strip is attached.
    func apply(slot: BarPlacement.Slot) {
        switch slot {
        case .below: layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // bottom corners
        case .above: layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]   // top corners
        case .insideTop: layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                                 .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
    }

    /// Natural width of the visible buttons, with room for a temporary status.
    var preferredWidth: CGFloat {
        contentStack.fittingSize.width + 24 + (statusButton.isHidden ? 0 : statusButton.fittingSize.width + 12)
    }

    // MARK: - Content

    func setCatalogModels(_ models: [CodexModel]) {
        catalogModels = models
        refreshReasoningControl()
    }

    func setModels(_ newModels: [CodexModel]) {
        guard newModels != models else { return }
        models = newModels
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        for model in newModels {
            let button = ModelButton(model: model)
            button.target = self
            button.action = #selector(modelClicked(_:))
            stack.addArrangedSubview(button)
            buttons[model.id] = button
        }
        refreshButtonStates()
        refreshReasoningControl()
    }

    /// Highlights the model Codex reports for the open chat (nil = unknown).
    func setCurrentModel(id: String?) {
        setCurrentSelection(CurrentSelection(modelID: id, effort: nil))
    }

    func setCurrentSelection(_ selection: CurrentSelection) {
        guard selection.modelID != currentModelID || selection.effort != currentEffort else { return }
        currentModelID = selection.modelID
        currentEffort = selection.effort
        refreshButtonStates()
        refreshReasoningControl()
    }

    /// Marks a switch in progress (dims the other buttons).
    func setBusyModel(id: String?) {
        busyModelID = id
        refreshButtonStates()
        refreshReasoningControl()
    }

    func setBusyReasoning(_ busy: Bool) {
        busyReasoning = busy
        refreshButtonStates()
        refreshReasoningControl()
    }

    private func refreshButtonStates() {
        for (id, button) in buttons {
            button.visualState = id == busyModelID ? .busy : (id == currentModelID ? .current : .normal)
            button.isEnabled = busyModelID == nil && !busyReasoning
        }
    }

    private func refreshReasoningControl() {
        let model = catalogModels.first { $0.id == currentModelID }
        let efforts = model?.supportedEfforts ?? []
        let index = currentEffort.flatMap { efforts.firstIndex(of: $0) }
        reasoningSlider.numberOfTickMarks = max(efforts.count, 2)
        reasoningSlider.minValue = 0
        reasoningSlider.maxValue = Double(max(efforts.count - 1, 1))
        reasoningSlider.doubleValue = Double(index ?? 0)
        reasoningSlider.isEnabled = efforts.count > 1 && index != nil && busyModelID == nil && !busyReasoning
        let value = currentEffort.map(CurrentModelMatcher.label(forEffort:)) ?? "—"
        reasoningLabel.stringValue = "Reasoning \(value)"
        reasoningSlider.setAccessibilityValue(value)
        onSizeChange?()
    }

    /// Shows a short message on the right. `sticky` messages stay until replaced;
    /// others disappear after a few seconds.
    func showStatus(_ text: String?, color: NSColor = .secondaryLabelColor, sticky: Bool = false) {
        statusHideWork?.cancel()
        guard let text, !text.isEmpty else {
            statusButton.isHidden = true
            statusButton.attributedTitle = NSAttributedString(string: "")
            onSizeChange?()
            return
        }
        statusButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        statusButton.isHidden = false
        onSizeChange?()
        if !sticky {
            let work = DispatchWorkItem { [weak self] in self?.showStatus(nil) }
            statusHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    // MARK: - Events

    @objc private func modelClicked(_ sender: ModelButton) {
        onSelect?(sender.model)
    }

    @objc private func effortClicked(_ sender: NSSlider) {
        guard let model = catalogModels.first(where: { $0.id == currentModelID }) else { return }
        let index = sender.integerValue
        guard model.supportedEfforts.indices.contains(index),
              model.supportedEfforts[index] != currentEffort else { return }
        onSelectEffort?(model.supportedEfforts[index])
    }

    @objc private func statusClicked() {
        onStatusClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    // Right-clicks on the buttons themselves should open the same menu.
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

/// One model button: a rounded pill showing the model's display name.
final class ModelButton: NSButton {
    enum VisualState { case normal, current, busy }

    let model: CodexModel
    var visualState: VisualState = .normal { didSet { updateAppearance() } }
    private var hovering = false { didSet { updateAppearance() } }

    init(model: CodexModel) {
        self.model = model
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        // Codex's own description adds information the label does not show.
        toolTip = model.description.isEmpty ? nil : model.description
        setAccessibilityLabel(model.displayName)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 22)])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 18, height: 22)   // horizontal padding inside the pill
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateAppearance() {
        let accent = NSColor.controlAccentColor
        let background: NSColor
        let textColor: NSColor
        let weight: NSFont.Weight
        switch visualState {
        case .current:
            background = accent.withAlphaComponent(0.85)
            textColor = .white
            weight = .semibold
        case .busy:
            background = accent.withAlphaComponent(0.45)
            textColor = .labelColor
            weight = .semibold
        case .normal:
            background = hovering ? NSColor.labelColor.withAlphaComponent(0.12) : .clear
            textColor = .labelColor
            weight = .regular
        }
        layer?.backgroundColor = background.cgColor
        attributedTitle = NSAttributedString(string: model.displayName, attributes: [
            .foregroundColor: textColor,
            .font: NSFont.systemFont(ofSize: 12, weight: weight),
        ])
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
