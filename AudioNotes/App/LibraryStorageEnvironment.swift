import SwiftUI

extension EnvironmentValues {
    /// The managed-file root of the library the app opened (a temporary root for DEBUG fixtures).
    /// Views outside the library hierarchy, such as Settings, read it instead of constructing `LibraryStorage()`.
    @Entry var libraryStorage = LibraryStorage()
}
