import AppKit

/// The installed fonts grouped the way Photoshop's Character panel groups them: a family list (Helvetica,
/// Avenir Next, …) and, within a family, its faces by style name (Regular, Bold, Italic, …). Built once from
/// `NSFontManager` on first use and cached, since scanning every family takes a moment.
@MainActor enum FontCatalog {
    struct Face { let postScriptName: String; let style: String }

    private static var loaded = false
    private static var families: [String] = []
    private static var facesByFamily: [String: [Face]] = [:]
    private static var familyByFace: [String: String] = [:]

    static func load() {
        guard !loaded else { return }
        loaded = true
        let manager = NSFontManager.shared
        var fams: [String] = []
        var byFamily: [String: [Face]] = [:]
        var byFace: [String: String] = [:]
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            var faces: [Face] = []
            for member in members {
                guard let ps = member.first as? String, !ps.isEmpty else { continue }
                let rawStyle = member.count > 1 ? (member[1] as? String) : nil
                let style = (rawStyle?.isEmpty == false) ? rawStyle! : ps
                faces.append(Face(postScriptName: ps, style: style))
                if byFace[ps] == nil { byFace[ps] = family }
            }
            if !faces.isEmpty { fams.append(family); byFamily[family] = faces }
        }
        families = fams.sorted()
        facesByFamily = byFamily
        familyByFace = byFace
    }

    /// All family names, sorted.
    static var allFamilies: [String] { load(); return families }

    /// The family a PostScript face name belongs to, or nil when it isn't a known face.
    static func family(of postScriptName: String) -> String? { load(); return familyByFace[postScriptName] }

    /// The faces in a family, in the order `NSFontManager` reports them (Regular first for most families).
    static func faces(ofFamily family: String) -> [Face] { load(); return facesByFamily[family] ?? [] }

    /// The face to switch to when a family is picked: keep the current style if the new family has it, otherwise
    /// its Regular, otherwise its first face.
    static func face(inFamily family: String, matchingStyle style: String?) -> Face? {
        let faces = faces(ofFamily: family)
        if let style, let exact = faces.first(where: { $0.style == style }) { return exact }
        return faces.first(where: { $0.style == "Regular" }) ?? faces.first
    }

    /// The style name of a face, for showing it in the style popup.
    static func style(of postScriptName: String) -> String? {
        faces(ofFamily: family(of: postScriptName) ?? "").first { $0.postScriptName == postScriptName }?.style
    }
}
