import AppKit
import CodexModelBarCore

/// The floating strip itself.
///
/// It is a **non-activating panel**: clicking a button does not make this app active,
/// so Codex keeps keyboard focus while the switcher operates its model menu.
final class BarPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
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
        hidesOnDeactivate = false        // visibility is managed by AppController, including the brief keyboard-focus handoff
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

    /// Keep the toolbar reachable if Flow intersects its on-screen position.
    func place(frame: CGRect, obstructingWindows: [CGRect]) {
        level = obstructingWindows.contains { frame.intersects($0) } ? .floating + 2 : .floating // Ethan wants the bar beside Flow's HUD and always visible; clear Flow's level (.floating + 1) without moving either window (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
        if self.frame != frame {
            setFrame(frame, display: true)
        }
        if !isVisible { orderFrontRegardless() }
        (contentView as? BarView)?.placeStatus()
    }

    override func orderOut(_ sender: Any?) {
        (contentView as? BarView)?.hideStatus()
        super.orderOut(sender)
    }
}

/// A horizontal toolbar that wraps only when its available screen width runs out.
/// Status messages float outside the controls without changing the toolbar's size.
final class BarView: NSVisualEffectView {
    var availableWidth: CGFloat? { didSet { if availableWidth != oldValue { needsLayout = true } } } // Ethan rejected an unconditional vertical rail: keep the horizontal layout beside Flow and wrap only for insufficient side space (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
    var obstructingWindows: [CGRect] = [] // Reuse the tracker's geometry for floating notices; never read either app again just to place one.

