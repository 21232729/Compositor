import Foundation
import CoreGraphics

/// A bounded canvas region within a multi-artboard document. Each artboard has its own
/// coordinate space starting at (0, 0), and layers scoped to it are positioned relative
/// to the artboard's origin in document space.
struct Artboard: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    /// Position in document coordinates (top-left corner).
    var origin: CGPoint
    var width: Int
    var height: Int

    var size: CGSize { CGSize(width: width, height: height) }
    var rect: CGRect { CGRect(origin: origin, size: size) }

    init(id: UUID = UUID(), name: String, origin: CGPoint, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.origin = origin
        self.width = width
        self.height = height
    }

    /// Convert a point from artboard-local coordinates to document coordinates.
    func documentPoint(fromArtboardPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    /// Convert a point from document coordinates to artboard-local coordinates.
    func artboardPoint(fromDocumentPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// Check if a document-space point falls within this artboard.
    func contains(documentPoint point: CGPoint) -> Bool {
        rect.contains(point)
    }
}

// MARK: - EditorSession Artboard Support

extension EditorSession {
    /// The active artboard object, if any.
    var activeArtboard: Artboard? {
        guard let id = document?.activeArtboardID, let artboards = document?.artboards else { return nil }
        return artboards.first { $0.id == id }
    }

    /// Whether the document uses artboards (multi-artboard mode).
    var usesArtboards: Bool {
        guard let doc = document else { return false }
        return !doc.artboards.isEmpty
    }

    /// Create a new artboard at the specified position.
    func addArtboard(name: String? = nil, origin: CGPoint, width: Int, height: Int) {
        guard canEditLayers, let doc = document else { return }
        let artboardName = name ?? "Artboard \(doc.artboards.count + 1)"
        let artboard = Artboard(name: artboardName, origin: origin, width: width, height: height)
        beginEdit("Add Artboard")
        defer { endEdit() }
        document?.artboards.append(artboard)
        // The artboard shows in the Layers panel as its own group, as in Photoshop: layers made
        // while it is active land inside it, and exporting it renders just its contents. Board
        // groups sit at the very top level, never inside another board — one that was nested
        // would not be its own canvas region, and clicking it would edit the board around it.
        var group = ImageLayer(name: artboardName, blankSize: doc.size)
        group.isGroup = true
        group.parentID = nil
        group.artboardID = artboard.id
        document?.layers.append(group)
        // A layer inside a board group belongs to that board, and a board group's own layers are
        // the ones the board owns; the group's id is not a board.
        for i in document?.layers.indices ?? 0..<0 where document?.layers[i].parentID == group.id {
            document?.layers[i].artboardID = nil
        }
        collapsedGroupIDs.remove(group.id)
        // The board just made is the one being edited, so a brush or the New Layer button lands in it.
        document?.activeArtboardID = artboard.id
        activeLayerID = group.id
    }

    /// Remove an artboard and optionally its layers.
    func removeArtboard(_ id: UUID, removeLayers: Bool = true) {
        guard canEditLayers, let doc = document, let index = doc.artboards.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Delete Artboard")
        defer { endEdit() }
        document?.artboards.remove(at: index)
        let groupID = doc.layers.first { $0.isGroup && $0.artboardID == id }?.id
        let doomed = groupID.map { Self.artboardSubtree(of: $0, in: doc.layers) } ?? []
        if removeLayers {
            document?.layers.removeAll { doomed.contains($0.id) }
        } else {
            for i in document?.layers.indices ?? 0..<0 {
                if document?.layers[i].artboardID == id { document?.layers[i].artboardID = nil }
                if document?.layers[i].parentID == groupID { document?.layers[i].parentID = nil }
            }
            if let groupID { document?.layers.removeAll { $0.id == groupID } }
        }
        if let active = activeLayerID, doomed.contains(active) { activeLayerID = nil }
        if document?.activeArtboardID == id {
            document?.activeArtboardID = document?.artboards.first?.id
        }
    }

    /// Move an artboard to a new position.
    func moveArtboard(_ id: UUID, to origin: CGPoint) {
        guard canEditLayers, let index = document?.artboards.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Move Artboard")
        defer { endEdit() }
        document?.artboards[index].origin = origin
    }

    /// Resize an artboard.
    func resizeArtboard(_ id: UUID, width: Int, height: Int) {
        guard canEditLayers, let index = document?.artboards.firstIndex(where: { $0.id == id }) else { return }
        beginEdit("Resize Artboard")
        defer { endEdit() }
        document?.artboards[index].width = width
        document?.artboards[index].height = height
    }

    /// Set the active artboard.
    func setActiveArtboard(_ id: UUID?) {
        document?.activeArtboardID = id
        // Selecting an artboard selects its group in the Layers panel, so new layers and
        // painting land inside it, as in Photoshop.
        if let id, let group = artboardGroup(id) {
            activeLayerID = group.id
            collapsedGroupIDs.remove(group.id)
        }
    }

    /// The board being edited becomes this one, and something on it is picked to work on: its topmost layer
    /// where it has one, its group row where it has none — so a stroke starts on a layer, and on an empty
    /// board it makes one. Returns whether the board changed.
    @discardableResult
    func focusArtboard(_ id: UUID) -> Bool {
        guard document?.activeArtboardID != id else { return false }
        setActiveArtboard(id)
        guard let group = artboardGroup(id) else { return true }
        // Bottom to top in document order, so the last one is what the Layers panel shows on top.
        if let top = document?.layers.last(where: { $0.parentID == group.id && !$0.isGroup }) {
            activeLayerID = top.id
        } else {
            activeLayerID = group.id
        }
        return true
    }

    /// The group layer standing for an artboard in the Layers panel, if any.
    func artboardGroup(_ artboardID: UUID) -> ImageLayer? {
        document?.layers.first { $0.isGroup && $0.artboardID == artboardID }
    }

    /// The board a layer's pixels belong to: the board whose group holds it, walked up through any folders in
    /// between. Nothing, for a layer outside every board — and for a board's own group row, which stands for the
    /// rectangle and has no pixels of its own.
    func artboard(owning layer: ImageLayer) -> Artboard? {
        guard let document, usesArtboards else { return nil }
        if layer.isGroup, layer.artboardID != nil { return nil }
        if let own = layer.artboardID { return document.artboards.first { $0.id == own } }
        var parent = layer.parentID
        var steps = 0
        while let id = parent, steps < 64 {
            guard let group = document.layers.first(where: { $0.id == id }) else { return nil }
            if let boardID = group.artboardID { return document.artboards.first { $0.id == boardID } }
            parent = group.parentID
            steps += 1
        }
        return nil
    }

    /// Where a layer made now belongs: inside the folder that is selected, or on the board being edited —
    /// the board's own group, and the board itself when the new layer should take its size and corner.
    /// Nil parent means the top level of a document without artboards.
    func newLayerPlacement(boardSize: Bool) -> (parent: UUID?, board: Artboard?) {
        guard let document else { return (nil, nil) }
        // A selected folder takes the new layer, wherever it sits: a folder nested in another one is still the
        // folder being worked in, not a sibling of it. (This used to ask after the parent, which made a nested
        // folder's new layer land beside the folder instead of inside it.)
        if activeLayer?.isGroup == true, activeLayer?.artboardID == nil { return (activeLayerID, nil) }
        // Already inside a folder or a board: the new layer joins it, as it always has.
        if let layer = activeLayer, let parent = layer.parentID { return (parent, nil) }
        let board = document.activeArtboardID.flatMap { id in document.artboards.first { $0.id == id } }
        guard usesArtboards, let board, let group = artboardGroup(board.id) else { return (nil, nil) }
        return (group.id, boardSize ? board : nil)
    }

    /// A layer and everything nested inside it, by parentID.
    static func artboardSubtree(of root: UUID, in layers: [ImageLayer]) -> Set<UUID> {
        var children: [UUID?: [UUID]] = [:]
        for layer in layers { children[layer.parentID, default: []].append(layer.id) }
        var result: Set<UUID> = []
        var stack = [root]
        while let id = stack.popLast() {
            result.insert(id)
            stack.append(contentsOf: children[id] ?? [])
        }
        return result
    }

    /// Get layers belonging to a specific artboard.
    func layers(forArtboard artboardID: UUID) -> [ImageLayer] {
        guard let doc = document, let group = artboardGroup(artboardID) else { return [] }
        let ids = Self.artboardSubtree(of: group.id, in: doc.layers)
        return doc.layers.filter { ids.contains($0.id) && $0.id != group.id }
    }

    /// Convert a document-space point to the active artboard's local coordinates.
    func toArtboardCoordinates(_ point: CGPoint) -> CGPoint? {
        guard let artboard = activeArtboard else { return point }
        return artboard.artboardPoint(fromDocumentPoint: point)
    }

    /// Convert a point from active artboard coordinates to document coordinates.
    func fromArtboardCoordinates(_ point: CGPoint) -> CGPoint {
        guard let artboard = activeArtboard else { return point }
        return artboard.documentPoint(fromArtboardPoint: point)
    }
}

/// In-progress artboard creation drag.
struct ArtboardDraft: Equatable {
    var start: CGPoint
    var current: CGPoint
    var artboardID: UUID?

    var rect: CGRect {
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// In-progress artboard move or resize.
struct ArtboardEdit: Equatable {
    enum Mode { case move, resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight }
    var artboardID: UUID
    var mode: Mode
    var originalArtboard: Artboard
    var startMouse: CGPoint
}

// MARK: - Artboard Tool Actions

extension EditorSession {
    func beginArtboardCreation(at point: CGPoint) {
        guard canEditLayers else { return }
        artboardDraft = ArtboardDraft(start: point, current: point)
    }

    func updateArtboardCreation(to point: CGPoint) {
        artboardDraft?.current = point
    }

    func commitArtboardCreation() {
        guard let draft = artboardDraft else { return }
        let rect = draft.rect
        let width = max(1, Int(rect.width))
        let height = max(1, Int(rect.height))
        if width >= 10 && height >= 10 {
            addArtboard(origin: rect.origin, width: width, height: height)
        }
        artboardDraft = nil
    }

    func cancelArtboardCreation() {
        artboardDraft = nil
    }

    func beginArtboardMove(artboardID: UUID, at point: CGPoint) {
        guard canEditLayers, let artboard = document?.artboards.first(where: { $0.id == artboardID }) else { return }
        beginEdit("Move Artboard")
        artboardEdit = ArtboardEdit(artboardID: artboardID, mode: .move, originalArtboard: artboard, startMouse: point)
    }

    func beginArtboardResize(artboardID: UUID, corner: ArtboardEdit.Mode, at point: CGPoint) {
        guard canEditLayers, let artboard = document?.artboards.first(where: { $0.id == artboardID }) else { return }
        beginEdit("Resize Artboard")
        artboardEdit = ArtboardEdit(artboardID: artboardID, mode: corner, originalArtboard: artboard, startMouse: point)
    }

    func updateArtboardEdit(to point: CGPoint) {
        guard let edit = artboardEdit, let index = document?.artboards.firstIndex(where: { $0.id == edit.artboardID }) else { return }
        let dx = point.x - edit.startMouse.x
        let dy = point.y - edit.startMouse.y

        switch edit.mode {
        case .move:
            document?.artboards[index].origin = CGPoint(
                x: edit.originalArtboard.origin.x + dx,
                y: edit.originalArtboard.origin.y + dy
            )
        case .resizeTopLeft:
            let newOrigin = CGPoint(
                x: edit.originalArtboard.origin.x + dx,
                y: edit.originalArtboard.origin.y + dy
            )
            let newWidth = max(10, Int(CGFloat(edit.originalArtboard.width) - dx))
            let newHeight = max(10, Int(CGFloat(edit.originalArtboard.height) - dy))
            document?.artboards[index].origin = newOrigin
            document?.artboards[index].width = newWidth
            document?.artboards[index].height = newHeight
        case .resizeTopRight:
            let newOrigin = CGPoint(
                x: edit.originalArtboard.origin.x,
                y: edit.originalArtboard.origin.y + dy
            )
            let newWidth = max(10, Int(CGFloat(edit.originalArtboard.width) + dx))
            let newHeight = max(10, Int(CGFloat(edit.originalArtboard.height) - dy))
            document?.artboards[index].origin = newOrigin
            document?.artboards[index].width = newWidth
            document?.artboards[index].height = newHeight
        case .resizeBottomLeft:
            let newOrigin = CGPoint(
                x: edit.originalArtboard.origin.x + dx,
                y: edit.originalArtboard.origin.y
            )
            let newWidth = max(10, Int(CGFloat(edit.originalArtboard.width) - dx))
            let newHeight = max(10, Int(CGFloat(edit.originalArtboard.height) + dy))
            document?.artboards[index].origin = newOrigin
            document?.artboards[index].width = newWidth
            document?.artboards[index].height = newHeight
        case .resizeBottomRight:
            let newWidth = max(10, Int(CGFloat(edit.originalArtboard.width) + dx))
            let newHeight = max(10, Int(CGFloat(edit.originalArtboard.height) + dy))
            document?.artboards[index].width = newWidth
            document?.artboards[index].height = newHeight
        }
    }

    func commitArtboardEdit() {
        artboardEdit = nil
        endEdit()
    }

    func cancelArtboardEdit() {
        guard let edit = artboardEdit, let index = document?.artboards.firstIndex(where: { $0.id == edit.artboardID }) else {
            artboardEdit = nil
            return
        }
        document?.artboards[index] = edit.originalArtboard
        artboardEdit = nil
        endEdit()
    }

    /// Find the artboard at a document point, if any.
    func artboard(at point: CGPoint) -> Artboard? {
        document?.artboards.first { $0.contains(documentPoint: point) }
    }

    /// Check if a point is near an artboard corner handle.
    func artboardCorner(at point: CGPoint, handleRadius: CGFloat = 8) -> (artboardID: UUID, mode: ArtboardEdit.Mode)? {
        guard let doc = document else { return nil }
        for artboard in doc.artboards {
            let rect = artboard.rect
            let corners: [(CGPoint, ArtboardEdit.Mode)] = [
                (rect.origin, .resizeTopLeft),
                (CGPoint(x: rect.maxX, y: rect.minY), .resizeTopRight),
                (CGPoint(x: rect.minX, y: rect.maxY), .resizeBottomLeft),
                (CGPoint(x: rect.maxX, y: rect.maxY), .resizeBottomRight)
            ]
            for (corner, mode) in corners {
                if hypot(point.x - corner.x, point.y - corner.y) <= handleRadius {
                    return (artboard.id, mode)
                }
            }
        }
        return nil
    }

    /// Opens the exact-size editor for the board under a point (in document coordinates), if there is one.
    /// Right-clicking an artboard's size label routes here; the sheet the request drives takes the typed width
    /// and height and calls `resizeArtboard`.
    func beginArtboardResize(at point: CGPoint) {
        guard usesArtboards, let board = artboard(at: point) else { return }
        artboardResize = ArtboardResizeTarget(id: board.id, name: board.name, width: board.width, height: board.height)
    }
}

/// What the artboard size sheet edits: the board's identity plus working copies of its size.
struct ArtboardResizeTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
    var width: Int
    var height: Int
}
