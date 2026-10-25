import SwiftUI

/// Settings (Command-comma): how jotting works, your words, how it writes, and recording.
struct JotSettings: View {
    enum Tab: String, CaseIterable { case jot, dictionary, snippets, styles, record }
    @AppStorage("settingsTab") private var tab: Tab = .jot

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.jot)
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(Tab.dictionary)
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }.tag(Tab.snippets)
            StylesTab()
                .tabItem { Label("Styles", systemImage: "textformat") }.tag(Tab.styles)
            SettingsView()
                .tabItem { Label("Record", systemImage: "record.circle") }.tag(Tab.record)
        }
        .frame(width: 620, height: 680)
    }
}
