import AppKit

/// One anchor on a pen path: its position plus two bezier control handles. A corner point has both handles equal to
/// its position; a smooth point has them on opposite sides (a straight line through the anchor).
struct PenAnchorPoint: Equatable, Codable {
    var position: CGPoint
    /// The handle pulling the curve *into* this anchor (from the previous segment). Equal to `position` for corners.
    var controlIn: CGPoint
    /// The handle pulling the curve *out of* this anchor (toward the next segment). Equal to `position` for corners.
    var controlOut: CGPoint

    init(position: CGPoint, controlIn: CGPoint? = nil, controlOut: CGPoint? = nil) {
        self.position = position
        self.controlIn = controlIn ?? position
        self.controlOut = controlOut ?? position
    }

    /// True when both handles sit on the anchor — a sharp corner, not a curve.
    var isCorner: Bool { controlIn == position && controlOut == position }
}

/// A pen path being drawn or already committed: a list of anchor points, optionally closed.
struct PenPath: Equatable {
    var points: [PenAnchorPoint]
    var isClosed: Bool = false

    var isEmpty: Bool { points.isEmpty }

    /// The CGPath this path describes, for rasterization or hit-testing.
    nonisolated func cgPath() -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first.position)
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            path.addCurve(to: curr.position, control1: prev.controlOut, control2: curr.controlIn)
        }
        if isClosed { path.closeSubpath() }
        return path
    }

    /// The bounding box of every anchor and handle, with a little room for the stroke.
    nonisolated func bounds(strokeWidth: CGFloat = 0) -> CGRect {
        var rect = CGRect.null
        for p in points {
            rect = rect.union(CGRect(origin: p.position, size: .zero))
            rect = rect.union(CGRect(origin: p.controlIn, size: .zero))
            rect = rect.union(CGRect(origin: p.controlOut, size: .zero))
        }
        return rect.insetBy(dx: -strokeWidth, dy: -strokeWidth)
    }
}

/// The pen tool's in-progress gesture: the path so far, the anchor being placed or dragged, and where the pointer is.
struct PenDraft: Equatable {
    /// The committed anchors (clicked and released without a drag, or the previous anchors).
    var path: PenPath
    /// The anchor currently being placed: where the last mouseDown landed.
    var currentAnchor: PenAnchorPoint
    /// Where the pointer is during a drag (pulling the bezier handles out).
    var dragPosition: CGPoint?
    /// True while the mouse button is held and handles are being dragged.
    var isDragging: Bool = false

    /// The path as it stands, including the in-progress anchor and its handles.
    var previewPath: PenPath {
        var p = path
        if isDragging, let drag = dragPosition {
            // The handles mirror around the anchor: dragging one pulls the other opposite.
            let anchor = currentAnchor.position
            let controlOut = drag
            let controlIn = CGPoint(x: 2 * anchor.x - drag.x, y: 2 * anchor.y - drag.y)
            p.points.append(PenAnchorPoint(position: anchor, controlIn: controlIn, controlOut: controlOut))
        } else {
            p.points.append(currentAnchor)
        }
        return p
    }
}

/// How the pen tool's finished path is used: fill it as a shape, stroke it, or turn it into a selection.
enum PenOutputMode: String, CaseIterable {
    case shape = "Shape"
    case selection = "Selection"
    case path = "Path"
}

extension EditorSession {
    /// Starts a new pen path at the given document point (the first anchor).
    func beginPen(at point: CGPoint) {
        guard tool == .pen, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        let snapped = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        let anchor = PenAnchorPoint(position: snapped)
        penDraft = PenDraft(path: PenPath(points: []), currentAnchor: anchor, isDragging: false)
    }

    /// A click with an existing draft: start placing the next anchor at the given point.
    func beginNextPenAnchor(at point: CGPoint) {
        guard var draft = penDraft, point.x.isFinite, point.y.isFinite else { return }
        let snapped = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        // Commit the current anchor first (it was placed on the previous mouseUp).
        draft.path.points.append(draft.currentAnchor)
        draft.currentAnchor = PenAnchorPoint(position: snapped)
        draft.isDragging = false
        draft.dragPosition = nil
        penDraft = draft
    }

    /// The pointer moved while the button is held: pull the bezier handles out from the anchor.
    func dragPen(to point: CGPoint) {
        guard var draft = penDraft, point.x.isFinite, point.y.isFinite else { return }
        draft.isDragging = true
        draft.dragPosition = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        penDraft = draft
    }

