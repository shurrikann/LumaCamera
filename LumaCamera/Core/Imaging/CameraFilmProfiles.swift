import CoreImage

/// Named camera profiles use the user's colour tables, shared by every rendering path.
enum CameraFilmProfiles {
    static func apply(_ style: FilmStyle, to input: CIImage) -> CIImage {
        guard let definition = ImportedFilterCatalog.definition(for: style) else { return input }
        return ImportedFilterCatalog.apply(definition, to: input)
    }
}