    /// Called when a model button is clicked.
    var onSelect: ((CodexModel) -> Void)?
    /// Called when a reasoning tick is chosen.
    var onSelectEffort: ((String) -> Void)?
    /// Called when a response-speed icon is clicked.
    var onSelectSpeed: ((ResponseSpeed) -> Void)?
    /// Called when the status text is clicked (used for "Allow Accessibility access").
    var onStatusClick: (() -> Void)?
    /// Repositions the panel when the visible model list changes its required size.
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
    private let speedSeparator = NSBox()
    private let visibleSpeeds: [ResponseSpeed] = [.fast, .ultrafast] // Ethan removed the Standard icon; click the active tier again to toggle it off (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
    private var speedButtons: [ResponseSpeed: NSButton] = [:]
    private let statusButton = NSButton(title: "", target: nil, action: nil)
    private let statusPanel = BarPanel() // Ethan rejected messages replacing the reasoning slider; reuse the nonactivating panel for a separate notice (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
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
    private var busySpeed = false
    private var currentSpeed: ResponseSpeed? // Best-effort speed of the focused chat; nil when Codex's model button was not read.
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
        speedSeparator.boxType = .separator
        addSubview(speedSeparator)
        for speed in visibleSpeeds {
            let button = NSButton(image: Self.speedImage(for: speed, filled: false),
                                  target: self, action: #selector(speedClicked(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = speed == .fast ? "Fast speed — more usage" : "\(speed.rawValue) speed"
            button.setAccessibilityLabel("\(speed.rawValue) speed")
            addSubview(button)
            speedButtons[speed] = button
        }

        reasoningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        reasoningLabel.textColor = .secondaryLabelColor
        reasoningLabel.alignment = .center
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
        let statusBackground = NSVisualEffectView()
        statusBackground.material = material
        statusBackground.blendingMode = blendingMode
        statusBackground.state = state
        statusBackground.wantsLayer = true
        statusBackground.layer?.cornerRadius = 7
        statusBackground.layer?.masksToBounds = true
        statusBackground.addSubview(statusButton)
        statusPanel.contentView = statusBackground
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Model selection, reasoning previews and status messages never change the natural width.
    var preferredWidth: CGFloat {
        return modelWidths.reduce(0, +) + CGFloat(max(models.count - 1, 0)) * modelSpacing
            + sectionSpacing + naturalReasoningWidth + speedWidth + 16
    }

    var preferredSize: CGSize {
        let minimumWidth = max(modelWidths.max() ?? 0, max(reasoningLabelWidth, sliderWidth)) + 16
        let width = min(preferredWidth, max(minimumWidth, availableWidth ?? preferredWidth)) // Keep controls readable; placement rejects clear regions narrower than this minimum and tries another side.
        return controlLayout(width: width).size
    }

    private var modelWidths: [CGFloat] {
        models.map { buttons[$0.id]?.intrinsicContentSize.width ?? 0 }
    }

    private var naturalReasoningWidth: CGFloat {
        1 + sectionSpacing + reasoningLabelWidth + sectionSpacing + sliderWidth
    }

    private var speedWidth: CGFloat { sectionSpacing * 2 + 1 + CGFloat(visibleSpeeds.count * 24) }

    private struct ControlLayout {
        let size: CGSize
        let frames: [CGRect] // Models in display order, followed by the reasoning group and the two speed icons together.
        let separators: [CGRect?]
    }

    /// Measure and place the same groups for both window sizing and actual drawing.
    private func controlLayout(width: CGFloat) -> ControlLayout {
        let contentWidth = max(0, width - 16)
        let reasoningFits = reasoningLabelWidth + sectionSpacing + sliderWidth <= contentWidth
        let reasoningSize = reasoningFits
            ? CGSize(width: reasoningLabelWidth + sectionSpacing + sliderWidth, height: 26)
            : CGSize(width: max(reasoningLabelWidth, sliderWidth), height: 44)
        let sizes = modelWidths.map { CGSize(width: $0, height: 22) }
            + [reasoningSize, CGSize(width: CGFloat(visibleSpeeds.count * 24), height: 22)]
        var rows: [[Int]] = [[]]
        var rowHeights: [CGFloat] = [0]
        var frames: [CGRect] = []
        var separators: [CGRect?] = []
        var x: CGFloat = 8
        for (index, size) in sizes.enumerated() {
            let isSection = index >= models.count
            var gap: CGFloat = x == 8 ? 0 : (isSection ? sectionSpacing * 2 + 1 : modelSpacing)
            if x + gap + size.width > width - 8 && x > 8 {
                rows.append([])
                rowHeights.append(0)
                x = 8
                gap = 0
            }
            separators.append(isSection && gap > 0 ? CGRect(x: x + sectionSpacing, y: 0, width: 1, height: 17) : nil)
            frames.append(CGRect(x: x + gap, y: 0, width: size.width, height: size.height))
            rows[rows.count - 1].append(index)
            rowHeights[rowHeights.count - 1] = max(rowHeights.last ?? 0, size.height)
            x += gap + size.width
        }
        let height = 4 + rowHeights.reduce(0, +) + CGFloat(rows.count - 1) * modelSpacing
        var top = height - 2
        for (row, indices) in rows.enumerated() {
            for index in indices {
                frames[index].origin.y = top - (rowHeights[row] + frames[index].height) / 2
                if separators[index] != nil { separators[index]!.origin.y = top - (rowHeights[row] + 17) / 2 }
            }
            top -= rowHeights[row] + modelSpacing
        }
        return ControlLayout(size: CGSize(width: width, height: height), frames: frames, separators: separators)
    }

    override func layout() {
        super.layout()
        let layout = controlLayout(width: bounds.width)
        for (index, model) in models.enumerated() { buttons[model.id]?.frame = layout.frames[index] }
        for (view, index) in [(separator, models.count), (speedSeparator, models.count + 1)] {
            view.isHidden = layout.separators[index] == nil
            if let frame = layout.separators[index] { view.frame = frame }
        }
        let reasoningFrame = layout.frames[models.count]
        let stackedReasoning = reasoningFrame.height > 26
        reasoningLabel.alignment = .left
        reasoningLabel.frame = CGRect(x: reasoningFrame.minX,
                                      y: stackedReasoning ? reasoningFrame.maxY - 16 : reasoningFrame.midY - 8,
                                      width: reasoningLabelWidth, height: 16)
        reasoningSlider.frame = CGRect(x: stackedReasoning ? reasoningFrame.minX : reasoningLabel.frame.maxX + sectionSpacing,
                                       y: reasoningFrame.minY, width: sliderWidth, height: stackedReasoning ? 24 : 26)
        let speedsFrame = layout.frames[models.count + 1]
        for (index, speed) in visibleSpeeds.enumerated() {
            speedButtons[speed]?.frame = CGRect(x: speedsFrame.minX + CGFloat(index * 24), y: speedsFrame.minY, width: 24, height: 22)
        }
        placeStatus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeStatus()
    }

    /// Follow the toolbar as its child, while keeping the message outside every control.
    func placeStatus() {
        guard !statusButton.isHidden, let window, window.isVisible, let screen = window.screen else {
            hideStatus()
            return
        }
        let size = CGSize(width: ceil(statusButton.attributedTitle.size().width) + 20, height: 26)
        let frame = BarPlacement.status(beside: window.frame, visibleFrame: screen.visibleFrame, contentSize: size,
                                        obstructingWindows: obstructingWindows)
        statusButton.frame = CGRect(x: 10, y: 2, width: max(0, frame.width - 20), height: 22)
        statusPanel.level = window.level
        statusPanel.setFrame(frame, display: true)
        if statusPanel.parent !== window {
            statusPanel.parent?.removeChildWindow(statusPanel)
            window.addChildWindow(statusPanel, ordered: .above)
        }
        if !statusPanel.isVisible { statusPanel.orderFrontRegardless() }
    }

    /// A hidden or detached toolbar must not leave a floating notice over another app.
    func hideStatus() {
        statusPanel.parent?.removeChildWindow(statusPanel)
        statusPanel.orderOut(nil)
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

    func setBusySpeed(_ busy: Bool) {
        busySpeed = busy
        refreshButtonStates()
        refreshReasoningControl()
    }

    /// Fills the icon of the speed Codex is on; Standard or an unread button leaves both outlined.
    func setCurrentSpeed(_ speed: ResponseSpeed?) {
        guard speed != currentSpeed else { return }
        currentSpeed = speed
        refreshButtonStates()
    }

    func cancelReasoningPreview() {
        previewEffort = nil
        if reasoningSlider.isTrackingPointer { dragWasInvalidated = true }
        refreshReasoningControl()
    }

    private func refreshButtonStates() {
        for (id, button) in buttons {
            button.visualState = id == busyModelID ? .busy : (id == currentModelID ? .current : .normal)
            button.isEnabled = busyModelID == nil && !busyReasoning && !busySpeed
        }
        for (speed, button) in speedButtons {
            let active = speed == currentSpeed
            button.isEnabled = busyModelID == nil && !busyReasoning && !busySpeed
            button.image = Self.speedImage(for: speed, filled: active)
            button.contentTintColor = active ? .controlAccentColor : .labelColor // Same accent as the current model's pill.
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
        reasoningSlider.isEnabled = efforts.count > 1 && index != nil && busyModelID == nil && !busyReasoning && !busySpeed
        updateReasoningLabel()
    }

    private func updateReasoningLabel() {
        let displayedEffort = previewEffort ?? currentEffort
        let value = displayedEffort.map(CurrentModelMatcher.label(forEffort:)) ?? "—"
        reasoningLabel.stringValue = "Reasoning \(value)"
        reasoningSlider.setAccessibilityValue(value)
    }

    /// Shows a short message beside the toolbar. `sticky` messages stay until replaced;
    /// others disappear after a few seconds.
    func showStatus(_ text: String?, color: NSColor = .secondaryLabelColor, sticky: Bool = false) {
        statusHideWork?.cancel()
        guard let text, !text.isEmpty else {
            statusButton.isHidden = true
            statusButton.attributedTitle = NSAttributedString(string: "")
            statusButton.toolTip = nil
            hideStatus()
            return
        }
        statusButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        statusButton.isHidden = false
        statusButton.toolTip = text
        placeStatus()
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

    @objc private func speedClicked(_ sender: NSButton) {
        guard let speed = speedButtons.first(where: { $0.value === sender })?.key else { return }
        onSelectSpeed?(speed)
    }

    private static func speedImage(for speed: ResponseSpeed, filled: Bool) -> NSImage {
        let boltName = filled ? "bolt.fill" : "bolt" // Ethan asked for the active speed's icon to be filled in (2026-10-31, Claude session 4901285c); Ultrafast's bolts are outlined while off.
        switch speed {
        case .standard: return NSImage(systemSymbolName: "speedometer", accessibilityDescription: speed.rawValue)!
        case .fast: return NSImage(systemSymbolName: boltName, accessibilityDescription: speed.rawValue)!
        case .ultrafast:
            let bolt = NSImage(systemSymbolName: boltName, accessibilityDescription: nil)!
            let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
                bolt.draw(in: NSRect(x: 1, y: 1, width: 8, height: 14))
                bolt.draw(in: NSRect(x: 11, y: 1, width: 8, height: 14))
                return true
            }
            image.isTemplate = true
            return image
        }
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
