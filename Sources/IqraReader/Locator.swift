import Foundation

let readerBundle = Bundle.module

/// Composite reading position (spec "Locator model"): the CFI is the precise coordinate,
/// progression fractions are display/fallback only — never anchors.
public struct Locator: Codable, Equatable, Sendable {
    public var spineIndex: Int
    public var spineHref: String?
    public var cfi: String?
    public var progressionInChapter: Double?
    public var totalProgression: Double
    public var tocLabel: String?
    public var textContext: TextContext?

    public init(spineIndex: Int, spineHref: String? = nil, cfi: String? = nil,
                progressionInChapter: Double? = nil, totalProgression: Double,
                tocLabel: String? = nil, textContext: TextContext? = nil) {
        self.spineIndex = spineIndex; self.spineHref = spineHref; self.cfi = cfi
        self.progressionInChapter = progressionInChapter
        self.totalProgression = totalProgression; self.tocLabel = tocLabel
        self.textContext = textContext
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }
    public static func from(jsonData: Data) throws -> Locator {
        try JSONDecoder().decode(Locator.self, from: jsonData)
    }
}

public struct TextContext: Codable, Equatable, Sendable {
    public var before: String
    public var highlight: String
    public var after: String
    public init(before: String, highlight: String, after: String) {
        self.before = before; self.highlight = highlight; self.after = after
    }
}

public enum AnnotationKind: String, Codable, Sendable, CaseIterable { case highlight, note, bookmark }

public enum HighlightColor: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple
    /// The fill color the foliate Overlayer draws (drawn OUTSIDE the themed iframe, so the
    /// color is explicit here rather than CSS-inherited). Opacity/blend are set on the
    /// renderer element separately.
    public var cssColor: String {
        switch self {
        case .yellow: "#F7D774"
        case .green:  "#A3E4A1"
        case .blue:   "#9EC9FF"
        case .pink:   "#FFB0C4"
        case .purple: "#D6B4FC"
        }
    }
}

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var locator: Locator
    public var color: HighlightColor?
    public var note: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public init(id: UUID, kind: AnnotationKind, locator: Locator, color: HighlightColor?,
                note: String?, createdAt: Date, modifiedAt: Date) {
        self.id = id; self.kind = kind; self.locator = locator; self.color = color
        self.note = note; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct SelectionRect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct SelectionInfo: Codable, Equatable, Sendable {
    public var text: String
    public var cfi: String
    public var rect: SelectionRect
    public var spineIndex: Int
    public var totalProgression: Double
    public var textContext: TextContext?
    public init(text: String, cfi: String, rect: SelectionRect, spineIndex: Int,
                totalProgression: Double, textContext: TextContext?) {
        self.text = text; self.cfi = cfi; self.rect = rect; self.spineIndex = spineIndex
        self.totalProgression = totalProgression; self.textContext = textContext
    }
}

public struct SearchHit: Codable, Equatable, Sendable, Identifiable {
    public var id: String { cfi }
    public var cfi: String
    public var excerptPre: String
    public var excerptMatch: String
    public var excerptPost: String
    public var sectionLabel: String?
    public init(cfi: String, excerptPre: String, excerptMatch: String, excerptPost: String,
                sectionLabel: String?) {
        self.cfi = cfi; self.excerptPre = excerptPre; self.excerptMatch = excerptMatch
        self.excerptPost = excerptPost; self.sectionLabel = sectionLabel
    }
}

public struct ReaderTheme: Codable, Equatable, Sendable {
    public var background: String
    public var foreground: String
    public init(background: String, foreground: String) {
        self.background = background; self.foreground = foreground
    }
    public static let light = ReaderTheme(background: "#ffffff", foreground: "#1a1a1a")
    public static let sepia = ReaderTheme(background: "#f4ecd8", foreground: "#5b4636")
    public static let dark  = ReaderTheme(background: "#121212", foreground: "#d6d6d6")
}

public struct ReaderSettings: Codable, Equatable, Sendable {
    public var fontSizePercent: Int
    public var fontFamily: String?
    public var lineHeight: Double
    public var justify: Bool
    public var theme: ReaderTheme
    public var flow: Flow
    public enum Flow: String, Codable, Sendable { case paginated, scrolled }

    public init(fontSizePercent: Int = 100, fontFamily: String? = nil, lineHeight: Double = 1.4,
                justify: Bool = false, theme: ReaderTheme = .light, flow: Flow = .paginated) {
        self.fontSizePercent = fontSizePercent; self.fontFamily = fontFamily
        self.lineHeight = lineHeight; self.justify = justify; self.theme = theme; self.flow = flow
    }
    public static let `default` = ReaderSettings()
}
