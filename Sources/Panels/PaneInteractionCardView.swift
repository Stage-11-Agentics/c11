import AppKit
import SwiftUI

/// Shared SwiftUI rendering for a pane-scoped interaction. Used by every mount layer —
/// AppKit-hosted for terminals and WebView-backed browsers (via NSHostingView), and
/// as a raw SwiftUI ZStack overlay for markdown and empty-browser panels.
///
/// Scrim covers only the panel's bounds. The card grabs first responder via an internal
/// `@FocusState` anchor so Return/Escape/Tab/Cmd+D route through `onKeyPress`.
struct PaneInteractionCardView: View {
    let panelId: UUID
    let interaction: PaneInteraction
    @ObservedObject var runtime: PaneInteractionRuntime

    var body: some View {
        ZStack {
            // Scrim — click does NOT dismiss (plan §2: prevents accidental cancel).
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .onTapGesture { /* intentional no-op */ }
                .accessibilityHidden(true)

            card
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private var card: some View {
        switch interaction {
        case .confirm(let content):
            ConfirmCard(panelId: panelId, content: content, runtime: runtime)
        case .textInput(let content):
            TextInputCard(panelId: panelId, content: content, runtime: runtime)
        }
    }
}

// MARK: - Confirm variant

private struct ConfirmCard: View {
    let panelId: UUID
    let content: ConfirmContent
    @ObservedObject var runtime: PaneInteractionRuntime
    @State private var pulse: Bool = false

    private var selected: ConfirmSelectionField {
        runtime.confirmSelection[panelId] ?? .confirm
    }

    private var isCritical: Bool {
        content.style == .criticalDestructive
    }

    private var titleFont: Font {
        isCritical
            ? .system(size: 18, weight: .bold)
            : .system(size: 15, weight: .semibold)
    }

    private var confirmFont: Font {
        isCritical
            ? .system(size: 14, weight: .bold)
            : .system(size: 13, weight: .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if isCritical {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.red)
                        .accessibilityHidden(true)
                }
                Self.emphasizedText(content.title)
                    .font(titleFont)
                    .foregroundStyle(BrandColors.whiteSwiftUI)
            }

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !content.detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(content.detailLines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.65))
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.95))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: cancel) {
                    Text(content.cancelLabel)
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .selectionBox(isActive: selected == .cancel)
                .accessibilityAddTraits(selected == .cancel ? .isSelected : [])

                Button(role: content.role == .destructive ? .destructive : nil,
                       action: confirm) {
                    Self.emphasizedText(content.confirmLabel)
                        .font(confirmFont)
                        .foregroundColor(content.role == .destructive
                                         ? BrandColors.whiteSwiftUI
                                         : BrandColors.blackSwiftUI)
                        .frame(minWidth: isCritical ? 96 : 64)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(isCritical ? .large : .regular)
                .tint(content.role == .destructive ? .red : BrandColors.goldSwiftUI)
                .selectionBox(isActive: selected == .confirm)
                .accessibilityAddTraits(selected == .confirm ? .isSelected : [])
                .scaleEffect(isCritical && pulse ? 1.04 : 1.0)
                .shadow(color: isCritical
                        ? Color.red.opacity(pulse ? 0.85 : 0.4)
                        : .clear,
                        radius: isCritical ? (pulse ? 14 : 6) : 0)
                .animation(
                    isCritical
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            }
        }
        .padding(24)
        .frame(
            minWidth: isCritical ? 320 : 260,
            maxWidth: isCritical ? 480 : 420,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isCritical ? Color.red.opacity(0.85) : BrandColors.ruleSwiftUI,
                            lineWidth: isCritical ? 2 : 1
                        )
                )
                .shadow(
                    color: isCritical ? Color.red.opacity(0.45) : .clear,
                    radius: isCritical ? 20 : 0
                )
        )
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("PaneInteraction.confirm.card")
        .onAppear {
            if isCritical { pulse = true }
        }
    }

    private func confirm() {
        runtime.resolveConfirm(
            panelId: panelId,
            result: .confirmed,
            ifInteractionId: content.id
        )
    }
    private func cancel() {
        runtime.resolveConfirm(
            panelId: panelId,
            result: .cancelled,
            ifInteractionId: content.id
        )
    }

    /// Underline standalone occurrences of "entire" / "Entire" / "ENTIRE" in
    /// the supplied string. We use this to make the pane-close title and
    /// button visibly distinct from a tab close at a glance — the differentiating
    /// word is what catches the eye, not the sentence as a whole.
    private static func emphasizedText(_ string: String) -> Text {
        let pattern = #"\b(entire|Entire|ENTIRE)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(string)
        }
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: string, range: fullRange)
        guard !matches.isEmpty else { return Text(string) }

        var cursor = 0
        var result = Text("")
        for match in matches {
            if match.range.location > cursor {
                let plainRange = NSRange(location: cursor, length: match.range.location - cursor)
                result = result + Text(nsString.substring(with: plainRange))
            }
            let emphasized = nsString.substring(with: match.range)
            result = result + Text(emphasized).underline().bold()
            cursor = match.range.location + match.range.length
        }
        if cursor < nsString.length {
            let tailRange = NSRange(location: cursor, length: nsString.length - cursor)
            result = result + Text(nsString.substring(with: tailRange))
        }
        return result
    }
}

// MARK: - TextInput variant

private struct TextInputCard: View {
    let panelId: UUID
    let content: TextInputContent
    @ObservedObject var runtime: PaneInteractionRuntime

    @State private var value: String = ""
    @State private var errorText: String?

    private var selection: TextInputSelectionField {
        runtime.textInputSelection[panelId] ?? .field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
            }

