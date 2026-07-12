/// A supported (DRM-free) book container format.
public enum FormatType: String, Codable, Sendable, CaseIterable {
    case epub, pdf, cbz, cbr, mobi

    public var fileExtension: String { rawValue }
}
