import Foundation
import CoreGraphics

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style, artboardID: layer.artboardID)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides,
            artboards: document.artboards.isEmpty ? nil : document.artboards,
            activeArtboardID: document.activeArtboardID), images: images, masks: masks)
    }

    /// One artboard's contents as their own document, sized to the artboard, for exporting it
    /// on its own. Layer placements shift so the artboard's top-left corner becomes the origin.
    func artboardSnapshot(_ artboardID: UUID) -> ProjectSnapshot? {
        guard let document, let artboard = document.artboards.first(where: { $0.id == artboardID }),
              let group = artboardGroup(artboardID) else { return nil }
        let ids = Self.artboardSubtree(of: group.id, in: document.layers)
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var records: [ProjectLayerRecord] = []
        // The group row stands for the board's rectangle, not for anything on it: what is exported is
        // the layers the board holds, at the board's own size with its top-left corner as the origin.
        for layer in document.layers where ids.contains(layer.id) && layer.id != group.id {
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            var transform = layer.transform
            transform.origin.x -= artboard.origin.x
            transform.origin.y -= artboard.origin.y
            var placement = layer.mask?.placement
            if placement != nil {
                placement?.origin.x -= artboard.origin.x
                placement?.origin.y -= artboard.origin.y
            }
            records.append(ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png",
                // The board's group row is not part of what is exported, so its own children become the top
                // level: anything else would nest under a layer the export does not have, and nothing draws.
                parentID: layer.parentID == group.id ? nil : layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity,
                blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png",
                maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment,
                maskPlacement: placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style,
                effects: layer.effects, text: layer.liveText?.style))
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id,
            width: artboard.width, height: artboard.height, activeLayerID: nil, layers: records),
            images: images, masks: masks)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                           effects: $0.effects,
                           text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image),
                           artboardID: $0.artboardID)
            }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [],
               artboards: manifest.artboards ?? [], activeArtboardID: manifest.activeArtboardID)
        activeLayerID = manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is session-only and starts over, as after an open.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int, resolution: Double = 72, background: CGColor? = nil) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true, resolution: resolution, background: background)
    }
}
