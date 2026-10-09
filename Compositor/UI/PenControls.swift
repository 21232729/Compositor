import SwiftUI

struct PenControls: View {
    @Bindable var session: EditorSession

    var body: some View {
        HStack(spacing: 12) {
            Text("Pen").font(ToolHeaderStyle.titleFont)
            Picker("Output", selection: Binding(get: { session.penOutputMode }, set: { session.penOutputMode = $0 })) {
                ForEach(PenOutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Shape fills or strokes the path; Selection turns it into a selection marquee")

            if session.penOutputMode == .shape {
                Toggle("Fill", isOn: Binding(get: { session.penFillsShape }, set: { session.penFillsShape = $0 }))
                    .toggleStyle(.checkbox)
                    .help("Fill the path with the foreground color, or stroke its outline")

                if !session.penFillsShape {
                    HStack(spacing: 6) {
                        Text("Width").scrubbable(sensitivity: 1, value: $session.penStrokeWidth, range: 1...500)
                        Slider(value: Binding(get: { min(100, session.penStrokeWidth) },
                                              set: { session.penStrokeWidth = $0.rounded() }), in: 1...100)
                            .frame(width: 100)
                        TextField("Width", value: Binding(get: { session.penStrokeWidth },
                                                          set: { session.penStrokeWidth = $0.isFinite ? min(500, max(1, $0)) : 2 }),
                                  format: .number.precision(.fractionLength(0)))
                            .frame(width: 48).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .arrowSteps(value: { session.penStrokeWidth },
                                        change: { session.penStrokeWidth = min(500, max(1, $0)) })
                            .unitSuffix("px")
                    }
                }

                HStack(spacing: 6) {
                    Text("Color")
                    Button { session.openColorPicker(background: false) } label: {
                        let swatch = RoundedRectangle(cornerRadius: 3, style: .continuous)
                        swatch.fill(Color(nsColor: session.foregroundColor.nsColor))
                            .overlay { swatch.strokeBorder(.black.opacity(0.5), lineWidth: 1) }
                            .frame(width: 36, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("Pen paths use the foreground color; click to change it")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy || session.document == nil)
    }
}
