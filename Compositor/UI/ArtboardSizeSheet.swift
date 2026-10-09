import SwiftUI

/// The small sheet that opens when you right-click an artboard's size label: type the exact width
/// and height in pixels. Applies through `EditorSession.resizeArtboard`, so it lands in undo.
struct ArtboardSizeSheet: View {
    let session: EditorSession
    let target: ArtboardResizeTarget
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Artboard Size").font(.title2.bold())
            Text(target.name).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Width").frame(width: 60, alignment: .leading)
                TextField("Width", text: $width)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
            HStack {
                Text("Height").frame(width: 60, alignment: .leading)
                TextField("Height", text: $height)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }
            if !isValid {
                Text("Use whole pixels from 1 to \(DocumentLimits.maxSide.formatted()).")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("OK") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 320)
        .onAppear {
            width = String(target.width)
            height = String(target.height)
        }
    }

    private var parsedWidth: Int? { Int(width.filter { $0.isNumber }) }
    private var parsedHeight: Int? { Int(height.filter { $0.isNumber }) }
    private var isValid: Bool {
        guard let w = parsedWidth, let h = parsedHeight else { return false }
        return w >= 1 && h >= 1 && w <= DocumentLimits.maxSide && h <= DocumentLimits.maxSide
    }
    private func apply() {
        guard isValid, let w = parsedWidth, let h = parsedHeight else { return }
        session.resizeArtboard(target.id, width: w, height: h)
        dismiss()
    }
}
