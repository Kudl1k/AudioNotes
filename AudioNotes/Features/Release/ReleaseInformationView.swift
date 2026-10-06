import SwiftUI

/// Native, selectable local help/privacy/license text; no web-based primary UI.
struct ReleaseInformationView: View {
    enum Page: String, Identifiable, Codable, Hashable { case help = "Soniquill Help", privacy = "Privacy", licenses = "Third-Party Licenses"; var id: String { rawValue } }
    static let windowID = "information"
    let page: Page
    @Environment(\.dismiss) private var dismiss

    private var content: String {
        let resource: String
        switch page { case .help: resource = "Help"; case .privacy: resource = "Privacy"; case .licenses: resource = "ThirdPartyLicenses" }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "This information could not be loaded. Please contact the release publisher." }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(page.rawValue).font(.title2)
            ScrollView { Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600, height: 520).navigationTitle(page.rawValue)
    }
}
