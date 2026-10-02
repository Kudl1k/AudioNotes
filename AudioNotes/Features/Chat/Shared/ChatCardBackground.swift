import SwiftUI

extension Color {
    /// Semantic background color for message cards and status banners.
    /// On macOS, matches standard control background color.
    /// On iOS, matches secondary system grouped background color.
    static var chatCardBackground: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }
}
