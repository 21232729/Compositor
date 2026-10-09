import AppKit
import Testing
@testable import Compositor

/// Serialized: copying a layer goes through the system pasteboard, which the whole process shares.
@MainActor
@Suite(.serialized)
struct ArtboardTests {
    /// Three artboards in one document, each with a layer of its own — the shape the Artboards to Files export
    /// and the Layers panel both assume.
    private func threeArtboards() throws -> (session: EditorSession, ids: [UUID], groups: [UUID], layers: [UUID]) {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        var ids: [UUID] = [], groups: [UUID] = [], layers: [UUID] = []
        for index in 0..<3 {
            session.addArtboard(origin: CGPoint(x: index * 200, y: 0), width: 180, height: 180)
            ids.append(try #require(session.document?.artboards.last?.id))
            groups.append(try #require(session.activeLayerID))
            session.addBlankLayer()
            layers.append(try #require(session.activeLayerID))
        }
        return (session, ids, groups, layers)
    }

    @Test func artboardsSitAtTheTopLevelWithTheirOwnLayers() throws {
        let (session, _, groups, layers) = try threeArtboards()
        for group in groups {
            #expect(session.document?.layers.first(where: { $0.id == group })?.parentID == nil)
        }
        // Each layer belongs to the artboard it was made in, and to no other.
        for (index, layer) in layers.enumerated() {
            #expect(session.document?.layers.first(where: { $0.id == layer })?.parentID == groups[index])
            #expect(session.document?.layers.first(where: { $0.id == layer })?.artboardID == nil)
        }
        #expect(Set(session.layers(forArtboard: try #require(session.document?.artboards[0].id)).map(\.id)) == [layers[0]])
    }

    /// Creating a second artboard while the first one's group is selected must not nest it inside that group,
    /// which is what left the later artboards uneditable on the canvas.
    @Test func newArtboardsDoNotNestInsideTheSelectedOnes() throws {
        let (session, ids, groups, _) = try threeArtboards()
        #expect(session.document?.artboards.count == 3)
        // The active artboard follows the artboard being made, never stays on the first.
        #expect(session.document?.activeArtboardID == ids[2])
        session.setActiveArtboard(ids[0])
        #expect(session.activeArtboard?.id == ids[0])
        #expect(session.activeLayerID == groups[0])
    }

    /// The selected layers Copy and Duplicate take whole, in document order, leaving out any inside a selected folder.
    /// An artboard is copied whole: choosing its group row takes the board and everything on it, so Paste brings
    /// back a board with its contents rather than an empty one.
    @Test func copyingAnArtboardTakesItsLayersWithIt() throws {
        let (session, ids, groups, layers) = try threeArtboards()
        session.setActiveArtboard(ids[1])
        let before = try #require(session.document)

        session.copySelection()
        let copied = try #require(session.copiedLayer).ids
        // The board's group row and the layer on it, and nothing from the boards either side.
        #expect(Set(copied) == [groups[1], layers[1]])
        // Paste puts the board back complete, clear of the one it was copied from.
        session.duplicateLayers(copied, editName: "Paste")

        let after = try #require(session.document)
        #expect(after.artboards.count == before.artboards.count + 1)
        let copy = try #require(after.artboards.last)
        #expect(copy.name == before.artboards[1].name + " copy")
        #expect(copy.width == before.artboards[1].width && copy.height == before.artboards[1].height)
        // Dropped clear of the original, so the two read as separate boards.
        #expect(copy.origin.x > before.artboards[1].origin.x + CGFloat(before.artboards[1].width))

        let copyGroup = try #require(session.artboardGroup(copy.id))
        #expect(copyGroup.parentID == nil)
        #expect(copyGroup.artboardID == copy.id)
        #expect(copyGroup.id != groups[1])
        let contents = session.layers(forArtboard: copy.id)
        #expect(contents.count == 1)
        // The content moved with its artboard, so it still sits where it was drawn on the board.
        let original = try #require(after.layers.first(where: { $0.id == layers[1] }))
        let moved = try #require(contents.first)
        #expect(moved.transform.origin.x == original.transform.origin.x + copy.origin.x - before.artboards[1].origin.x)
        #expect(moved.transform.origin.y == original.transform.origin.y + copy.origin.y - before.artboards[1].origin.y)
        // The artboards it did not copy are untouched.
        #expect(session.layers(forArtboard: ids[0]).count == 1)
        #expect(session.layers(forArtboard: ids[2]).count == 1)
    }

    @Test func duplicatingAnArtboardCopiesItsLayersInOneStep() throws {
        let (session, _, groups, _) = try threeArtboards()
        session.selectLayer(groups[2])
        let before = session.document?.layers.count ?? 0
        session.duplicateActiveLayer()
        // The board, the layer on it, and the new rectangle: one copy, not two of the layer inside.
        #expect(session.document?.layers.count == before + 2)
        #expect(session.document?.artboards.count == 4)
        let copy = try #require(session.document?.artboards.last)
        #expect(copy.name == "Artboard 3 copy")
        #expect(session.layers(forArtboard: copy.id).count == 1)
        session.undo()
        #expect(session.document?.layers.count == before)
        #expect(session.document?.artboards.count == 3)
    }

    /// Exporting one artboard must render only its own contents at its own size.
    @Test func exportingAnArtboardRendersOnlyItsOwnLayers() throws {
        let (session, ids, _, layers) = try threeArtboards()
        let snapshot = try #require(session.artboardSnapshot(ids[1]))
        #expect(snapshot.manifest.layers.map { $0.id } == [layers[1]])
        #expect(snapshot.manifest.width == 180 && snapshot.manifest.height == 180)
        #expect(snapshot.manifest.layers.allSatisfy { $0.isGroup != true })
        #expect(snapshot.manifest.layers.first?.transform.origin == .zero)
    }

    /// The artboard under a canvas point is what a click on the canvas should edit.
    @Test func theArtboardUnderAPointIsTheOneAClickEdits() throws {
        let (session, ids, groups, _) = try threeArtboards()
        session.setActiveArtboard(ids[0])
        let second = try #require(session.artboard(at: CGPoint(x: 250, y: 90)))
        #expect(second.id == ids[1])
        session.setActiveArtboard(second.id)
        #expect(session.activeArtboard?.id == ids[1])
        #expect(session.activeLayerID == groups[1])
        // The gap between boards belongs to no artboard.
        #expect(session.artboard(at: CGPoint(x: 390, y: 90)) == nil)
        #expect(session.artboard(at: CGPoint(x: 20, y: 380)) == nil)
    }

    /// Painting on a board makes a layer on that board, at the board's corner, and the stroke lands where the
    /// pointer was — the whole point of an artboard being its own canvas region.
    @Test func paintingOnABoardPaintsWhereThePointerWas() async throws {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        session.addArtboard(origin: CGPoint(x: 200, y: 0), width: 180, height: 180)
        let group = try #require(session.activeLayerID)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 1, green: 0, blue: 0)

        session.beginBrush(at: CGPoint(x: 290, y: 90))
        // The board's group row has no pixels of its own, so a stroke starts a layer on the board: the
        // board's own size, at the board's corner.
        #expect(session.activeLayer?.parentID == group)
        #expect(session.activeLayer?.id != group)
        #expect(session.activeLayer?.size == CGSize(width: 180, height: 180))
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 200, y: 0))
        session.continueBrush(at: CGPoint(x: 300, y: 90))
        await session.finishBrush()

        // The stroke ends up where the pointer was, not at the canvas corner — the layer it leaves behind
        // covers just the part it touched.
        let layer = try #require(session.activeLayer)
        #expect(layer.parentID == group)
        #expect(layer.id != group)
        #expect(layer.transform.origin == CGPoint(x: 280, y: 80))
        let painted = try #require(layer.asset?.image)
        #expect(painted.width > 0 && painted.height > 0)
        #expect(bounds(ofRedPixelsIn: painted) != nil,
                "painted \(painted.width)x\(painted.height) has no red")
        // And the board shows it there: exporting the board alone puts the same stroke in the same place,
        // with the board's corner as the origin.
        let boardID = try #require(session.document?.artboards.first?.id)
        let snapshot = try #require(session.artboardSnapshot(boardID))
        let boardLayer = try #require(snapshot.manifest.layers.first)
        #expect(snapshot.manifest.layers.count == 1)
        #expect(boardLayer.transform.origin == CGPoint(x: 80, y: 80))
        let rendered = try await ImageExporter.shared.render(snapshot).image
        let marked = try #require(bounds(ofRedPixelsIn: rendered),
                                  "rendered \(rendered.width)x\(rendered.height) has no red")
        // The stroke's own box, in the board's coordinates: it sits around where the pointer was, well
        // clear of the board's corner.
        #expect(marked.midX == 95 && marked.midY == 90, "red at \(marked)")
        #expect(marked.minX > 40 && marked.minY > 40, "red at \(marked)")
    }

    /// Clicking a board picks something on it to work on: its topmost layer where it has one, its group row
    /// where it has none, so a stroke on a bare board starts a layer instead of landing on the group.
    @Test func clickingABoardPicksWhatToEdit() throws {
        let (session, ids, groups, layers) = try threeArtboards()
        // On a board with a layer, its topmost layer is what a click works on.
        session.focusArtboard(ids[0])
        #expect(session.activeArtboard?.id == ids[0])
        #expect(session.activeLayerID == layers[0])

        // A bare board has no layer, so its group row is what is picked.
        session.addArtboard(origin: CGPoint(x: 0, y: 220), width: 180, height: 180)
        let bare = try #require(session.document?.artboards.last?.id)
        let bareGroup = try #require(session.artboardGroup(bare))
        session.focusArtboard(ids[1])
        session.focusArtboard(bare)
        #expect(session.activeLayerID == bareGroup.id)

        // And working on that bare board makes a layer on it, not on the board it was on before.
        session.addBlankLayer()
        let made = try #require(session.activeLayerID)
        #expect(session.document?.layers.first { $0.id == made }?.parentID == bareGroup.id)
        #expect(session.document?.layers.first { $0.id == made }?.artboardID == nil)
        #expect(session.layers(forArtboard: ids[1]).count == 1)
    }

    /// Everything made while a board is being edited lands on that board — a pasted image, a typed layer, a
    /// drawn shape — because that is the surface the user is working on.
    @Test func pastedPixelsLandOnTheEditedBoard() throws {
        // The artboards come from the shared helper, which focuses the last one it made.
        let (session, ids, _, _) = try threeArtboards()
        let board = try #require(session.document?.artboards[1])
        session.focusArtboard(ids[1])
        let group = try #require(session.artboardGroup(ids[1]))
        let image = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        session.addPixelLayer(image, at: CGPoint(x: board.origin.x + 10, y: board.origin.y + 10), name: "Pasted", editName: "Paste")
        let pasted = try #require(session.activeLayer)
        #expect(pasted.parentID == group.id)
        #expect(session.layers(forArtboard: ids[1]).contains { $0.id == pasted.id })
        #expect(!session.layers(forArtboard: ids[0]).contains { $0.id == pasted.id })
        #expect(!session.layers(forArtboard: ids[2]).contains { $0.id == pasted.id })
    }

    /// Exporting a board to a file is what "Export Artboards…" does: the PNG must be the board's own size and
    /// hold what is on the board, not a blank rectangle.
    @Test func exportingABoardToDiskWritesWhatIsOnIt() async throws {
        let session = EditorSession()
        session.createDocument(width: 600, height: 400)
        session.addArtboard(origin: CGPoint(x: 200, y: 0), width: 180, height: 180)
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 24, hardness: 1, red: 0, green: 1, blue: 0)
        session.beginBrush(at: CGPoint(x: 290, y: 90))
        session.continueBrush(at: CGPoint(x: 300, y: 90))
        await session.finishBrush()

        let boardID = try #require(session.document?.artboards.first?.id)
        let snapshot = try #require(session.artboardSnapshot(boardID))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compositor-artboard-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ImageExporter.shared.exportPNG(snapshot, to: url)

        let data = try Data(contentsOf: url)
        let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
        #expect(image.width == 180 && image.height == 180)
        let marked = try #require(bounds(ofGreenPixelsIn: image), "exported \(image.width)x\(image.height) has no green")
        #expect(marked.midX == 95 && marked.midY == 90, "green at \(marked)")
    }

    /// The box a green mark covers, in the image's own top-left coordinates.
    private func bounds(ofGreenPixelsIn image: CGImage) -> CGRect? {
        bounds(ofPixelsIn: image) { $0[1] > 200 && $0[0] < 60 && $0[2] < 60 && $0[3] > 200 }
    }

    /// The box a red mark covers, in the document's own top-left coordinates: for checking that a stroke landed
    /// where the pointer was.
    private func bounds(ofRedPixelsIn image: CGImage) -> CGRect? {
        bounds(ofPixelsIn: image) { $0[0] > 200 && $0[1] < 60 && $0[2] < 60 && $0[3] > 200 }
    }

    /// The box the pixels matching `test` cover. The export is drawn into a flipped context, so rows are read
    /// bottom up to keep the answer in the document's own top-left coordinates.
    private func bounds(ofPixelsIn image: CGImage, _ test: ([Int]) -> Bool) -> CGRect? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = ((image.height - 1 - y) * image.width + x) * 4
                guard test((0..<4).map { Int(bytes[index + $0]) }) else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
