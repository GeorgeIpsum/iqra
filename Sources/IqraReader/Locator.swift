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

    public init(spineIndex: Int, spineHref: String? = nil, cfi: String? = nil,
                progressionInChapter: Double? = nil, totalProgression: Double,
                tocLabel: String? = nil) {
        self.spineIndex = spineIndex; self.spineHref = spineHref; self.cfi = cfi
        self.progressionInChapter = progressionInChapter
        self.totalProgression = totalProgression; self.tocLabel = tocLabel
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }
    public static func from(jsonData: Data) throws -> Locator {
        try JSONDecoder().decode(Locator.self, from: jsonData)
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
