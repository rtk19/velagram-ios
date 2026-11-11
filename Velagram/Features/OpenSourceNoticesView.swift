import SwiftUI

struct OpenSourceNoticesView: View {
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return "See the repository LICENSE and NOTICE files." }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "Notices could not be loaded."
    }
    var body: some View { ScrollView { Text(notices).font(.caption).textSelection(.enabled).padding(20) }.navigationTitle("Open-source licenses") }
}
