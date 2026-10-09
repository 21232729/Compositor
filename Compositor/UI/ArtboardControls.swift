import SwiftUI

struct ArtboardControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Artboard").font(ToolHeaderStyle.titleFont)

            if session.usesArtboards {
                // Artboard selector
                Picker("Artboard", selection: Binding(
                    get: { session.document?.activeArtboardID },
                    set: { session.setActiveArtboard($0) }
                )) {
                    ForEach(session.document?.artboards ?? []) { artboard in
                        Text(artboard.name).tag(Optional(artboard.id))
                    }
                }
                .frame(width: 150)

                Divider().frame(height: 16)

                // Show artboard count
                Text("\(session.document?.artboards.count ?? 0) artboard\(session.document?.artboards.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
            } else {
                Text("Drag to create an artboard").foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .toolHeaderBar()
    }
}
