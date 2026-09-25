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
    /// Repositions the panel when the visible model list changes its required width.
    var onSizeChange: (() -> Void)?
    /// Supplies the right-click menu.
    var menuProvider: (() -> NSMenu)?

    private let modelSpacing: CGFloat = 4
    private let sectionSpacing: CGFloat = 8
    private let sliderWidth: CGFloat = 122
    private var reasoningLabelWidth: CGFloat = 0
    private let reasoningLabel = NSTextField(labelWithString: "Reasoning —")
    private let reasoningSlider = ReasoningSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let separator = NSBox()
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private var buttons: [String: ModelButton] = [:]
    private var models: [CodexModel] = []
    private var catalogModels: [CodexModel] = []
    private var currentModelID: String?
    private var currentEffort: String?
    private var previewEffort: String?
    private var dragModelID: String?
    private var dragWasInvalidated = false
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

        separator.boxType = .separator
        addSubview(separator)

        reasoningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        reasoningLabel.textColor = .secondaryLabelColor
        let longestReasoningLabel = "Reasoning Extra High" as NSString
        reasoningLabelWidth = ceil(longestReasoningLabel.size(withAttributes: [
            .font: reasoningLabel.font as Any,
        ]).width) + 4
        reasoningLabel.lineBreakMode = .byTruncatingTail
        addSubview(reasoningLabel)

        reasoningSlider.numberOfTickMarks = 2
        reasoningSlider.allowsTickMarkValuesOnly = true
        reasoningSlider.tickMarkPosition = .below
        reasoningSlider.isContinuous = true
        reasoningSlider.target = self
        reasoningSlider.action = #selector(effortClicked(_:))
        reasoningSlider.onBeginTracking = { [weak self] in
            guard let self else { return }
            self.dragModelID = self.currentModelID
            self.dragWasInvalidated = false
        }
        reasoningSlider.onFinishTracking = { [weak self] in
            guard let self else { return }
            if self.dragWasInvalidated {
                self.previewEffort = nil
                self.refreshReasoningControl()
            } else {
                self.commitEffort()
            }
            self.dragModelID = nil
        }
        reasoningSlider.toolTip = "Choose reasoning effort"
        reasoningSlider.setAccessibilityLabel("Reasoning effort")
        addSubview(reasoningSlider)
        refreshReasoningControl()

        statusButton.isBordered = false
        statusButton.font = .systemFont(ofSize: 11, weight: .medium)
        statusButton.target = self
        statusButton.action = #selector(statusClicked)
        statusButton.isHidden = true
        (statusButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        addSubview(statusButton)
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

    /// Independent of the current layout: compressed controls never feed a smaller
    /// width back into the panel, and status messages use the reasoning area.
    var preferredWidth: CGFloat {
        modelWidths.reduce(0, +) + CGFloat(max(models.count - 1, 0)) * modelSpacing
            + sectionSpacing + naturalReasoningWidth + 16
    }

    private var modelWidths: [CGFloat] {
        models.map { buttons[$0.id]?.intrinsicContentSize.width ?? 0 }
    }

    private var naturalReasoningWidth: CGFloat {
        1 + sectionSpacing + reasoningLabelWidth + sectionSpacing + sliderWidth
    }

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - 16)
        let reasoningWidth = min(naturalReasoningWidth, max(150, available * 0.45))
        let gaps = CGFloat(max(models.count - 1, 0)) * modelSpacing
        let buttonSpace = max(0, available - reasoningWidth - sectionSpacing - gaps)
        let naturalButtons = modelWidths.reduce(0, +)
        let scale = min(1, buttonSpace / max(naturalButtons, 1))
        var x: CGFloat = 8
        for model in models {
            guard let button = buttons[model.id] else { continue }
            let width = button.intrinsicContentSize.width * scale
            button.frame = NSRect(x: x, y: (bounds.height - 22) / 2, width: width, height: 22)
            x += width + modelSpacing
        }
        if !models.isEmpty { x -= modelSpacing }
        x += sectionSpacing
        separator.frame = NSRect(x: x, y: (bounds.height - 17) / 2, width: 1, height: 17)
        x += 1 + sectionSpacing
        let remaining = max(0, bounds.width - 8 - x)
        let labelWidth = min(reasoningLabelWidth, max(60, remaining - sectionSpacing - 70))
        reasoningLabel.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: labelWidth, height: 16)
        reasoningSlider.frame = NSRect(x: x + labelWidth + sectionSpacing, y: 2,
                                      width: max(0, remaining - labelWidth - sectionSpacing), height: bounds.height - 4)
        statusButton.frame = NSRect(x: x, y: 3, width: remaining, height: bounds.height - 6)
        reasoningLabel.isHidden = !statusButton.isHidden
        reasoningSlider.isHidden = !statusButton.isHidden
    }

    // MARK: - Content

    func setCatalogModels(_ models: [CodexModel]) {
        catalogModels = models
        refreshReasoningControl()
    }

    func setModels(_ newModels: [CodexModel]) {
        guard newModels != models else { return }
        models = newModels
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        for model in newModels {
            let button = ModelButton(model: model)
            button.target = self
            button.action = #selector(modelClicked(_:))
            addSubview(button)
            buttons[model.id] = button
        }
        refreshButtonStates()
        refreshReasoningControl()
        needsLayout = true
        onSizeChange?()
    }

    /// Highlights the model Codex reports for the open chat (nil = unknown).
    func setCurrentModel(id: String?) {
        setCurrentSelection(CurrentSelection(modelID: id, effort: nil))
    }

    func setCurrentSelection(_ selection: CurrentSelection) {
        guard selection.modelID != currentModelID || selection.effort != currentEffort else { return }
        if selection.modelID != currentModelID {
            previewEffort = nil
            if reasoningSlider.isTrackingPointer { dragWasInvalidated = true }
        } else if !reasoningSlider.isTrackingPointer && !busyReasoning {
            previewEffort = nil
        }
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
        if !busy { previewEffort = nil }
        refreshButtonStates()
        refreshReasoningControl()
    }

    func cancelReasoningPreview() {
        previewEffort = nil
        if reasoningSlider.isTrackingPointer { dragWasInvalidated = true }
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
        if !reasoningSlider.isTrackingPointer {
            reasoningSlider.numberOfTickMarks = max(efforts.count, 2)
            reasoningSlider.minValue = 0
            reasoningSlider.maxValue = Double(max(efforts.count - 1, 1))
        }
        if !reasoningSlider.isTrackingPointer && !busyReasoning {
            reasoningSlider.doubleValue = Double(index ?? 0)
        }
        reasoningSlider.isEnabled = efforts.count > 1 && index != nil && busyModelID == nil && !busyReasoning
        updateReasoningLabel()
    }

    private func updateReasoningLabel() {
        let displayedEffort = previewEffort ?? currentEffort
        let value = displayedEffort.map(CurrentModelMatcher.label(forEffort:)) ?? "—"
        reasoningLabel.stringValue = "Reasoning \(value)"
        reasoningSlider.setAccessibilityValue(value)
    }

    /// Shows a short message on the right. `sticky` messages stay until replaced;
    /// others disappear after a few seconds.
    func showStatus(_ text: String?, color: NSColor = .secondaryLabelColor, sticky: Bool = false) {
        statusHideWork?.cancel()
        guard let text, !text.isEmpty else {
            statusButton.isHidden = true
            statusButton.attributedTitle = NSAttributedString(string: "")
            statusButton.toolTip = nil
            needsLayout = true
            return
        }
        statusButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        statusButton.isHidden = false
        statusButton.toolTip = text
        needsLayout = true
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

    @objc private func effortClicked(_ sender: ReasoningSlider) {
        guard !dragWasInvalidated || !sender.isTrackingPointer,
              !sender.isTrackingPointer || dragModelID == currentModelID,
              let model = catalogModels.first(where: { $0.id == currentModelID }) else { return }
        let index = sender.integerValue
        guard model.supportedEfforts.indices.contains(index) else { return }
        previewEffort = model.supportedEfforts[index]
        updateReasoningLabel()
        if !sender.isTrackingPointer { commitEffort() }
    }

    private func commitEffort() {
        guard let effort = previewEffort, effort != currentEffort else {
            previewEffort = nil
            refreshReasoningControl()
            return
        }
        onSelectEffort?(effort)
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

/// Sends previews continuously, then commits one selected tick at mouse release.
private final class ReasoningSlider: NSSlider {
    private(set) var isTrackingPointer = false
    var onBeginTracking: (() -> Void)?
    var onFinishTracking: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTrackingPointer = true
        onBeginTracking?()
        track(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPointer else { return }
        track(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingPointer else { return }
        track(event)
        isTrackingPointer = false
        onFinishTracking?()
    }

    private func track(_ event: NSEvent) {
        guard numberOfTickMarks > 1 else { return }
        // Explicit pointer events keep the label and commit boundary in sync.
        // AppKit's native mouseDown tracking can return before a knob drag ends.
        let point = convert(event.locationInWindow, from: nil)
        let first = rectOfTickMark(at: 0).midX
        let last = rectOfTickMark(at: numberOfTickMarks - 1).midX
        let fraction = max(0, min(1, (point.x - first) / max(last - first, 1)))
        let index = Int((fraction * Double(numberOfTickMarks - 1)).rounded())
        doubleValue = tickMarkValue(at: index)
        if let action { sendAction(action, to: target) }
    }
}

/// One model button: a rounded pill showing the model's display name.
final class ModelButton: NSButton {
    enum VisualState { case normal, current, busy }

    let model: CodexModel
    private let fixedWidth: CGFloat
    var visualState: VisualState = .normal { didSet { updateAppearance() } }
    private var hovering = false { didSet { updateAppearance() } }

    init(model: CodexModel) {
        self.model = model
        let weights: [NSFont.Weight] = [.regular, .semibold]
        fixedWidth = ceil(weights.map { weight in
            (model.displayName as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: weight),
            ]).width
        }.max() ?? 0) + 18
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        // Codex's own description adds information the label does not show.
        toolTip = model.description.isEmpty ? nil : model.description
        setAccessibilityLabel(model.displayName)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: 22)
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
