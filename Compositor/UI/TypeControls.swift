import SwiftUI
import AppKit

struct TypeControls: View {
    @Bindable var session: EditorSession
    private func value<T>(_ key: WritableKeyPath<LayerTextStyle, T>) -> Binding<T> {
        Binding(get: { session.currentTextStyle[keyPath: key] }, set: { value in
            session.changeTextStyle { $0[keyPath: key] = value }
        })
    }
    private func number(_ key: WritableKeyPath<LayerTextStyle, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(session.currentTextStyle[keyPath: key]) }, set: { value in
            session.changeTextStyle { $0[keyPath: key] = CGFloat(value) }
        })
    }

    /// The face the header shows for the current selection: the caret's face with nothing highlighted, the one face
    /// covering the highlight, or "" when the selection spans faces (so the pickers read "(Multiple)").
    private var currentFace: String {
        guard let draft = session.textDraft else { return session.currentTextStyle.fontName }
        let selection = draft.selection
        if selection.length == 0 { return draft.style.fontName(at: max(0, selection.location - 1)) }
        return draft.style.uniformFontName(in: selection) ?? ""
    }
    /// Applying a chosen face to the current selection, the same path the old single picker used.
    private func applyFace(_ name: String) {
        let selection = session.textDraft?.selection ?? NSRange()
        session.changeTextStyle { $0.setFont(name, in: selection) }
    }
    private func previewFace(_ step: FontChoicePopup.PreviewStep) {
        switch step {
        case .show(let name): session.previewFont(name)
        case .revert: session.endFontPreview()
        case .keep: session.keepFontPreview()
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Type").font(ToolHeaderStyle.titleFont)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    // Family and style, the way Photoshop splits the two: the style popup lists the weights and
                    // slants within whatever family is chosen.
                    FontChoicePopup(
                        items: FontCatalog.allFamilies.map { family in
                            let style = FontCatalog.style(of: currentFace)
                            let face = FontCatalog.face(inFamily: family, matchingStyle: style)
                            return (label: family, value: face?.postScriptName ?? "")
                        },
                        selection: FontCatalog.family(of: currentFace) ?? "",
                        placeholder: "(Family)", accessibility: "Font family",
                        choose: { face in applyFace(face) }, preview: previewFace
                    )
                        .frame(width: 170).help("Font family")
                    FontChoicePopup(
                        items: FontCatalog.faces(ofFamily: FontCatalog.family(of: currentFace) ?? "")
                            .map { (label: $0.style, value: $0.postScriptName) },
                        selection: currentFace,
                        placeholder: "(Style)", accessibility: "Font style",
                        choose: { face in applyFace(face) }, preview: previewFace
                    )
                        .frame(width: 130).help("Font style, weight and slant within the family")
                    TextField("Size", value: number(\.fontSize), format: .number).frame(width: 52)
                        .unitSuffix("px", scrubValue: value(\.fontSize), sensitivity: 1, range: 1...2000, step: 1)
                        .arrowSteps(value: { Double(session.currentTextStyle.fontSize) },
                                    change: { stepped in session.changeTextStyle { $0.fontSize = CGFloat(min(2000, max(1, stepped))) } })
                    Button { session.openTextColorPicker() } label: {
                        let color = session.typeColor
                        let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                        swatch.fill(Color(red: color.red, green: color.green, blue: color.blue))
                            .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                            .frame(width: 36, height: 18)
                    }
                    .buttonStyle(.plain).help("Text color").accessibilityLabel("Text color")
                    HStack(spacing: 2) {
                        ForEach(TextAlignment.allCases, id: \.self) { alignment in
                            let selected = session.currentTextStyle.alignment == alignment
                            Button {
                                session.changeTextStyle { $0.alignment = alignment }
                            } label: {
                                Image(systemName: alignment == .left ? "text.alignleft" : alignment == .center ? "text.aligncenter" : "text.alignright")
                                    .frame(width: 30, height: 26)
                                    .background(selected ? Color.white.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    // Without this the glyph's own strokes are the only thing a click lands on.
                                    .contentShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help("Align " + alignment.rawValue.lowercased())
                            .accessibilityLabel("Align " + alignment.rawValue.lowercased())
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    // Superscript / subscript: raise or lower the highlighted letters, as Photoshop's Text Options.
                    HStack(spacing: 2) {
                        scriptButton(.superscript, symbol: "textformat.superscript", title: "Superscript")
                        scriptButton(.subscript, symbol: "textformat.subscript", title: "Subscript")
                    }
                    Text("Tracking").scrubbable(sensitivity: 1, value: value(\.tracking), range: -100...1000, step: 1)
                    TextField("Tracking", value: number(\.tracking), format: .number).frame(width: 45)
                        .arrowSteps(value: { Double(session.currentTextStyle.tracking) },
                                    change: { stepped in session.changeTextStyle { $0.tracking = CGFloat(stepped) } })
                    Text("Leading").scrubbable(sensitivity: 1, value: value(\.leading), range: 0...5000, step: 1)
                    // 0 means Auto: the field is left empty so its "Auto" placeholder shows through.
                    TextField("Leading", text: Binding(get: {
                        let leading = session.currentTextStyle.leading
                        return leading > 0 ? String(Int(leading.rounded())) : ""
                    }, set: { typed in
                        let value = Double(typed.trimmingCharacters(in: .whitespaces)) ?? 0
                        session.changeTextStyle { $0.leading = CGFloat(max(0, min(5000, value))) }
                    }), prompt: Text("Auto"))
                        .frame(width: 52)
                        .arrowSteps(value: { Double(session.currentTextStyle.lineHeight) },
                                    change: { stepped in session.changeTextStyle { $0.leading = CGFloat(max(0, stepped)) } })
                        .help("Line height, baseline to baseline. Empty or 0 is Auto: 120% of the font size.")
                }
            }.scrollIndicators(.hidden)
            if session.textDraft != nil {
                Button("Cancel") { session.cancelText() }
                // Committing text hands the tool to Move, so the new layer can be dragged or another picked at once.
                Button("Done") { if session.finishText() { session.selectTool(.move) } }
            } else {
                Button("Edit Text") { session.editActiveText() }.disabled(session.activeLayer?.liveText == nil)
            }
        }
        .textFieldStyle(.roundedBorder).padding(.horizontal, 18).toolHeaderBar()
        .disabled(session.document == nil || session.showsBusy)
        .onChange(of: session.colorPicker?.color) { _, _ in session.previewTextColor() }
    }

    /// A superscript/subscript toggle: pressing it again with the same script already on the selection clears it.
    private func scriptButton(_ script: TextScript, symbol: String, title: String) -> some View {
        let on = selectionScript == script
        return Button {
            let selection = session.textDraft?.selection ?? NSRange(location: 0, length: session.currentTextStyle.content.utf16.count)
            session.changeTextStyle { $0.setScript(on ? .none : script, in: selection) }
        } label: {
            Image(systemName: symbol)
                .frame(width: 30, height: 26)
                .background(on ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The script of the current selection, for lighting its button: the caret's own script with nothing highlighted.
    private var selectionScript: TextScript {
        guard let draft = session.textDraft else { return .none }
        let selection = draft.selection
        let index = selection.length == 0 ? max(0, selection.location - 1) : selection.location
        return draft.style.script(at: index)
    }
}

/// A face/family/style popup that previews faces on the text as the pointer moves over the list, the way the
/// single font picker did. `items` carry a display label and the PostScript face to apply (and preview) for it.
struct FontChoicePopup: NSViewRepresentable {
    enum PreviewStep { case show(String), revert, keep }
    let items: [(label: String, value: String)]
    let selection: String
    let placeholder: String
    let accessibility: String
    let choose: (String) -> Void
    let preview: (PreviewStep) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(choose: choose, preview: preview) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FixedWidthPopUpButton(frame: .zero, pullsDown: false)
        button.borderShape = .capsule
        button.cell?.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        button.cell?.alignment = .left
        button.setAccessibilityLabel(accessibility)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.choose = choose
        context.coordinator.preview = preview
        guard !context.coordinator.tracking else { return }
        context.coordinator.reload(into: button, items: items, selection: selection, placeholder: placeholder)
    }

    /// The list holds names of every length; the control keeps whatever width it is given, so choosing a long one
    /// can't stretch it — or leave it stretched once a short one is chosen again.
    final class FixedWidthPopUpButton: NSPopUpButton {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var choose: (String) -> Void
        var preview: (PreviewStep) -> Void
        weak var button: NSPopUpButton?
        var tracking = false
        private var chose = false
        /// Menu item tag -> the PostScript face it applies and previews.
        private var faceByTag: [Int: String] = [:]
        /// The last list built, so a redraw with the same fonts doesn't rebuild every attributed title.
        private var lastSignature = ""

        init(choose: @escaping (String) -> Void, preview: @escaping (PreviewStep) -> Void) {
            self.choose = choose; self.preview = preview
        }

        func reload(into button: NSPopUpButton, items: [(label: String, value: String)], selection: String, placeholder: String) {
            let signature = selection + "|" + items.map { "\($0.label):\($0.value)" }.joined(separator: ",")
            guard signature != lastSignature else { return }
            lastSignature = signature
            button.removeAllItems()
            faceByTag.removeAll()
            var tag = 0
            var selectedIndex: Int?
            for item in items where !item.value.isEmpty {
                let menuItem = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
                menuItem.tag = tag
                menuItem.attributedTitle = Self.styled(item.label, face: item.value)
                button.menu?.addItem(menuItem)
                if item.value == selection { selectedIndex = button.numberOfItems - 1 }
                if item.label == selection { selectedIndex = button.numberOfItems - 1 }
                faceByTag[tag] = item.value
                tag += 1
            }
            if button.numberOfItems == 0 {
                let empty = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
                empty.isEnabled = false
                button.menu?.addItem(empty)
            }
            if let selectedIndex { button.selectItem(at: selectedIndex) }
        }

        /// The label drawn in its own face, when that face can render it; otherwise the menu's plain font.
        @MainActor private static func styled(_ label: String, face: String) -> NSAttributedString {
            guard let font = NSFont(name: face, size: NSFont.systemFontSize),
                  label.unicodeScalars.filter({ $0.properties.isAlphabetic }).allSatisfy({ font.coveredCharacterSet.contains($0) })
            else { return NSAttributedString(string: label) }
            return NSAttributedString(string: label, attributes: [.font: font])
        }

        func menuWillOpen(_ menu: NSMenu) { tracking = true }
        func menuDidClose(_ menu: NSMenu) {
            tracking = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.chose { self.preview(.revert) }
                self.chose = false
            }
        }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            if let item, let face = faceByTag[item.tag] { preview(.show(face)) }
        }

        @objc func choose(_ button: NSPopUpButton) {
            chose = true
            if let face = button.selectedItem.flatMap({ faceByTag[$0.tag] }) {
                preview(.keep)
                choose(face)
            }
        }
    }
}
