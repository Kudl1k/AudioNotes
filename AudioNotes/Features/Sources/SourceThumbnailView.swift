import SwiftUI

struct SourceThumbnailView: View {
    let url: URL
    let revision: String
    let icon: String
    let loader: SourceImageLoader
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: icon).font(.title2).foregroundStyle(.secondary) }
        }
        .frame(width: 40, height: 44)
        .accessibilityHidden(true)
        .task(id: url.path + revision) {
            let result = await loader.image(url: url, maximumDimension: 220)
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}
