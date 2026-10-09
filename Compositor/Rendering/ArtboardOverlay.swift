import AppKit

/// Draws artboard borders, name and size labels, resize handles, and the in-progress
/// creation rectangle above the canvas. The canvas itself is presented by the Metal
/// view on screen, so anything that has to sit on top of it lives in its own overlay,
/// the way the transform handles and the pixel grid do. Purely visual: it never
/// intercepts mouse events.
final class ArtboardOverlay: NSView {
    var session: EditorSession?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// The canvas beneath takes every click; the overlay is only ink.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let session, let document = session.document,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = session.viewport.pointsPerPixel
        let lineScale = 1 / session.viewport.backingScale
        func viewRect(of rect: CGRect) -> CGRect {
            CGRect(origin: session.viewport.viewPoint(from: rect.origin, documentSize: document.size),
                   size: CGSize(width: rect.width * scale, height: rect.height * scale))
        }

        for artboard in document.artboards {
            let rect = viewRect(of: artboard.rect)
            let isActive = artboard.id == document.activeArtboardID
            let borderColor = isActive ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.4)
            context.setStrokeColor(borderColor.cgColor)
            context.setLineWidth(1.5 * lineScale)
            context.stroke(rect)

            // The name sits above the artboard's top-left corner, the size under the name.
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: borderColor
            ]
            let labelSize = artboard.name.size(withAttributes: labelAttrs)
            let labelPoint = CGPoint(x: rect.minX, y: rect.minY - labelSize.height - 4)
            artboard.name.draw(at: labelPoint, withAttributes: labelAttrs)

            let sizeText = "\(artboard.width) × \(artboard.height)"
            let sizeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6)
            ]
            let sizeSize = sizeText.size(withAttributes: sizeAttrs)
            sizeText.draw(at: CGPoint(x: rect.minX, y: labelPoint.y - sizeSize.height - 2), withAttributes: sizeAttrs)

            // Corner handles while the Artboard tool can grab them.
            if session.tool == .artboard {
                let handleSize: CGFloat = 6
                let half = handleSize / 2
                context.setFillColor(NSColor.white.cgColor)
                context.setStrokeColor(NSColor.systemBlue.cgColor)
                context.setLineWidth(lineScale)
                for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                    let handle = CGRect(x: corner.x - half, y: corner.y - half, width: handleSize, height: handleSize)
                    context.fill(handle)
                    context.stroke(handle)
                }
            }
        }

        // The rectangle being dragged out, dashed until it becomes an artboard.
        if let draft = session.artboardDraft {
            let rect = viewRect(of: draft.rect)
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineWidth(2 * lineScale)
            context.setLineDash(phase: 0, lengths: [4, 4])
            context.stroke(rect)
            context.setLineDash(phase: 0, lengths: [])
        }
    }
}