            IMESafeTextField(
                text: $value,
                placeholder: content.placeholder,
                onSubmit: submit,
                onCancel: cancel,
                onTabOut: { backward in
                    runtime.cycleTextInputSelection(panelId: panelId, backward: backward)
                },
                onBeganEditing: {
                    runtime.setTextInputSelection(panelId: panelId, .field)
                }
            )
            .frame(minHeight: 22)

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .accessibilityIdentifier("PaneInteraction.textInput.error")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: cancel) {
                    Text(content.cancelLabel)
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .selectionBox(isActive: selection == .cancel)
                .accessibilityAddTraits(selection == .cancel ? .isSelected : [])

                Button(action: submit) {
                    Text(content.confirmLabel)
                        .foregroundColor(BrandColors.blackSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.goldSwiftUI)
                .keyboardShortcut(.defaultAction)
                .selectionBox(isActive: selection != .cancel)
                .accessibilityAddTraits(selection == .confirm ? .isSelected : [])
            }
        }
        .padding(24)
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
        .background(
            // Background tap: click on the card chrome (outside the field and
            // buttons) defocuses the field and promotes selection to .confirm
            // so arrow keys start driving the buttons. The Color.clear layer
            // sits behind real content, so taps on the field / buttons hit
            // those first and never reach this gesture.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    runtime.setTextInputSelection(panelId: panelId, .confirm)
                }
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(BrandColors.ruleSwiftUI, lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("PaneInteraction.textInput.card")
        .onAppear {
            value = content.defaultValue
            // Seed the bridge so Cmd+D immediately after present() submits the
            // default value instead of nil — matches the original contract
            // when the user hasn't started typing yet.
            runtime.updatePendingTextInputValue(interactionId: content.id, value: content.defaultValue)
        }
        .onChange(of: value) { _, newValue in
            // Bridge live text back to the runtime so Cmd+D accept submits
            // what the user typed, not the default value.
            runtime.updatePendingTextInputValue(interactionId: content.id, value: newValue)
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private func submit() {
        if let error = content.validate(value) {
            errorText = error
            return
        }
        runtime.resolveTextInput(
            panelId: panelId,
            result: .submitted(value),
            ifInteractionId: content.id
        )
    }

    private func cancel() {
        runtime.resolveTextInput(
            panelId: panelId,
            result: .cancelled,
            ifInteractionId: content.id
        )
    }
}

/// NSTextField-backed text input that respects IME composition. Needed because
/// SwiftUI's `TextField` routes key events in a way that swallows marked-text
/// composition state for CJK input methods — typing Japanese (Kotoeri) or
/// Pinyin into the rename-tab overlay would otherwise lose the composition.
///
/// Pattern mirrors m9's `TextBoxInput.InputTextView` IME guard: skip binding
/// sync and binding writes whenever `currentEditor()?.hasMarkedText()` is true.
private struct IMESafeTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String?
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Called when Tab / Shift-Tab is pressed inside the field. `backward`
    /// is true for Shift-Tab. The card uses this to cycle its selection
    /// state off `.field`; the overlay host's selection observer then
    /// transfers first responder from this field to itself.
    var onTabOut: ((_ backward: Bool) -> Void)? = nil
    /// Called when the field begins editing (e.g., user clicked it after
    /// defocusing). Lets the card restore `.field` selection so the outline
    /// on Cancel/Confirm clears.
    var onBeganEditing: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.placeholderString = placeholder ?? ""
        tf.delegate = context.coordinator
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.isEditable = true
        tf.isSelectable = true
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.sendsActionOnEndEditing = false
        tf.focusRingType = .default
        // Grab first responder on next runloop so the hosting window has
        // settled its responder chain (the AppKit overlay host has already
        // become first responder just before this view appears).
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let window = tf.window else { return }
            window.makeFirstResponder(tf)
            if let editor = tf.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (tf.stringValue as NSString).length)
            }
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder ?? ""
        // Skip committed-text sync during IME composition — the field editor
        // holds uncommitted marked text that stringValue doesn't reflect.
        // Overwriting stringValue here cancels the active composition.
        if let editor = nsView.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IMESafeTextField
        init(_ parent: IMESafeTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if let editor = tf.currentEditor() as? NSTextView, editor.hasMarkedText() {
                // Don't push uncommitted composition through to the binding.
                return
            }
            parent.text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // User clicked back into the field (or AppKit granted responder) —
            // reset the card's selection so the outline on Cancel/Confirm
            // clears and arrow keys go back to cursor-movement inside the
            // field editor.
            parent.onBeganEditing?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() {
                    // Let the IME commit the composition first; NSTextField
                    // will re-send insertNewline on the next commit.
                    return false
                }
                // Flush the field's committed value to the binding before
                // invoking submit — resignFirstResponder otherwise lags.
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                if textView.hasMarkedText() { return false }
                parent.text = control.stringValue
                parent.onTabOut?(false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if textView.hasMarkedText() { return false }
                parent.text = control.stringValue
                parent.onTabOut?(true)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Helpers

private extension View {
    /// White rectangular outline around the currently-selected button. Arrow
    /// keys (left/right) and Tab move the selection; Return invokes it. Plain
    /// `@State` drives this overlay rather than `@FocusState` because the
    /// `PaneInteractionOverlayHost` holds AppKit first responder — SwiftUI
    /// focus inside the card is shadowed, so it can't be trusted to render.
    @ViewBuilder
    func selectionBox(isActive: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white, lineWidth: isActive ? 2 : 0)
                .padding(-3)
                .animation(.easeInOut(duration: 0.12), value: isActive)
        )
    }
}

