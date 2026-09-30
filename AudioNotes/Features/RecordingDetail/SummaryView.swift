import SwiftUI

struct SummaryView: View {
    let summary: Summary?

    var body: some View {
        if let summary {
            ScrollView {
                Text(summary.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        } else {
            ContentUnavailableView("No summary yet", systemImage: "doc.text",
                                   description: Text("Summary generation is not available yet. You can listen to the original recording above."))
        }
    }
}
