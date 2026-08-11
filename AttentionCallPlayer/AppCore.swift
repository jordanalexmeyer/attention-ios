import SwiftData
import SwiftUI

@main
struct AttentionCallPlayerApp: App {
    private let container: ModelContainer
    @StateObject private var appState: AppState
    @StateObject private var player: PlayerManager
    @StateObject private var downloads: DownloadManager

    init() {
        let schema = Schema([
            CachedConversation.self,
            PlaybackBookmark.self,
            DownloadedCall.self,
            RecentSearch.self,
            SuggestedEmail.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let modelContainer: ModelContainer

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Schema may have changed (e.g. SuggestedEmail). Recreate a fresh local store.
            let storeURL = configuration.url
            try? FileManager.default.removeItem(at: storeURL)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Unable to create local store: \(error)")
            }
        }

        let keychain = KeychainStore()
        let client = AttentionAPIClient(keychain: keychain)
        let repository = ConversationRepository(client: client)
        let playerManager = PlayerManager(repository: repository)
        let downloadManager = DownloadManager(repository: repository)

        container = modelContainer
        _appState = StateObject(wrappedValue: AppState(keychain: keychain, client: client, repository: repository))
        _player = StateObject(wrappedValue: playerManager)
        _downloads = StateObject(wrappedValue: downloadManager)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(player)
                .environmentObject(downloads)
        }
        .modelContainer(container)
    }
}

@MainActor
final class AppState: ObservableObject {
    let keychain: KeychainStore
    let client: AttentionAPIClient
    let repository: ConversationRepository

    @Published var apiKey: String
    @Published var myEmail: String
    /// Bumped whenever the API key changes so Library/Search reload.
    @Published private(set) var credentialsVersion = 0
    @Published var selectedConversation: Conversation?
    @Published var errorMessage: String?
    /// Set true to present the full player sheet (e.g. Continue Listening).
    @Published var presentNowPlaying = false
    @Published var tab: AppTab = .library

    private let myEmailDefaultsKey = "attention.myEmail"

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(keychain: KeychainStore, client: AttentionAPIClient, repository: ConversationRepository) {
        self.keychain = keychain
        self.client = client
        self.repository = repository
        self.apiKey = keychain.readAPIKey() ?? ""
        self.myEmail = UserDefaults.standard.string(forKey: "attention.myEmail") ?? ""
    }

    func saveAPIKey(_ value: String) {
        let normalized = KeychainStore.normalizedAPIKey(value)
        apiKey = normalized
        keychain.saveAPIKey(normalized)
        credentialsVersion += 1
    }

    func clearAPIKey() {
        apiKey = ""
        keychain.deleteAPIKey()
        credentialsVersion += 1
    }

    func saveMyEmail(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        myEmail = normalized
        UserDefaults.standard.set(normalized, forKey: myEmailDefaultsKey)
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @State private var isShowingNowPlaying = false

    var body: some View {
        // Custom chrome so tabs stay pinned at the bottom and the mini player
        // sits directly above them (Spotify-style). System TabView + safeAreaInset
        // was covering the tab bar when playback started.
        VStack(spacing: 0) {
            // All tabs stay alive so switching doesn't rebuild them (white flash)
            // and scroll positions are preserved.
            ZStack {
                LibraryView()
                    .opacity(appState.tab == .library ? 1 : 0)
                    .allowsHitTesting(appState.tab == .library)
                SearchView()
                    .opacity(appState.tab == .search ? 1 : 0)
                    .allowsHitTesting(appState.tab == .search)
                DownloadsView()
                    .opacity(appState.tab == .downloads ? 1 : 0)
                    .allowsHitTesting(appState.tab == .downloads)
                SettingsView()
                    .opacity(appState.tab == .settings ? 1 : 0)
                    .allowsHitTesting(appState.tab == .settings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if player.currentConversation != nil {
                // Floating rounded card with side margins, resting directly on the tab bar.
                MiniPlayerView(isShowingNowPlaying: $isShowingNowPlaying)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .background(Color(.systemGroupedBackground))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            BottomTabBar(selection: $appState.tab)
        }
        .animation(.easeInOut(duration: 0.2), value: player.currentConversation?.id)
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
                .presentationDragIndicator(.visible)
        }
        .onChange(of: appState.presentNowPlaying) { _, shouldPresent in
            guard shouldPresent else { return }
            isShowingNowPlaying = true
            appState.presentNowPlaying = false
        }
        .alert("Attention", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .task {
            player.modelContext = modelContext
            downloads.modelContext = modelContext
        }
        .overlay {
            if !appState.hasAPIKey {
                APIKeyGateView()
            }
        }
    }
}

enum AppTab: Hashable, CaseIterable, Identifiable {
    case library
    case search
    case downloads
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: return "Library"
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "rectangle.stack.fill"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct BottomTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20, weight: selection == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.bottom, 4)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