    /// The button came up: commit the anchor. A click without drag makes a corner; a drag makes a smooth point.
    func finishPenAnchor() {
        guard var draft = penDraft else { return }
        var anchor = draft.currentAnchor
        if draft.isDragging, let drag = draft.dragPosition {
            let pos = anchor.position
            anchor.controlOut = drag
            anchor.controlIn = CGPoint(x: 2 * pos.x - drag.x, y: 2 * pos.y - drag.y)
        }
        draft.path.points.append(anchor)
        draft.currentAnchor = anchor
        draft.isDragging = false
        draft.dragPosition = nil
        penDraft = draft
    }

    /// Clicked near the first anchor: close the path.
    func closePenPath() {
        guard var draft = penDraft, draft.path.points.count >= 2 else { return }
        draft.path.isClosed = true
        penDraft = draft
        commitPenPath()
    }

    /// Removes the last anchor placed.
    func removeLastPenPoint() {
        guard var draft = penDraft else { return }
        if draft.isDragging {
            draft.isDragging = false
            draft.dragPosition = nil
            penDraft = draft
        } else if !draft.path.points.isEmpty {
            draft.path.points.removeLast()
            if let last = draft.path.points.last {
                draft.currentAnchor = last
            }
            penDraft = draft
        }
    }

    /// Escape: throw the whole path away.
    func cancelPen() {
        penDraft = nil
    }

    /// Enter or Return on an open path: commit what's there.
    func commitPenOpenPath() {
        guard penDraft != nil else { return }
        commitPenPath()
    }

    /// Rasterize the path and make it a layer (shape mode) or a selection (selection mode).
    private func commitPenPath() {
        guard let draft = penDraft else { return }
        let path = draft.previewPath
        penDraft = nil

        guard path.points.count >= 2 else { return }

        switch penOutputMode {
        case .selection:
            commitPenAsSelection(path)
        case .shape:
            commitPenAsShape(path)
        case .path:
            // Path mode keeps the vector path on the session for now; a future enhancement could store it on the layer.
            // For now, convert to a shape as a sensible default.
            commitPenAsShape(path)
        }
    }

    private func commitPenAsShape(_ path: PenPath) {
        guard canEditLayers else { return }
        let strokeWidth = CGFloat(penStrokeWidth)
        let bounds = path.bounds(strokeWidth: strokeWidth / 2).integral
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        let pixelCount = Int(bounds.width) * Int(bounds.height)
        guard pixelCount <= Self.maxShapePixels else {
            brushError = "That path is too large. A path can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
            return
        }
        guard let image = Self.penPathImage(path, size: bounds.size, color: foregroundColor,
                                            strokeWidth: strokeWidth, filled: penFillsShape) else { return }
        addPixelLayer(image, at: bounds.origin, name: nextPenName(), editName: "Pen",
                      dropsSelection: false)
    }

    private func commitPenAsSelection(_ path: PenPath) {
        let cgPath = path.cgPath()
        setSelection(DocumentSelection(path: cgPath, antialiased: selectionAntialiased), name: "Pen Selection")
    }

    private func nextPenName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Path \(number)") { number += 1 }
        return "Path \(number)"
    }

    /// Rasterize a pen path into a CGImage: the filled or stroked bezier curves, anti-aliased.
    nonisolated static func penPathImage(_ path: PenPath, size: CGSize, color: PaletteColor,
                                         strokeWidth: CGFloat, filled: Bool) -> CGImage? {
        guard let context = try? BrushRaster.context(width: max(1, Int(size.width)), height: max(1, Int(size.height)), mask: false) else { return nil }
        let cgPath = path.cgPath()
        // Translate so the path's bounding-box origin lands at (0, 0) in the context.
        let bounds = path.bounds(strokeWidth: 0)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
        context.addPath(cgPath)
        if filled {
            context.fillPath()
        } else {
            context.setLineWidth(max(1, strokeWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        return context.makeImage()
    }

    /// Whether the pointer is close enough to the first anchor to close the path (10 document pixels).
    func penCanClose(at point: CGPoint) -> Bool {
        guard let draft = penDraft, let first = draft.path.points.first, draft.path.points.count >= 2 else { return false }
        let dx = point.x - first.position.x, dy = point.y - first.position.y
        return hypot(dx, dy) <= 10
    }
}
