import AVKit
import SwiftData
import SwiftUI
import UIKit

struct APIKeyGateView: View {
    @EnvironmentObject private var appState: AppState
    @State private var draftKey = ""

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                Text("Attention")
                    .font(.largeTitle.bold())
                Text("Paste your Attention org API key to browse, stream, and download your team's calls.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                SecureField("Bearer token", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button {
                    appState.saveAPIKey(draftKey)
                } label: {
                    Label("Save Key", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(28)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedConversation.createdAt, order: .reverse) private var cachedConversations: [CachedConversation]
    @Query(sort: \PlaybackBookmark.updatedAt, order: .reverse) private var bookmarks: [PlaybackBookmark]
    @Query(sort: \FavoriteCall.createdAt, order: .reverse) private var favorites: [FavoriteCall]
    @Query(sort: \Playlist.createdAt) private var playlists: [Playlist]
    @Query(sort: \FollowedArtist.name) private var followedArtists: [FollowedArtist]

    @State private var conversations: [Conversation] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Fresh spinner identity per retry (List reuse can eat respawned spinners).
    @State private var retryNonce = 0

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        VStack(spacing: 12) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Couldn't load calls")
                                        .font(.subheadline.weight(.semibold))
                                    Text(errorMessage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            Button {
                                retryNonce += 1
                                Task { await refresh() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isLoading {
                                        ProgressView()
                                            .id(retryNonce)
                                            .controlSize(.small)
                                        Text("Retrying…")
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Try Again")
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.bordered)
                            .tint(.indigo)
                            .disabled(isLoading)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let continueItem = continueListeningTarget {
                    Section("Continue Listening") {
                        Button {
                            if player.currentConversation?.id == continueItem.conversation.id {
                                // Already loaded: open the player instead of reloading.
                                appState.presentNowPlaying = true
                            } else {
                                Task { await player.play(continueItem.conversation, queue: conversations) }
                            }
                        } label: {
                            ContinueListeningCard(
                                conversation: continueItem.conversation,
                                bookmark: continueItem.bookmark
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                yourLibrarySection
            }
            .navigationTitle("Library")
            .refreshable {
                await refresh()
            }
            .task(id: appState.credentialsVersion) {
                guard appState.hasAPIKey else { return }
                if conversations.isEmpty {
                    conversations = cachedConversations.map(Conversation.init(cache:))
                }
                await refresh()
            }
        }
    }

    /// Spotify-style collection: liked calls, playlists, and followed people.
    private var yourLibrarySection: some View {
        Section("Your Library") {
            NavigationLink {
                FavoriteCallsView()
            } label: {
                HStack {
                    Label {
                        Text("Favorites")
                    } icon: {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                    Spacer()
                    if !favorites.isEmpty {
                        Text("\(favorites.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Built-in "playlist" of every call, newest first.
            NavigationLink {
                NewCallsView()
            } label: {
                Label {
                    Text("New Calls")
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.indigo)
                }
            }

            ForEach(playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    HStack {
                        Label(playlist.name, systemImage: "music.note.list")
                        Spacer()
                        Text("\(playlist.conversationIDs.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(followedArtists) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist)
                } label: {
                    Label(artist.name, systemImage: "person.circle")
                }
            }

            NavigationLink {
                FollowPeopleView()
            } label: {
                Label("Follow People", systemImage: "person.crop.circle.badge.plus")
                    .foregroundStyle(.indigo)
            }
        }
    }

    private func refresh() async {
        guard appState.hasAPIKey else {
            errorMessage = "Add an Attention API key in Settings first."
            return
        }
        page = 1
        pageCount = 1
        await loadMoreIfNeeded(resetting: true)
    }

    private func loadMoreIfNeeded(resetting: Bool = false) async {
        guard !isLoading, page <= pageCount else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await appState.repository.list(page: page)
            if resetting {
                conversations = result.0
            } else {
                conversations.append(contentsOf: result.0)
            }
            pageCount = max(result.1?.pageCount ?? page, 1)
            page += 1
            errorMessage = nil
            upsertCache(result.0)
        } catch {
            if resetting {
                // Keep any cached rows visible while showing the failure.
                if conversations.isEmpty {
                    conversations = cachedConversations.map(Conversation.init(cache:))
                }
            }
            errorMessage = error.localizedDescription
        }
    }

    private func upsertCache(_ items: [Conversation]) {
        for conversation in items {
            let id = conversation.id
            let descriptor = FetchDescriptor<CachedConversation>(predicate: #Predicate { $0.id == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.update(from: conversation)
            } else {
                modelContext.insert(CachedConversation(conversation: conversation))
            }
        }
        EmailSuggestionStore.harvest(from: items, in: modelContext)
        try? modelContext.save()
    }

    private func conversation(for id: String) -> Conversation? {
        conversations.first { $0.id == id } ??
            cachedConversations.first { $0.id == id }.map(Conversation.init(cache:))
    }

    /// What you're in the middle of: the call loaded in the player if there is
    /// one, otherwise the most recently resumed unfinished call.
    private var continueListeningTarget: (conversation: Conversation, bookmark: PlaybackBookmark?)? {
        if let current = player.currentConversation {
            let bookmark = bookmarks.first { $0.conversationID == current.id }
            return (current, bookmark)
        }
        for bookmark in bookmarks {
            // Treat calls within 30s of the end as finished.
            if bookmark.duration > 0, bookmark.position >= bookmark.duration - 30 { continue }
            if let conversation = conversation(for: bookmark.conversationID) {
                return (conversation, bookmark)
            }
        }
        // Nothing in progress: suggest the newest call.
        if let conversation = conversations.first {
            return (conversation, nil)
        }
        if let cached = cachedConversations.first {
            return (Conversation(cache: cached), nil)
        }
        return nil
    }
}

/// Built-in "playlist" of every call, newest first. Not deletable — it's the
/// firehose, pushed from the Library's collection list.
struct NewCallsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CachedConversation.createdAt, order: .reverse) private var cachedConversations: [CachedConversation]
    @Query private var bookmarks: [PlaybackBookmark]
    @Query private var downloadedCalls: [DownloadedCall]
    @Query private var favorites: [FavoriteCall]

    @State private var conversations: [Conversation] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var playedIDs: Set<String> {
        Set(bookmarks.map(\.conversationID))
    }

    private var downloadedByID: [String: DownloadedCall] {
        Dictionary(downloadedCalls.map { ($0.conversationID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var favoriteIDs: Set<String> {
        Set(favorites.map(\.conversationID))
    }

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if conversations.isEmpty, !isLoading, errorMessage == nil {
                Section {
                    ContentUnavailableView(
                        "No calls yet",
                        systemImage: "waveform",
                        description: Text("Pull to refresh once your calls finish processing.")
                    )
                }
            } else {
                ForEach(Array(groupConversationsByDate(conversations).enumerated()), id: \.offset) { _, group in
                    Section(group.label) {
                        ForEach(group.items) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isUnplayed: !playedIDs.contains(conversation.id),
                                downloadedCall: downloadedByID[conversation.id],
                                isFavorite: favoriteIDs.contains(conversation.id),
                                onToggleFavorite: { FavoritesStore.toggle(conversation, in: modelContext) }
                            ) {
                                Task { await player.play(conversation, queue: conversations) }
                            }
                            .swipeActions(edge: .trailing) {
                                if let downloaded = downloadedByID[conversation.id] {
                                    Button(role: .destructive) {
                                        downloads.delete(downloaded)
                                    } label: {
                                        Label("Remove download", systemImage: "arrow.down.circle.dotted")
                                    }
                                } else {
                                    Button {
                                        Task { await downloads.download(conversation) }
                                    } label: {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                    .tint(.blue)
                                }
                                Button {
                                    player.enqueue([conversation])
                                } label: {
                                    Label("Queue", systemImage: "text.badge.plus")
                                }
                                .tint(.indigo)
                            }
                            .task {
                                if conversation.id == conversations.last?.id {
                                    await loadMore()
                                }
                            }
                        }
                    }
                }
                if isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Loading calls…")
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("New Calls")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if conversations.isEmpty {
                conversations = cachedConversations.map(Conversation.init(cache:))
            }
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    private func refresh() async {
        page = 1
        pageCount = 1
        await loadMore(resetting: true)
    }

    private func loadMore(resetting: Bool = false) async {
        guard !isLoading, page <= pageCount else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await appState.repository.list(page: page)
            if resetting {
                conversations = result.0
            } else {
                conversations.append(contentsOf: result.0)
            }
            pageCount = max(result.1?.pageCount ?? page, 1)
            page += 1
            errorMessage = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var downloadedCalls: [DownloadedCall]
    @Query private var favorites: [FavoriteCall]

    @State private var titleQuery = ""
    @State private var participantEmails: [String] = []
    @State private var dateRange: LibraryDateRange = .all
    @State private var hideInternal = false
    @State private var callsIOwn = false
    @State private var isShowingFilters = false
    @State private var results: [Conversation] = []
    @State private var totalCount: Int?
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isSearching = false
    /// A resetting search (new query/filters) is in flight while old results are still on screen.
    @State private var isRefreshing = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    /// Monotonic id so a superseded search can't clear the newer search's loading flags.
    @State private var searchGeneration = 0

    private var activeOwnerEmail: String? {
        callsIOwn ? appState.myEmail.nilIfBlank : nil
    }

    private var activeFilterCount: Int {
        participantEmails.count
            + [titleQuery.nilIfBlank != nil, dateRange != .all, hideInternal, callsIOwn].filter { $0 }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                if activeFilterCount > 0 {
                    filterStatusSection
                }

                resultsSections
            }
            .navigationTitle("Search")
            .onChange(of: titleQuery) { _, _ in runSearch() }
            .onChange(of: participantEmails) { _, _ in runSearch() }
            .onChange(of: dateRange) { _, _ in runSearch() }
            .onChange(of: hideInternal) { _, _ in runSearch() }
            .onChange(of: callsIOwn) { _, _ in runSearch() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingFilters = true
                    } label: {
                        Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
            .sheet(isPresented: $isShowingFilters) {
                SearchFiltersSheet(
                    titleQuery: $titleQuery,
                    participantEmails: $participantEmails,
                    dateRange: $dateRange,
                    hideInternal: $hideInternal,
                    callsIOwn: $callsIOwn
                )
                .presentationDetents([.large])
            }
            .task(id: appState.credentialsVersion) {
                await refreshEmailDirectory()
                if appState.hasAPIKey {
                    await search(resetting: true)
                }
            }
        }
    }

    private var filterStatusSection: some View {
        Section {
            HStack {
                Button {
                    isShowingFilters = true
                } label: {
                    Label(
                        "\(activeFilterCount) \(activeFilterCount == 1 ? "filter" : "filters") active",
                        systemImage: "line.3.horizontal.decrease.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Clear filters") {
                    clearAllFilters()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
    }

    private var groupedResults: [(label: String, items: [Conversation])] {
        groupConversationsByDate(results)
    }

    @ViewBuilder
    private var resultsSections: some View {
        if isSearching && results.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading calls…")
                    Spacer()
                }
            }
        } else if hasSearched, results.isEmpty, !isSearching {
            Section {
                ContentUnavailableView(
                    "No matching calls",
                    systemImage: "magnifyingglass",
                    description: Text("Try clearing a filter or widening the date range.")
                )
            }
        } else {
            if isRefreshing {
                Section {
                    HStack(spacing: 10) {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                            // List reuse breaks respawned spinners; a fresh identity
                            // per search forces SwiftUI to rebuild (and animate) it.
                            .id(searchGeneration)
                        Text("Updating results…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            ForEach(Array(groupedResults.enumerated()), id: \.offset) { index, group in
                Section {
                    ForEach(group.items) { conversation in
                        let downloaded = downloadedCalls.first { $0.conversationID == conversation.id }
                        ConversationRow(
                            conversation: conversation,
                            downloadedCall: downloaded,
                            isFavorite: favorites.contains { $0.conversationID == conversation.id },
                            onToggleFavorite: { FavoritesStore.toggle(conversation, in: modelContext) }
                        ) {
                            Task { await player.play(conversation, queue: results) }
                        }
                        .swipeActions(edge: .trailing) {
                            if let downloaded {
                                Button(role: .destructive) {
                                    downloads.delete(downloaded)
                                } label: {
                                    Label("Remove download", systemImage: "arrow.down.circle.dotted")
                                }
                            } else {
                                Button {
                                    Task { await downloads.download(conversation) }
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                }
                                .tint(.blue)
                            }
                            Button {
                                player.enqueue([conversation])
                            } label: {
                                Label("Queue", systemImage: "text.badge.plus")
                            }
                            .tint(.indigo)
                        }
                        .task {
                            if conversation.id == results.last?.id {
                                await search(resetting: false)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.label)
                        Spacer()
                        if index == 0, let totalCount {
                            Text("\(totalCount) calls")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .opacity(isRefreshing ? 0.4 : 1)
            if isSearching, !results.isEmpty, !isRefreshing {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        searchTask = Task {
            // Debounce: the title field now searches as you type.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(resetting: true)
        }
    }

    private func clearAllFilters() {
        titleQuery = ""
        participantEmails = []
        dateRange = .all
        hideInternal = false
        callsIOwn = false
    }

    private func refreshEmailDirectory() async {
        guard appState.hasAPIKey else { return }
        do {
            let users = try await appState.repository.users()
            EmailSuggestionStore.harvest(from: users, in: modelContext)
        } catch {
            // Best-effort.
        }
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedConversation>())) ?? []
        EmailSuggestionStore.harvest(from: cached.map(Conversation.init(cache:)), in: modelContext)
    }

    private func search(resetting: Bool) async {
        guard appState.hasAPIKey else {
            errorMessage = "Add an Attention API key in Settings first."
            return
        }
        if callsIOwn, activeOwnerEmail == nil {
            errorMessage = "Set your email in Settings to filter calls you own."
            return
        }
        if !resetting {
            guard !isSearching, page <= pageCount else { return }
        }

        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        if resetting {
            isRefreshing = true
        }
        defer {
            if generation == searchGeneration {
                isSearching = false
                isRefreshing = false
            }
        }

        if resetting {
            page = 1
            pageCount = 1
        }

        do {
            let bounds = dateRange.bounds
            let result = try await appState.repository.list(
                page: page,
                size: 25,
                search: titleQuery,
                participantEmails: participantEmails,
                ownerEmail: activeOwnerEmail,
                hideInternal: hideInternal,
                fromDate: bounds.from,
                toDate: bounds.to
            )
            if Task.isCancelled { return }
            if resetting {
                results = result.0
            } else {
                results.append(contentsOf: result.0)
            }
            totalCount = result.1?.totalRecords
            pageCount = max(result.1?.pageCount ?? page, 1)
            page += 1
            hasSearched = true
            errorMessage = nil
            EmailSuggestionStore.harvest(from: result.0, in: modelContext)
            for email in participantEmails {
                EmailSuggestionStore.upsert(email: email, name: nil, source: "search", in: modelContext)
            }
            if !participantEmails.isEmpty {
                try? modelContext.save()
            }
            if resetting {
                let recent = titleQuery.nilIfBlank ?? participantEmails.first
                if let recent { saveRecentSearch(recent) }
            }
        } catch {
            // A newer search superseded this one; don't surface cancellation.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    private func saveRecentSearch(_ value: String) {
        guard let query = value.nilIfBlank else { return }
        let descriptor = FetchDescriptor<RecentSearch>(predicate: #Predicate { $0.query == query })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.updatedAt = Date()
        } else {
            modelContext.insert(RecentSearch(query: query))
        }
        try? modelContext.save()
    }
}

/// Shown as the Downloads tab and pushed from Settings ("Manage downloads").
struct DownloadsListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Query(sort: \DownloadedCall.createdAt, order: .reverse) private var downloadedCalls: [DownloadedCall]
    @State private var errorMessage: String?

    var body: some View {
            List {
                if downloadedCalls.isEmpty, downloads.downloadingTitles.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Swipe a call in Library to save it for offline listening.")
                    )
                }

                if !downloads.downloadingTitles.isEmpty {
                    Section("Downloading") {
                        ForEach(downloads.downloadingTitles.sorted(by: { $0.key < $1.key }), id: \.key) { _, title in
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section {
                    ForEach(downloadedCalls) { download in
                        Button {
                            open(download, autoplay: true)
                        } label: {
                            HStack(spacing: 6) {
                                if player.currentConversation?.id == download.conversationID {
                                    SoundBars(animating: player.isPlaying)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(download.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                        .foregroundStyle(player.currentConversation?.id == download.conversationID ? Color.indigo : Color.primary)
                                    Text("\(download.duration.shortDuration) · \(formattedSize(download.fileSize)) · \(download.createdAt.compactRelativeLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                downloads.delete(download)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    if !downloadedCalls.isEmpty {
                        HStack {
                            Text("\(downloadedCalls.count) \(downloadedCalls.count == 1 ? "call" : "calls") · \(formattedSize(totalSize))")
                            Spacer()
                            Menu {
                                Picker("Keep last", selection: Binding(
                                    get: { downloads.downloadLimit },
                                    set: { downloads.setDownloadLimit($0) }
                                )) {
                                    ForEach([10, 20, 50], id: \.self) { limit in
                                        Text("Keep last \(limit)").tag(limit)
                                    }
                                }
                            } label: {
                                Text("Keeps last \(downloads.downloadLimit)")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .alert("Download Error", isPresented: Binding(
                get: { errorMessage != nil || downloads.errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                        downloads.errorMessage = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? downloads.errorMessage ?? "")
            }
    }

    private var totalSize: Int64 {
        downloadedCalls.reduce(0) { $0 + $1.fileSize }
    }

    private func open(_ download: DownloadedCall, autoplay: Bool) {
        do {
            let conversation = Conversation(
                id: download.conversationID,
                title: download.title,
                createdAt: download.createdAt,
                duration: download.duration
            )
            let url = try downloads.localURL(for: download)
            if !autoplay {
                appState.presentNowPlaying = true
            }
            Task { await player.play(conversation, localURL: url, autoplay: autoplay) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct SnippetsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSnippet.createdAt, order: .reverse) private var snippets: [SavedSnippet]
    @Query(sort: \SnippetFolder.name) private var folders: [SnippetFolder]
    @State private var selectedSnippet: SavedSnippet?
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    private var unfiledSnippets: [SavedSnippet] {
        snippets.filter { $0.localFolder.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                foldersSection
                snippetsSection
            }
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newFolderName = ""
                        isNamingFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .accessibilityLabel("New Folder")
                }
            }
            .sheet(item: $selectedSnippet) { snippet in
                SnippetPlayerView(snippet: snippet)
            }
            .alert("New Folder", isPresented: $isNamingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    createFolder(named: newFolderName)
                }
            } message: {
                Text("Folders live on this phone and help organize your snippets.")
            }
        }
    }

    @ViewBuilder
    private var foldersSection: some View {
        if !folders.isEmpty {
            Section("Folders") {
                ForEach(folders) { folder in
                    NavigationLink {
                        SnippetFolderView(folder: folder)
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder")
                            Spacer()
                            let count = snippets.count { $0.localFolder == folder.name }
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var snippetsSection: some View {
        if snippets.isEmpty {
            ContentUnavailableView(
                "No Snippets",
                systemImage: "scissors",
                description: Text("Create a snippet from the player and it shows up here with its share link.")
            )
        } else {
            Section {
                if unfiledSnippets.isEmpty {
                    Text("All snippets are filed in folders.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(unfiledSnippets) { snippet in
                    SnippetRow(snippet: snippet, folders: folders) {
                        selectedSnippet = snippet
                    }
                }
            } header: {
                Text("My Snippets")
            }
        }
    }

    private func createFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !folders.contains(where: { $0.name == name }) else { return }
        modelContext.insert(SnippetFolder(name: name))
        try? modelContext.save()
        Haptics.success()
    }
}

/// One local folder's snippets, with rename and delete.
struct SnippetFolderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedSnippet.createdAt, order: .reverse) private var allSnippets: [SavedSnippet]
    @Query(sort: \SnippetFolder.name) private var folders: [SnippetFolder]

    let folder: SnippetFolder

    @State private var selectedSnippet: SavedSnippet?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    private var snippetsHere: [SavedSnippet] {
        allSnippets.filter { $0.localFolder == folder.name }
    }

    var body: some View {
        List {
            if snippetsHere.isEmpty {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Move snippets here from their long-press menu, or pick this folder when saving a new snippet.")
                )
            }
            ForEach(snippetsHere) { snippet in
                SnippetRow(snippet: snippet, folders: folders) {
                    selectedSnippet = snippet
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = folder.name
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $selectedSnippet) { snippet in
            SnippetPlayerView(snippet: snippet)
        }
        .alert("Rename Folder", isPresented: $isRenaming) {
            TextField("Folder name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                renameFolder(to: renameText)
            }
        }
        .alert("Delete “\(folder.name)”?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteFolder()
            }
        } message: {
            Text("Snippets inside move back to My Snippets.")
        }
    }

    private func renameFolder(to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != folder.name,
              !folders.contains(where: { $0.name == name }) else { return }
        for snippet in snippetsHere {
            snippet.localFolder = name
        }
        folder.name = name
        try? modelContext.save()
    }

    private func deleteFolder() {
        for snippet in snippetsHere {
            snippet.localFolder = ""
        }
        modelContext.delete(folder)
        try? modelContext.save()
        dismiss()
    }
}

/// Shared snippet row: tap to open the snippet player, long-press or swipe for
/// copy/share/move/delete.
struct SnippetRow: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.modelContext) private var modelContext

    let snippet: SavedSnippet
    let folders: [SnippetFolder]
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(snippet.callTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !snippet.notes.isEmpty {
                    Text(snippet.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .italic()
                }
                HStack(spacing: 6) {
                    Image(systemName: "scissors")
                    Text((snippet.endTime - snippet.startTime).shortDuration)
                    Text("·")
                    Text("starts at \(snippet.startTime.shortDuration)")
                    Text("·")
                    Text(snippet.createdAt.compactRelativeLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = snippet.url {
                Button("Copy link", systemImage: "link") {
                    UIPasteboard.general.string = snippet.urlString
                    UIPasteboard.general.url = url
                    Haptics.success()
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button("Play in call", systemImage: "play.circle") {
                playSource()
            }
            moveToFolderMenu
            Button("Remove from list", systemImage: "trash", role: .destructive) {
                modelContext.delete(snippet)
                try? modelContext.save()
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                modelContext.delete(snippet)
                try? modelContext.save()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if snippet.url != nil {
                Button {
                    UIPasteboard.general.string = snippet.urlString
                    Haptics.success()
                } label: {
                    Label("Copy link", systemImage: "link")
                }
                .tint(.indigo)
            }
        }
    }

    @ViewBuilder
    private var moveToFolderMenu: some View {
        if !folders.isEmpty {
            Menu {
                ForEach(folders) { folder in
                    Button {
                        snippet.localFolder = folder.name
                        try? modelContext.save()
                        Haptics.tap()
                    } label: {
                        if snippet.localFolder == folder.name {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                if !snippet.localFolder.isEmpty {
                    Button("Remove from folder", systemImage: "folder.badge.minus") {
                        snippet.localFolder = ""
                        try? modelContext.save()
                    }
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
        }
    }

    /// Opens the source call and starts playback at the snippet's start.
    private func playSource() {
        Haptics.tap()
        let conversation = Conversation(
            id: snippet.conversationID,
            title: snippet.callTitle,
            createdAt: snippet.createdAt,
            duration: 0
        )
        Task {
            await player.play(conversation)
            player.seek(to: snippet.startTime)
        }
    }
}

/// Trailing ⓧ shown inside text fields whenever there's something to clear.
struct ClearButton: View {
    @Binding var text: String

    var body: some View {
        if !text.isEmpty {
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Standalone audio engine for a single snippet. Deliberately separate from
/// PlayerManager so previewing a clip never unloads or reseats the call in the
/// main player (mini bar, lock screen, bookmarks all stay untouched).
@MainActor
final class SnippetClipPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Absolute position in the source call's timeline.
    @Published private(set) var position: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var window: ClosedRange<TimeInterval> = 0...1

    func load(url: URL, start: TimeInterval, end: TimeInterval) {
        teardown()
        window = start...max(start + 0.1, end)
        position = start
        let player = AVPlayer(url: url)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds
                if time.seconds >= self.window.upperBound {
                    self.pause()
                }
            }
        }
        self.player = player
    }

    func play() {
        guard let player else { return }
        // Restart from the top if the clip already ran out.
        if position >= window.upperBound - 0.25 {
            seek(to: window.lowerBound)
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let bounded = min(max(seconds, window.lowerBound), window.upperBound)
        position = bounded
        player?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
    }

    func restart() {
        seek(to: window.lowerBound)
        if !isPlaying { play() }
    }

    func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        isPlaying = false
    }
}

/// Player scoped to a single snippet: plays just [start, end] on its own audio
/// engine and stops. The main player is only touched via the explicit expand button.
struct SnippetPlayerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var downloadedCalls: [DownloadedCall]
    let snippet: SavedSnippet

    @StateObject private var clip = SnippetClipPlayer()
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var scrubTime: TimeInterval?
    @State private var isEditingNote = false
    @State private var noteDraft = ""

    private var windowLength: TimeInterval {
        max(0.1, snippet.endTime - snippet.startTime)
    }

    /// Current position clamped into the snippet window, window-relative.
    private var windowPosition: TimeInterval {
        min(max(clip.position, snippet.startTime), snippet.endTime) - snippet.startTime
    }

    var body: some View {
        NavigationStack {
            // Top-aligned with a fixed rhythm (no stretching Spacers) so the
            // layout reads the same at the half and full detents.
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "scissors")
                        .font(.system(size: 32))
                        .foregroundStyle(.indigo)
                    VStack(spacing: 4) {
                        Text(snippet.title)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text(snippet.callTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        noteRow
                    }
                }
                .padding(.horizontal, 24)

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                } else if isLoading {
                    ProgressView("Loading snippet…")
                        .padding(.top, 12)
                } else {
                    VStack(spacing: 22) {
                        VStack(spacing: 8) {
                            Slider(
                                value: Binding(
                                    get: { scrubTime ?? windowPosition },
                                    set: { scrubTime = $0 }
                                ),
                                in: 0...windowLength
                            ) { editing in
                                guard !editing, let scrubTime else { return }
                                clip.seek(to: snippet.startTime + scrubTime)
                                self.scrubTime = nil
                            }
                            HStack {
                                Text((scrubTime ?? windowPosition).shortDuration)
                                Spacer()
                                Text(windowLength.shortDuration)
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 44) {
                            Button {
                                Haptics.tap()
                                clip.restart()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.title2)
                            }
                            Button {
                                Haptics.tap()
                                if clip.isPlaying {
                                    clip.pause()
                                } else {
                                    if player.isPlaying { player.pause() }
                                    clip.play()
                                }
                            } label: {
                                Image(systemName: clip.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 60))
                            }
                            Button(action: expandToFullCall) {
                                Image(systemName: "rectangle.expand.vertical")
                                    .font(.title2)
                            }
                        }
                        .foregroundStyle(.indigo)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .navigationTitle("Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Anchored to the sheet's bottom safe area, so the buttons keep a
            // comfortable inset at every detent instead of hugging the edge.
            .safeAreaInset(edge: .bottom) {
                if let url = snippet.url {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = snippet.urlString
                            UIPasteboard.general.url = url
                            Haptics.success()
                        } label: {
                            Label("Copy link", systemImage: "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
            .task {
                await loadAndPlay()
            }
            .onDisappear {
                clip.teardown()
            }
            .sheet(isPresented: $isEditingNote) {
                noteEditor
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var noteEditor: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        TextField("Note", text: $noteDraft, axis: .vertical)
                            .lineLimit(3...8)
                        ClearButton(text: $noteDraft)
                    }
                } footer: {
                    Text("Saved on this phone. The shared web clip keeps the note it was created with.")
                }
            }
            .navigationTitle("Snippet Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isEditingNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        snippet.notes = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        try? modelContext.save()
                        Haptics.success()
                        isEditingNote = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var noteRow: some View {
        Button {
            noteDraft = snippet.notes
            isEditingNote = true
        } label: {
            if snippet.notes.isEmpty {
                Label("Add note", systemImage: "square.and.pencil")
                    .font(.footnote)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(snippet.notes)
                        .font(.footnote)
                        .italic()
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Image(systemName: "pencil")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func loadAndPlay() async {
        do {
            let url: URL
            if let download = downloadedCalls.first(where: { $0.conversationID == snippet.conversationID }),
               let local = try? downloads.localURL(for: download) {
                url = local
            } else {
                url = try await appState.repository.mediaURL(for: snippet.conversationID)
            }
            clip.load(url: url, start: snippet.startTime, end: snippet.endTime)
            isLoading = false
            // Don't talk over the main player; pause it (state preserved) and play the clip.
            if player.isPlaying { player.pause() }
            clip.play()
        } catch {
            loadError = "Couldn't load the snippet audio."
            isLoading = false
        }
    }

    /// The one deliberate handoff: load the source call into the main player
    /// and continue from wherever the clip was.
    private func expandToFullCall() {
        Haptics.tap()
        let target = snippet.startTime + windowPosition
        clip.teardown()
        let conversation = Conversation(
            id: snippet.conversationID,
            title: snippet.callTitle,
            createdAt: snippet.createdAt,
            duration: 0
        )
        dismiss()
        appState.presentNowPlaying = true
        Task {
            if player.currentConversation?.id != snippet.conversationID {
                await player.play(conversation)
            }
            player.seek(to: target)
        }
    }
}

struct SearchFiltersSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SuggestedEmail.updatedAt, order: .reverse) private var suggestedEmails: [SuggestedEmail]

    @Binding var titleQuery: String
    @Binding var participantEmails: [String]
    @Binding var dateRange: LibraryDateRange
    @Binding var hideInternal: Bool
    @Binding var callsIOwn: Bool

    @State private var emailDraft = ""
    @FocusState private var emailFocused: Bool

    private var emailSuggestions: [SuggestedEmail] {
        EmailSuggestionStore.suggestions(matching: emailDraft, from: suggestedEmails)
            .filter { !participantEmails.contains($0.email.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Call title") {
                    HStack {
                        TextField("Search call titles", text: $titleQuery)
                            .autocorrectionDisabled()
                        if !titleQuery.isEmpty {
                            Button {
                                titleQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Participants") {
                    ForEach(participantEmails, id: \.self) { email in
                        HStack {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.indigo)
                            Text(email)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                participantEmails.removeAll { $0 == email }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField(participantEmails.isEmpty ? "Participant email" : "Add another participant", text: $emailDraft)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .focused($emailFocused)
                            .submitLabel(.return)
                            .onSubmit { commitEmail(emailDraft) }
                        ClearButton(text: $emailDraft)
                    }

                    if emailFocused {
                        ForEach(emailSuggestions) { suggestion in
                            Button {
                                commitEmail(suggestion.email)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: suggestion.source == "org" ? "person.crop.circle.fill" : "envelope.circle.fill")
                                        .foregroundStyle(.indigo)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.name ?? suggestion.email)
                                            .foregroundStyle(.primary)
                                        if suggestion.name != nil {
                                            Text(suggestion.email)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(suggestion.source == "org" ? "Teammate" : "Seen on calls")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Picker("Date range", selection: $dateRange) {
                        ForEach(LibraryDateRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    Toggle("Hide internal calls", isOn: $hideInternal)
                    Toggle("Calls I own", isOn: $callsIOwn)
                    if callsIOwn, appState.myEmail.nilIfBlank == nil {
                        Text("Set your email in Settings to use “Calls I own”.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Filters apply immediately. Transcript, duration, tags, company, and contact filters aren’t available via Attention’s public API yet.")
                }

                Section {
                    Button("Clear all filters", role: .destructive) {
                        titleQuery = ""
                        emailDraft = ""
                        participantEmails = []
                        dateRange = .all
                        hideInternal = false
                        callsIOwn = false
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitEmail(emailDraft)
                        dismiss()
                    }
                }
            }
        }
    }

    private func commitEmail(_ value: String) {
        emailDraft = ""
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), !participantEmails.contains(normalized) else { return }
        participantEmails.append(normalized)
    }
}

struct SettingsView: View {
    enum ConnectionStatus: Equatable {
        case unknown
        case verifying
        case connected(userCount: Int?, orgKey: Bool?)
        case failed(String)
    }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query private var downloadedCalls: [DownloadedCall]
    @Query private var cachedConversations: [CachedConversation]
    @Query private var bookmarks: [PlaybackBookmark]
    @Query private var recentSearches: [RecentSearch]
    @Query(sort: \SuggestedEmail.updatedAt, order: .reverse) private var suggestedEmails: [SuggestedEmail]
    @State private var draftKey = ""
    @State private var draftEmail = ""
    @State private var connection: ConnectionStatus = .unknown
    @State private var savedField: String?
    @State private var isConfirmingClearCache = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                profileSection
                playbackSection
                storageSection
                aboutSection
            }
            .navigationTitle("Settings")
            // task(id:) instead of onAppear: tabs stay alive, so this must re-run
            // whenever the key changes elsewhere (e.g. the first-launch key gate).
            .task(id: appState.credentialsVersion) {
                draftKey = appState.apiKey
                draftEmail = appState.myEmail
                if appState.apiKey.isEmpty {
                    connection = .unknown
                } else {
                    await verifyConnection()
                }
            }
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            connectionRow
            SecureField("API key", text: $draftKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draftKey.trimmingCharacters(in: .whitespacesAndNewlines) != appState.apiKey {
                Button("Save & Verify Key") {
                    appState.saveAPIKey(draftKey)
                    draftKey = appState.apiKey
                    flashSaved("key")
                    Task { await verifyConnection() }
                }
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if savedField == "key" {
                savedLabel
            }
            if !appState.apiKey.isEmpty {
                Button("Clear API Key", role: .destructive) {
                    appState.clearAPIKey()
                    draftKey = ""
                    connection = .unknown
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Use an org-level Attention API key — it unlocks audio streaming and offline downloads.")
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        switch connection {
        case .unknown:
            Label {
                Text(appState.apiKey.isEmpty ? "No API key" : "Not verified")
            } icon: {
                Circle().fill(.gray).frame(width: 10, height: 10)
            }
        case .verifying:
            HStack(spacing: 10) {
                ProgressView()
                Text("Verifying…")
                    .foregroundStyle(.secondary)
            }
        case let .connected(userCount, orgKey):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                    Text(connectionDetail(userCount: userCount, orgKey: orgKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Circle().fill(.green).frame(width: 10, height: 10)
            }
        case let .failed(message):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection failed")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } icon: {
                Circle().fill(.red).frame(width: 10, height: 10)
            }
        }
    }

    private func connectionDetail(userCount: Int?, orgKey: Bool?) -> String {
        var parts: [String] = []
        if let userCount {
            parts.append("\(userCount) \(userCount == 1 ? "user" : "users") in directory")
        }
        switch orgKey {
        case true: parts.append("Audio streaming OK")
        case false: parts.append("Key can't stream audio — use an org key")
        default: break
        }
        return parts.isEmpty ? "Key accepted" : parts.joined(separator: " · ")
    }

    private func verifyConnection() async {
        connection = .verifying
        do {
            let (conversations, _) = try await appState.repository.list(page: 1, size: 1)
            let userCount = (try? await appState.repository.users())?.count
            var orgKey: Bool?
            if let first = conversations.first {
                // Media URL minting only works with org-level keys, so it doubles as a key-type probe.
                orgKey = (try? await appState.repository.mediaURL(for: first.id)) != nil
            }
            connection = .connected(userCount: userCount, orgKey: orgKey)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: Profile

    private var normalizedDraftEmail: String {
        draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var emailSuggestions: [SuggestedEmail] {
        let query = normalizedDraftEmail
        guard emailFocused, !query.isEmpty, query != appState.myEmail else { return [] }
        return suggestedEmails
            .filter { $0.email.localizedCaseInsensitiveContains(query) && $0.email != query }
            .prefix(3)
            .map { $0 }
    }

    private var profileSection: some View {
        Section {
            HStack {
                TextField("My email", text: $draftEmail)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($emailFocused)
                ClearButton(text: $draftEmail)
            }
            ForEach(emailSuggestions, id: \.email) { suggestion in
                Button {
                    saveEmail(suggestion.email)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.email)
                                .foregroundStyle(.primary)
                            if let name = suggestion.name, !name.isEmpty {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            if !normalizedDraftEmail.isEmpty, normalizedDraftEmail != appState.myEmail {
                Button("Save My Email") {
                    saveEmail(draftEmail)
                }
            }
            if savedField == "email" {
                savedLabel
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Used by the “Calls I own” search filter to find your calls.")
        }
    }

    private func saveEmail(_ email: String) {
        appState.saveMyEmail(email)
        draftEmail = appState.myEmail
        emailFocused = false
        flashSaved("email")
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section {
            Picker("Playback speed", selection: $player.playbackRate) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                    Text(rate == 1.0 ? "Normal" : String(format: "%g×", rate))
                        .tag(Float(rate))
                }
            }
            Picker("Skip interval", selection: $player.skipInterval) {
                ForEach([10.0, 15.0, 30.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            }
            Toggle("Autoplay next in queue", isOn: $player.autoplayQueueEnabled)
            Toggle("Smart speed", isOn: $player.smartSpeedEnabled)
        } header: {
            Text("Playback")
        } footer: {
            Text("Smart speed uses the transcript to jump past silences longer than 2 seconds.")
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section("Storage") {
            NavigationLink {
                DownloadsListView()
            } label: {
                HStack {
                    Label("Manage downloads", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(downloadedCalls.count) · \(formattedSize(downloadedCalls.reduce(0) { $0 + $1.fileSize }))")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Cached calls", value: "\(cachedConversations.count)")
            Button("Clear Local Cache", role: .destructive) {
                isConfirmingClearCache = true
            }
            .confirmationDialog(
                "Clear local cache?",
                isPresented: $isConfirmingClearCache,
                titleVisibility: .visible
            ) {
                Button("Clear cache, bookmarks & recent searches", role: .destructive) {
                    clearLocalCache()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes cached call listings, playback positions, and recent searches. Downloaded audio is kept.")
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            Link(destination: URL(string: "https://docs.attention.com")!) {
                Label("Attention API Docs", systemImage: "book")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Built on the Attention API.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != version {
            return "\(version) (\(build))"
        }
        return version
    }

    // MARK: Helpers

    private var savedLabel: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .transition(.opacity)
    }

    private func flashSaved(_ field: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { savedField = field }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if savedField == field {
                withAnimation { savedField = nil }
            }
        }
    }

    private func clearLocalCache() {
        for item in cachedConversations { modelContext.delete(item) }
        for item in bookmarks { modelContext.delete(item) }
        for item in recentSearches { modelContext.delete(item) }
        try? modelContext.save()
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

struct QueueSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentConversation {
                    Section("Now Playing") {
                        HStack(spacing: 12) {
                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                .foregroundStyle(.indigo)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(current.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(current.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if player.queue.isEmpty {
                    ContentUnavailableView(
                        "Nothing queued",
                        systemImage: "list.bullet",
                        description: Text("Swipe a call in Library and tap Queue to line it up.")
                    )
                } else {
                    Section {
                        ForEach(player.queue) { conversation in
                            Button {
                                playNow(conversation)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(conversation.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(conversation.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { player.removeFromQueue(at: $0) }
                        .onMove { player.moveInQueue(from: $0, to: $1) }
                    } header: {
                        Text("Up Next")
                    } footer: {
                        Text("Plays automatically when the current call ends. Tap to play now, drag to reorder, swipe to remove.")
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !player.queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { player.clearQueue() }
                    }
                }
            }
        }
    }

    private func playNow(_ conversation: Conversation) {
        guard let index = player.queue.firstIndex(where: { $0.id == conversation.id }) else { return }
        let remaining = Array(player.queue[(index + 1)...])
        Task { await player.play(conversation, queue: remaining) }
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @Binding var isShowingNowPlaying: Bool

    var body: some View {
        Button {
            isShowingNowPlaying = true
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentConversation?.title ?? "Nothing playing")
                            .lineLimit(1)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subtitle = player.currentConversation?.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .lineLimit(1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                Button {
                    Haptics.tap()
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Spotify-style: thin progress line flush with the card's bottom edge.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.25))
                        Capsule()
                            .fill(Color.indigo)
                            .frame(width: geometry.size.width * progressFraction)
                    }
                }
                .frame(height: 2.5)
                .padding(.horizontal, 10)
            }
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var progressFraction: CGFloat {
        guard player.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, player.currentTime / player.duration)))
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.playlists) private var playlists
    @Query private var favorites: [FavoriteCall]
    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var isShowingDetail = false
    @State private var isShowingAsk = false
    @State private var isShowingQueue = false
    @State private var snippetDraft: SnippetDraft?
    @State private var snippetError: String?
    @StateObject private var snippetSelection = SnippetSelectionState()

    @State private var showRemainingTime = true

    @State private var isSearchingTranscript = false
    @State private var transcriptQuery = ""
    @State private var activeMatchIndex = 0
    @State private var searchScrollNonce = 0
    @FocusState private var transcriptSearchFocused: Bool

    private var speakerColors: [String: Color] {
        SpeakerPalette.colorMap(for: player.currentTranscript)
    }

    private var trimmedTranscriptQuery: String {
        transcriptQuery.trimmingCharacters(in: .whitespaces)
    }

    private var transcriptMatches: [TranscriptSegment] {
        guard trimmedTranscriptQuery.count >= 2 else { return [] }
        return player.currentTranscript.filter { $0.text.localizedCaseInsensitiveContains(trimmedTranscriptQuery) }
    }

    private var activeMatchID: String? {
        guard !transcriptMatches.isEmpty else { return nil }
        return transcriptMatches[min(activeMatchIndex, transcriptMatches.count - 1)].id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                header

                scrubber
                controls

                if isSearchingTranscript {
                    transcriptSearchBar
                }

                if snippetSelection.isSelecting {
                    SnippetSelectionBanner(selection: snippetSelection) {
                        createDraftFromSelection()
                    }
                }

                TranscriptView(
                    selection: snippetSelection,
                    speakerColors: speakerColors,
                    searchQuery: trimmedTranscriptQuery.count >= 2 ? trimmedTranscriptQuery : "",
                    activeSearchMatchID: activeMatchID,
                    searchScrollNonce: searchScrollNonce
                ) { draft in
                    snippetDraft = draft
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if isSearchingTranscript {
                            closeTranscriptSearch()
                        } else {
                            isSearchingTranscript = true
                            transcriptSearchFocused = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    Button {
                        snippetSelection.beginSelecting()
                    } label: {
                        Image(systemName: snippetSelection.isSelecting ? "scissors.badge.ellipsis" : "scissors")
                    }
                    Button { isShowingAsk = true } label: {
                        Image(systemName: "sparkles")
                    }
                    if let webURL = player.currentConversation?.webURL {
                        ShareLink(item: webURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button { isShowingDetail = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingDetail) {
                if let conversation = player.currentConversation {
                    CallDetailView(conversation: conversation) { draft in
                        snippetDraft = draft
                    }
                }
            }
            .sheet(isPresented: $isShowingAsk) {
                if let conversation = player.currentConversation {
                    AskCallView(conversation: conversation)
                }
            }
            .sheet(isPresented: $isShowingQueue) {
                QueueSheet()
            }
            .sheet(item: $snippetDraft) { draft in
                SnippetComposerView(draft: draft)
            }
            .alert("Snippet", isPresented: Binding(
                get: { snippetError != nil },
                set: { if !$0 { snippetError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(snippetError ?? "")
            }
            .alert("Playback Error", isPresented: Binding(
                get: { player.errorMessage != nil },
                set: { if !$0 { player.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(player.errorMessage ?? "")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.currentConversation?.title ?? "No call")
                        .font(.headline)
                        .lineLimit(2)
                    if player.currentConversation?.isInternal == true {
                        Text("Internal")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.indigo.opacity(0.15), in: Capsule())
                    }
                }
                participantsMenu
            }
            Spacer(minLength: 0)
            if let conversation = player.currentConversation {
                let isFavorite = favorites.contains { $0.conversationID == conversation.id }
                Button {
                    Haptics.tap()
                    FavoritesStore.toggle(conversation, in: modelContext)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isFavorite ? .pink : .secondary)
                }
                Menu {
                    ForEach(playlists) { playlist in
                        Button {
                            playlist.toggle(conversation)
                            try? modelContext.save()
                            Haptics.tap()
                        } label: {
                            if playlist.contains(conversation.id) {
                                Label(playlist.name, systemImage: "checkmark")
                            } else {
                                Text(playlist.name)
                            }
                        }
                    }
                    Button {
                        newPlaylistName = ""
                        isNamingPlaylist = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("New Playlist", isPresented: $isNamingPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let conversation = player.currentConversation else { return }
                let playlist = Playlist(name: name)
                playlist.toggle(conversation)
                modelContext.insert(playlist)
                try? modelContext.save()
                Haptics.success()
            }
        } message: {
            Text("“\(player.currentConversation?.title ?? "This call")” will be added to it.")
        }
    }

    private var participantsMenu: some View {
        Menu {
            ForEach(player.currentConversation?.participants ?? [], id: \.stableID) { participant in
                Button {
                    UIPasteboard.general.string = participant.email ?? participant.displayName ?? ""
                } label: {
                    Text(participant.displayName ?? participant.email ?? "Unknown")
                    if let email = participant.email, email != participant.displayName {
                        Text(email)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(participantSummary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var participantSummary: String {
        let participants = player.currentConversation?.participants ?? []
        let names = participants.compactMap { participant -> String? in
            guard let display = participant.displayName else { return nil }
            // First name (or the mailbox part of an email) keeps the line short.
            if display.contains("@") { return String(display.split(separator: "@").first ?? "") }
            return String(display.split(separator: " ").first ?? "")
        }
        guard !names.isEmpty else { return player.currentConversation?.subtitle ?? "" }
        let shown = names.prefix(3).joined(separator: ", ")
        let extra = names.count - min(3, names.count)
        return extra > 0 ? "\(shown) +\(extra)" : shown
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search transcript", text: $transcriptQuery)
                .focused($transcriptSearchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { stepMatch(1) }
            if !transcriptMatches.isEmpty {
                Text("\(min(activeMatchIndex, transcriptMatches.count - 1) + 1) of \(transcriptMatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if trimmedTranscriptQuery.count >= 2 {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button { stepMatch(-1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(transcriptMatches.isEmpty)
            Button { stepMatch(1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(transcriptMatches.isEmpty)
            Button {
                closeTranscriptSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onChange(of: transcriptQuery) { _, _ in
            activeMatchIndex = 0
            if !transcriptMatches.isEmpty {
                searchScrollNonce += 1
            }
        }
    }

    private func stepMatch(_ delta: Int) {
        let count = transcriptMatches.count
        guard count > 0 else { return }
        activeMatchIndex = ((min(activeMatchIndex, count - 1) + delta) % count + count) % count
        searchScrollNonce += 1
    }

    private func closeTranscriptSearch() {
        isSearchingTranscript = false
        transcriptQuery = ""
        activeMatchIndex = 0
        transcriptSearchFocused = false
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            CallScrubber(
                segments: player.currentTranscript,
                duration: player.duration,
                currentTime: player.currentTime,
                speakerColors: speakerColors
            ) { time in
                player.seek(to: time)
            }
            .frame(height: 34)

            HStack {
                Text(player.currentTime.shortDuration)
                Spacer()
                Button {
                    showRemainingTime.toggle()
                } label: {
                    Text(showRemainingTime
                         ? "-" + max(0, player.duration - player.currentTime).shortDuration
                         : player.duration.shortDuration)
                }
                .buttonStyle(.plain)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 26) {
                transportButton(icon: "backward.end.fill", caption: "Speaker") {
                    player.skipToPreviousSpeaker()
                }
                transportButton(icon: "gobackward.\(Int(player.skipInterval))", caption: "\(Int(player.skipInterval))s") {
                    player.skip(by: -player.skipInterval)
                }
                Button {
                    Haptics.tap()
                    player.playPause()
                } label: {
                    // Invisible caption mirrors the transport buttons' layout so
                    // all icons share the same vertical center.
                    VStack(spacing: 3) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 58))
                        Text(" ")
                            .font(.system(size: 9, weight: .medium))
                            .hidden()
                    }
                }
                transportButton(icon: "goforward.\(Int(player.skipInterval))", caption: "\(Int(player.skipInterval))s") {
                    player.skip(by: player.skipInterval)
                }
                transportButton(icon: "forward.end.fill", caption: "Next call") {
                    player.playNext()
                }
            }

            HStack(spacing: 10) {
                Menu {
                    Picker("Speed", selection: $player.playbackRate) {
                        ForEach([0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5], id: \.self) { rate in
                            Text("\(rate, specifier: "%.2g")x").tag(Float(rate))
                        }
                    }
                } label: {
                    pill(text: String(format: "%.2gx", player.playbackRate), active: player.playbackRate != 1.0)
                }

                Button {
                    Haptics.tap()
                    player.smartSpeedEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hare.fill")
                            .font(.caption)
                        Text("Skip silence")
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        player.smartSpeedEnabled ? Color.indigo.opacity(0.18) : Color.secondary.opacity(0.1),
                        in: Capsule()
                    )
                    .foregroundStyle(player.smartSpeedEnabled ? Color.indigo : Color.primary)
                }
                .buttonStyle(.plain)

                Spacer()

                AirPlayRoutePicker()
                    .frame(width: 28, height: 28)

                Button {
                    isShowingQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.body.weight(.medium))
                        .frame(width: 28, height: 28)
                        .overlay(alignment: .topTrailing) {
                            if !player.queue.isEmpty {
                                Text("\(player.queue.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(.indigo, in: Circle())
                                    .offset(x: 5, y: -4)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: pill helper

    private func pill(text: String, active: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? Color.indigo.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(active ? Color.indigo : Color.primary)
    }

    private func transportButton(icon: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.title2)
                Text(caption)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func createDraftFromSelection() {
        guard let conversation = player.currentConversation else { return }
        let segments = snippetSelection.selectedSegments(in: player.currentTranscript)
        guard !segments.isEmpty else { return }
        if let draft = SnippetDraft.fromSegments(conversation: conversation, segments: segments) {
            snippetDraft = draft
            snippetSelection.cancel()
        } else {
            snippetError = "This call is missing the owner user ID Attention needs to create a snippet."
        }
    }
}

@MainActor
final class SnippetSelectionState: ObservableObject {
    @Published var isSelecting = false
    @Published var anchorID: String?
    @Published var focusID: String?

    func beginSelecting() {
        isSelecting = true
        anchorID = nil
        focusID = nil
    }

    func cancel() {
        isSelecting = false
        anchorID = nil
        focusID = nil
    }

    func select(_ segment: TranscriptSegment) {
        if !isSelecting {
            beginSelecting()
        }
        if anchorID == nil {
            anchorID = segment.id
            focusID = segment.id
        } else {
            focusID = segment.id
        }
    }

    func isSelected(_ segment: TranscriptSegment, in transcript: [TranscriptSegment]) -> Bool {
        guard let anchorID, let focusID,
              let start = transcript.firstIndex(where: { $0.id == anchorID }),
              let end = transcript.firstIndex(where: { $0.id == focusID })
        else {
            return false
        }
        let range = start <= end ? start...end : end...start
        return transcript.indices.contains(where: { range.contains($0) && transcript[$0].id == segment.id })
    }

    /// Set-based variant so the transcript can check membership in O(1) per row.
    func selectedIDs(in transcript: [TranscriptSegment]) -> Set<String> {
        Set(selectedSegments(in: transcript).map(\.id))
    }

    func selectedSegments(in transcript: [TranscriptSegment]) -> [TranscriptSegment] {
        guard let anchorID, let focusID,
              let start = transcript.firstIndex(where: { $0.id == anchorID }),
              let end = transcript.firstIndex(where: { $0.id == focusID })
        else {
            return []
        }
        let lower = min(start, end)
        let upper = max(start, end)
        return Array(transcript[lower...upper])
    }
}

struct SnippetSelectionBanner: View {
    @ObservedObject var selection: SnippetSelectionState
    let onCreate: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Select transcript bubbles")
                    .font(.caption.bold())
                Text(selection.anchorID == nil ? "Tap a start bubble, then an end bubble." : "Range selected. Adjust by tapping another bubble.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: selection.cancel)
                .font(.caption)
            Button("Create", action: onCreate)
                .font(.caption.bold())
                .disabled(selection.anchorID == nil)
        }
        .padding(10)
        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TranscriptView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject var selection: SnippetSelectionState
    var speakerColors: [String: Color] = [:]
    var searchQuery: String = ""
    var activeSearchMatchID: String?
    var searchScrollNonce: Int = 0
    var onCreateSnippet: (SnippetDraft) -> Void
    @State private var followPlayback = true
    @State private var scrollRequestID: String?

    var body: some View {
        // Computed once per update, not once per segment — with thousands of
        // words these lookups dominated scrolling performance on long calls.
        let activeWord = player.currentWord()
        let activeSegmentID = player.activeSegment()?.id
        let selectedIDs = selection.isSelecting ? selection.selectedIDs(in: player.currentTranscript) : []
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if player.currentTranscript.isEmpty {
                            ContentUnavailableView("No Transcript", systemImage: "text.bubble", description: Text("Open a call with a completed transcript to see word-level sync."))
                        }
                        ForEach(player.currentTranscript) { segment in
                            TranscriptSegmentView(
                                segment: segment,
                                activeWord: segment.id == activeSegmentID ? activeWord : nil,
                                isSelected: selectedIDs.contains(segment.id),
                                speakerColor: speakerColors[segment.speaker?.stableID ?? ""] ?? .indigo,
                                searchQuery: searchQuery,
                                isActiveSearchMatch: activeSearchMatchID == segment.id,
                                onTap: {
                                    if selection.isSelecting {
                                        selection.select(segment)
                                    } else {
                                        followPlayback = true
                                        player.seek(to: segment.startTime)
                                    }
                                },
                                onCopy: {
                                    UIPasteboard.general.string = segment.text
                                },
                                onCreateSnippet: {
                                    guard let conversation = player.currentConversation,
                                          let draft = SnippetDraft.fromSegments(conversation: conversation, segments: [segment])
                                    else { return }
                                    onCreateSnippet(draft)
                                },
                                onStartRange: {
                                    selection.beginSelecting()
                                    selection.select(segment)
                                }
                            )
                            .equatable()
                            .id(segment.id)
                        }
                    }
                    .padding(.vertical)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            followPlayback = false
                        }
                )

                if !followPlayback, !selection.isSelecting, !player.currentTranscript.isEmpty {
                    Button {
                        followPlayback = true
                        // last(where:) not activeSegment(): the playhead often sits
                        // in a silence gap between segments, where activeSegment()
                        // is nil and the jump would silently go nowhere.
                        scrollRequestID = player.currentTranscript.last(where: { $0.startTime <= player.currentTime })?.id
                            ?? player.currentTranscript.first?.id
                    } label: {
                        Label("Jump to current", systemImage: "text.aligncenter")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.bottom, 8)
                }
            }
            // Open positioned at the current playback spot, not the top.
            .onAppear {
                jumpToPlayhead(proxy: proxy)
            }
            // The transcript loads asynchronously; if the view appeared before
            // it arrived, position once it lands.
            .onChange(of: player.currentTranscript.count) { _, _ in
                jumpToPlayhead(proxy: proxy)
            }
            .onChange(of: player.activeSegment()?.id) { _, id in
                guard let id, followPlayback, !selection.isSelecting else { return }
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Track the active word so long monologue blocks scroll line by
            // line instead of parking on the segment's center. Words on the
            // same line share a vertical position, so most changes are no-ops
            // and the view only glides down when the speech wraps to a new line.
            .onChange(of: player.currentWord()?.id) { _, wordID in
                guard let wordID, followPlayback, !selection.isSelecting else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(wordID, anchor: .center)
                }
            }
            .onChange(of: scrollRequestID) { _, id in
                guard let id else { return }
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
                scrollRequestID = nil
            }
            .onChange(of: searchScrollNonce) { _, _ in
                guard let id = activeSearchMatchID else { return }
                followPlayback = false
                withAnimation {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: selection.isSelecting) { _, selecting in
                if selecting {
                    followPlayback = false
                }
            }
        }
    }

    /// Instantly position the transcript at the playhead (no animation), e.g.
    /// when the player is opened mid-call.
    private func jumpToPlayhead(proxy: ScrollViewProxy) {
        guard followPlayback, !selection.isSelecting, player.currentTime > 1 else { return }
        // last(where:) instead of activeSegment(): lands on the right spot even
        // when the playhead sits in a silence between segments.
        guard let id = player.currentTranscript.last(where: { $0.startTime <= player.currentTime })?.id else { return }
        proxy.scrollTo(id, anchor: .center)
    }
}

/// Equatable so SwiftUI skips re-rendering the (word-heavy) segments whose
/// inputs didn't change on each playback tick. Closures are excluded: they are
/// recreated every update but always do the same thing for a given segment.
struct TranscriptSegmentView: View, Equatable {
    let segment: TranscriptSegment
    let activeWord: TranscriptWord?
    let isSelected: Bool
    var speakerColor: Color = .indigo
    var searchQuery: String = ""
    var isActiveSearchMatch: Bool = false
    let onTap: () -> Void
    let onCopy: () -> Void
    let onCreateSnippet: () -> Void
    let onStartRange: () -> Void

    static func == (lhs: TranscriptSegmentView, rhs: TranscriptSegmentView) -> Bool {
        lhs.segment.id == rhs.segment.id
            && lhs.activeWord?.id == rhs.activeWord?.id
            && lhs.isSelected == rhs.isSelected
            && lhs.speakerColor == rhs.speakerColor
            && lhs.searchQuery == rhs.searchQuery
            && lhs.isActiveSearchMatch == rhs.isActiveSearchMatch
    }

    var body: some View {
        // Not a Button: a wrapping button would swallow taps meant for the ⋮
        // menu, and .contextMenu would lift the (sometimes huge) bubble into a
        // translucent preview. Tap gesture on the bubble, real Menu inside.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 8, height: 8)
                Text(segment.speaker?.displayName ?? "Unknown")
                    .font(.caption.bold())
                    .foregroundStyle(speakerColor)
                if segment.speaker?.type == "internal" {
                    Text("Internal")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.indigo.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(segment.startTime.shortDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                    Button("Create snippet", systemImage: "scissors", action: onCreateSnippet)
                    Button("Select range…", systemImage: "selection.pin.in.out", action: onStartRange)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
            }
            FlowLayout(alignment: .leading, spacing: 4) {
                ForEach(segment.words) { word in
                    Text(word.text)
                        .font(.body)
                        // Highlight drawn outside the text bounds so the
                        // active word never shifts the layout.
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(wordBackground(word))
                                .padding(-2)
                        )
                        // Scroll anchor so follow mode can track the active
                        // word through long monologue blocks.
                        .id(word.id)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.indigo.opacity(0.16) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(strokeColor, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // Custom preview: long-pressing a huge monologue bubble no longer lifts
        // the whole thing into a screen-filling translucent copy — it shows a
        // compact card instead (same pattern as link previews in Messages).
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
            Button("Create snippet", systemImage: "scissors", action: onCreateSnippet)
            Button("Select range…", systemImage: "selection.pin.in.out", action: onStartRange)
        } preview: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(speakerColor)
                        .frame(width: 8, height: 8)
                    Text(segment.speaker?.displayName ?? "Unknown")
                        .font(.caption.bold())
                        .foregroundStyle(speakerColor)
                    Spacer()
                    Text(segment.startTime.shortDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.subheadline)
                    .lineLimit(6)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }

    private var strokeColor: Color {
        if isSelected { return .indigo }
        if isActiveSearchMatch { return .yellow }
        return .clear
    }

    private func wordBackground(_ word: TranscriptWord) -> Color {
        if activeWord?.id == word.id {
            return Color.indigo.opacity(0.25)
        }
        if !searchQuery.isEmpty, word.text.localizedCaseInsensitiveContains(searchQuery) {
            return Color.yellow.opacity(isActiveSearchMatch ? 0.5 : 0.28)
        }
        return .clear
    }
}

/// Video-editor style trim control: two independent handles marking a window.
struct RangeTrimSlider: View {
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval
    let bounds: ClosedRange<TimeInterval>
    var minGap: TimeInterval = 1

    private let handleWidth: CGFloat = 18
    private let trackHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let span = max(0.001, bounds.upperBound - bounds.lowerBound)
            let startX = CGFloat((start - bounds.lowerBound) / span) * width
            let endX = CGFloat((end - bounds.lowerBound) / span) * width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.indigo.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.indigo, lineWidth: 2)
                    )
                    .frame(width: max(2, endX - startX), height: trackHeight)
                    .offset(x: startX)

                // Handles bracket the window from the outside so a short clip
                // in a long call still shows two separate, grabbable handles.
                handle(edge: .leading, x: startX - handleWidth, trackWidth: width, span: span)
                handle(edge: .trailing, x: endX, trackWidth: width, span: span)
            }
            .coordinateSpace(name: "trimTrack")
        }
        .frame(height: trackHeight)
        .padding(.horizontal, handleWidth)
    }

    private func handle(edge: HorizontalEdge, x: CGFloat, trackWidth: CGFloat, span: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.indigo)
            .frame(width: handleWidth, height: trackHeight + 8)
            .overlay(
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: 16)
            )
            .contentShape(Rectangle().inset(by: -14))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("trimTrack"))
                    .onChanged { value in
                        let fraction = min(max(0, value.location.x / trackWidth), 1)
                        let time = bounds.lowerBound + TimeInterval(fraction) * span
                        if edge == .leading {
                            start = min(max(bounds.lowerBound, time), end - minGap)
                        } else {
                            end = max(min(bounds.upperBound, time), start + minGap)
                        }
                    }
            )
            .offset(x: x)
    }
}

/// Transcript words around the clip; tapping a word snaps the nearest clip edge
/// to it, so precise selections work like adjusting a text highlight.
struct WordSelectionView: View {
    let segments: [TranscriptSegment]
    @Binding var start: TimeInterval
    @Binding var end: TimeInterval

    @State private var padBefore: TimeInterval = 15
    @State private var padAfter: TimeInterval = 30

    private var windowStart: TimeInterval { max(0, start - padBefore) }
    private var windowEnd: TimeInterval { end + padAfter }

    private var visibleSegments: [TranscriptSegment] {
        segments.filter { $0.endTime >= windowStart && $0.startTime <= windowEnd }
    }

    /// Anchor for auto-scrolling the selection into view.
    private var firstSelectedWordID: String? {
        for segment in visibleSegments {
            if let word = segment.words.first(where: { $0.endTimestamp >= start && $0.startTimestamp <= end }) {
                return word.id
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                padBefore += 60
            } label: {
                Label("Show earlier words", systemImage: "chevron.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(visibleSegments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                if let name = segment.speaker?.displayName {
                                    Text(name)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                                FlowLayout(alignment: .leading, spacing: 4) {
                                    ForEach(visibleWords(in: segment)) { word in
                                        wordView(word)
                                            .id(word.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 280)
                // Open with the selection in view, not the lead-in context above it.
                .onAppear {
                    guard let id = firstSelectedWordID else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.12))
                    }
                }
            }

            Button {
                padAfter += 60
            } label: {
                Label("Show later words", systemImage: "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func visibleWords(in segment: TranscriptSegment) -> [TranscriptWord] {
        segment.words.filter { $0.endTimestamp >= windowStart && $0.startTimestamp <= windowEnd }
    }

    private func wordView(_ word: TranscriptWord) -> some View {
        let isSelected = word.endTimestamp >= start && word.startTimestamp <= end
        return Text(word.text.trimmingCharacters(in: .whitespaces))
            .font(.callout)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                isSelected ? Color.indigo.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .onTapGesture { adjustEdge(to: word) }
    }

    private func adjustEdge(to word: TranscriptWord) {
        if word.startTimestamp < start {
            start = word.startTimestamp
        } else if word.endTimestamp > end {
            end = word.endTimestamp
        } else if (word.startTimestamp - start) <= (end - word.endTimestamp) {
            // Tap inside the selection moves whichever edge is closer.
            start = word.startTimestamp
        } else {
            end = word.endTimestamp
        }
        Haptics.tap()
    }
}

struct SnippetComposerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State var draft: SnippetDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var createdURL: URL?
    @State private var didCopy = false
    @State private var showFullTranscript = false
    @Query(sort: \SnippetFolder.name) private var folders: [SnippetFolder]
    @State private var localFolder = ""
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let createdURL {
                    savedConfirmationView(url: createdURL)
                } else {
                    composerForm
                }
            }
            .navigationTitle(createdURL == nil ? "Create Snippet" : "Snippet Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if createdURL == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save & copy") {
                            Task { await saveAndCopy() }
                        }
                        .disabled(isSaving || draft.endTime <= draft.startTime)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .alert("Snippet Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            // Trimming a clip while the call keeps talking over you is disorienting.
            .onAppear {
                if player.isPlaying { player.pause() }
                // Attribute the snippet to me (not the call's owner) so it lands
                // in my Attention library and shows under my user on the web.
                if let mine = appState.myUserUUID?.nilIfBlank {
                    draft.userUUID = mine
                }
                // Web destination is automatic: my library when my email is
                // set, the org library otherwise. Folders are local-only.
                draft.myLibrary = appState.myUserUUID?.nilIfBlank != nil
                draft.libraryFolder = ""
            }
        }
    }

    private var composerForm: some View {
            Form {
                Section("Clip") {
                    HStack {
                        TextField("Title", text: $draft.title)
                        ClearButton(text: $draft.title)
                    }
                    HStack(alignment: .top) {
                        TextField("Notes", text: $draft.notes, axis: .vertical)
                        ClearButton(text: $draft.notes)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        RangeTrimSlider(
                            start: $draft.startTime,
                            end: $draft.endTime,
                            bounds: 0...trimUpperBound
                        )
                        HStack {
                            edgeNudger(
                                time: draft.startTime,
                                minus: { draft.startTime = max(0, draft.startTime - 1) },
                                plus: { draft.startTime = min(draft.endTime - 1, draft.startTime + 1) }
                            )
                            Spacer()
                            Text("\((draft.endTime - draft.startTime).shortDuration) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            edgeNudger(
                                time: draft.endTime,
                                minus: { draft.endTime = max(draft.startTime + 1, draft.endTime - 1) },
                                plus: { draft.endTime = min(trimUpperBound, draft.endTime + 1) }
                            )
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                    Button {
                        if isPreviewingClip {
                            player.pause()
                        } else {
                            player.previewWindow(start: draft.startTime, end: draft.endTime)
                        }
                    } label: {
                        Label(
                            isPreviewingClip ? "Stop preview" : "Preview clip",
                            systemImage: isPreviewingClip ? "stop.fill" : "play.fill"
                        )
                    }
                }

                if !liveSegments.isEmpty {
                    Section {
                        WordSelectionView(
                            segments: liveSegments,
                            start: $draft.startTime,
                            end: $draft.endTime
                        )
                    } header: {
                        Text("Select words")
                    } footer: {
                        Text("Highlighted words are in the clip. Tap any word to move the nearest clip edge to it, like adjusting a text selection.")
                    }
                } else if !draft.previewText.isEmpty {
                    Section {
                        Text(draft.previewText)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(showFullTranscript ? nil : 5)
                            .animation(.easeInOut(duration: 0.2), value: showFullTranscript)

                        Button(showFullTranscript ? "Show less" : "Show full transcript") {
                            showFullTranscript.toggle()
                        }
                    } header: {
                        Text("Transcript preview")
                    }
                }

                Section {
                    Toggle("Require login", isOn: $draft.requireLogin)
                    Toggle("Notify me on views", isOn: $draft.notifyOnViews)
                    Toggle("Add to library", isOn: $draft.addToLibrary)
                } header: {
                    Text("Share options")
                } footer: {
                    if appState.myUserUUID?.nilIfBlank != nil, appState.myEmail.contains("@") {
                        Text("Require login limits viewing to people in your Attention org. Add to library saves the snippet to your web library as \(appState.myEmail).")
                    } else {
                        Text("Require login limits viewing to people in your Attention org. Add to library saves the snippet to the org's web library. Set your email in Settings to save under your account.")
                    }
                }

                Section {
                    Picker("Folder", selection: $localFolder) {
                        Text("None").tag("")
                        ForEach(folders) { folder in
                            Text(folder.name).tag(folder.name)
                        }
                    }
                    Button {
                        newFolderName = ""
                        isNamingFolder = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("On this phone")
                } footer: {
                    Text("Folders organize snippets in the Snippets tab. They stay on this phone.")
                }

            }
            .alert("New Folder", isPresented: $isNamingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    if !folders.contains(where: { $0.name == name }) {
                        modelContext.insert(SnippetFolder(name: name))
                        try? modelContext.save()
                    }
                    localFolder = name
                }
            }
    }

    private func savedConfirmationView(url: URL) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Snippet saved")
                .font(.title2.bold())
            Text(didCopy ? "The link is on your clipboard." : "Your snippet link is ready.")
                .foregroundStyle(.secondary)
            Text(url.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            VStack(spacing: 12) {
                Button {
                    UIPasteboard.general.url = url
                    UIPasteboard.general.string = url.absoluteString
                    didCopy = true
                    Haptics.tap()
                } label: {
                    Label(didCopy ? "Copied" : "Copy link", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
            Spacer()
            Spacer()
        }
    }

    private var trimUpperBound: TimeInterval {
        draft.duration > 0 ? draft.duration : max(draft.endTime + 30, 60)
    }

    private var isPreviewingClip: Bool {
        player.isPlaying && player.previewStopTime != nil
            && player.currentConversation?.id == draft.conversationID
    }

    private var liveSegments: [TranscriptSegment] {
        guard player.currentConversation?.id == draft.conversationID else { return [] }
        return player.currentTranscript
    }

    private func edgeNudger(time: TimeInterval, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: minus) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            Text(time.shortDuration)
                .monospacedDigit()
            Button(action: plus) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func saveAndCopy() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let created = try await appState.client.createSnippet(draft)
            createdURL = created.url
            UIPasteboard.general.url = created.url
            UIPasteboard.general.string = created.url.absoluteString
            didCopy = true
            Haptics.success()
            // The API can't list snippets back, so remember it locally for the Snippets tab.
            modelContext.insert(SavedSnippet(
                snippetID: created.id,
                title: draft.title.nilIfBlank ?? "Snippet",
                callTitle: draft.callTitle,
                conversationID: draft.conversationID,
                startTime: draft.startTime,
                endTime: draft.endTime,
                urlString: created.url.absoluteString,
                notes: draft.notes,
                inLibrary: draft.addToLibrary,
                inMyLibrary: draft.myLibrary,
                localFolder: localFolder
            ))
            try? modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CallDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    let conversation: Conversation
    var onCreateSnippet: (SnippetDraft) -> Void
    @State private var snippetError: String?

    private var intelligenceItems: [ExtractedIntelligenceItem] {
        Array(conversation.confirmedExtractedIntelligence.values) + Array(conversation.extractedIntelligence.values)
    }

    var body: some View {
        NavigationStack {
            List {
                callMetadataSection
                participantsSection
                if !conversation.scorecardResults.isEmpty {
                    scorecardsSection
                }
                if !intelligenceItems.isEmpty {
                    intelligenceSection
                }
                sharingSection
            }
            .navigationTitle("Call Details")
            .alert("Snippet", isPresented: Binding(
                get: { snippetError != nil },
                set: { if !$0 { snippetError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(snippetError ?? "")
            }
        }
    }

    private var callMetadataSection: some View {
        Section("Call") {
            LabeledContent("Title", value: conversation.title)
            LabeledContent("Duration", value: conversation.duration.shortDuration)
            if let date = conversation.createdAt {
                LabeledContent("Created", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let opportunity = conversation.externalOpportunity?.title {
                LabeledContent("Opportunity", value: opportunity)
            }
        }
    }

    private var participantsSection: some View {
        Section("Participants") {
            ForEach(conversation.participants, id: \.stableID) { participant in
                VStack(alignment: .leading) {
                    Text(participant.displayName ?? "Unknown")
                    if let email = participant.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scorecardsSection: some View {
        Section("Scorecards") {
            ForEach(conversation.scorecardResults) { scorecard in
                VStack(alignment: .leading, spacing: 6) {
                    Text(scorecard.title ?? "Scorecard")
                        .font(.headline)
                    if let average = scorecard.summary?.averageScore {
                        Text("Average \(average, specifier: "%.0f")")
                            .font(.subheadline)
                    }
                    if let summary = scorecard.summary?.summaryText {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var intelligenceSection: some View {
        Section("Extracted Intelligence") {
            ForEach(intelligenceItems) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? item.key ?? "Insight")
                        .font(.headline)
                    if let value = item.value {
                        Text(value)
                    }
                    if let source = item.scopeInsight {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sharingSection: some View {
        Section("Sharing") {
            if let webURL = conversation.webURL {
                ShareLink(item: webURL) {
                    Label("Share call link", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.url = webURL
                    UIPasteboard.general.string = webURL.absoluteString
                    Haptics.tap()
                } label: {
                    Label("Copy call link", systemImage: "doc.on.doc")
                }
            }
            Button {
                if let draft = SnippetDraft.aroundCurrentMoment(
                    conversation: conversation,
                    currentTime: player.currentTime
                ) {
                    onCreateSnippet(draft)
                } else {
                    snippetError = "This call is missing the owner user ID Attention needs to create a snippet."
                }
            } label: {
                Label("Create snippet around current moment", systemImage: "scissors")
            }
        }
    }
}

/// Keeps the last Ask Attention question and answers per call, so reopening
/// the sheet (e.g. after tapping a source link) restores the previous session.
@MainActor
enum AskSessionCache {
    static var sessions: [String: (prompt: String, answers: [AskAttentionItem])] = [:]
}

struct AskCallView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var prompt = ""
    @State private var answers: [AskAttentionItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Briefly highlights the tapped source row before the sheet dismisses.
    @State private var tappedSegmentID: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top) {
                        TextField("What are the key takeaways?", text: $prompt, axis: .vertical)
                            .focused($promptFocused)
                        if !prompt.isEmpty {
                            Button {
                                prompt = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        promptFocused = false
                        Task { await ask() }
                    } label: {
                        Label("Ask Attention", systemImage: "sparkles")
                    }
                    .disabled(prompt.nilIfBlank == nil || isLoading)
                }

                if isLoading {
                    ProgressView()
                }

                ForEach(answers) { answer in
                    Section(answer.title ?? conversation.title) {
                        Text(answer.error?.nilIfBlank ?? answer.output)
                        ForEach(answer.segments ?? []) { segment in
                            Button {
                                guard let start = segment.startSec else { return }
                                withAnimation(.easeIn(duration: 0.1)) {
                                    tappedSegmentID = segment.id
                                }
                                Haptics.tap()
                                player.seek(to: start)
                                if !player.isPlaying {
                                    player.playPause()
                                }
                                // Let the highlight flash register before the sheet goes away.
                                Task {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(segment.text ?? "")
                                    if let start = segment.startSec {
                                        Text(start.shortDuration)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .listRowBackground(
                                tappedSegmentID == segment.id
                                    ? Color.indigo.opacity(0.22)
                                    : Color(.secondarySystemGroupedBackground)
                            )
                        }
                    }
                }
            }
            .navigationTitle("Ask This Call")
            .onAppear {
                if let session = AskSessionCache.sessions[conversation.id] {
                    prompt = session.prompt
                    answers = session.answers
                }
            }
            .alert("Ask Attention Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func ask() async {
        guard let prompt = prompt.nilIfBlank else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            answers = try await appState.repository.ask(conversationID: conversation.id, prompt: prompt)
            AskSessionCache.sessions[conversation.id] = (prompt, answers)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
enum FavoritesStore {
    static func toggle(_ conversation: Conversation, in context: ModelContext) {
        let id = conversation.id
        let descriptor = FetchDescriptor<FavoriteCall>(predicate: #Predicate { $0.conversationID == id })
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        } else {
            context.insert(FavoriteCall(conversationID: id, title: conversation.title))
        }
        try? context.save()
    }
}

/// A device-local playlist: ordered calls, playable front to back like Spotify.
struct PlaylistDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var cachedConversations: [CachedConversation]
    @Query private var favorites: [FavoriteCall]
    @Query private var downloadedCalls: [DownloadedCall]

    let playlist: Playlist

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    /// Playlist entries resolved to playable conversations, in playlist order.
    private var resolvedConversations: [Conversation] {
        let cachedByID = Dictionary(cachedConversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlist.conversationIDs.map { id in
            cachedByID[id].map(Conversation.init(cache:))
                ?? Conversation(
                    id: id,
                    title: playlist.titlesByID[id] ?? "Untitled call",
                    createdAt: nil,
                    duration: 0
                )
        }
    }

    var body: some View {
        List {
            if playlist.conversationIDs.isEmpty {
                ContentUnavailableView(
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("Add calls from the ⋮ menu on any call row.")
                )
            } else {
                Section {
                    Button {
                        guard let first = resolvedConversations.first else { return }
                        Haptics.tap()
                        Task { await player.play(first, queue: resolvedConversations) }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.headline)
                    }
                }
                Section {
                    ForEach(resolvedConversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            downloadedCall: downloadedCalls.first { $0.conversationID == conversation.id },
                            isFavorite: favorites.contains { $0.conversationID == conversation.id },
                            onToggleFavorite: { FavoritesStore.toggle(conversation, in: modelContext) }
                        ) {
                            Task { await player.play(conversation, queue: resolvedConversations) }
                        }
                    }
                    .onMove { source, destination in
                        var ids = playlist.conversationIDs
                        ids.move(fromOffsets: source, toOffset: destination)
                        playlist.conversationIDs = ids
                        try? modelContext.save()
                    }
                    .onDelete { offsets in
                        var ids = playlist.conversationIDs
                        for offset in offsets {
                            playlist.titlesByID[ids[offset]] = nil
                        }
                        ids.remove(atOffsets: offsets)
                        playlist.conversationIDs = ids
                        try? modelContext.save()
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // EditButton inside a Menu is flaky (menu dismissal races the
            // edit-mode toggle), so it gets its own toolbar slot.
            if !playlist.conversationIDs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = playlist.name
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                playlist.name = name
                try? modelContext.save()
            }
        }
        .alert("Delete “\(playlist.name)”?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                modelContext.delete(playlist)
                try? modelContext.save()
                dismiss()
            }
        } message: {
            Text("The calls themselves are not affected.")
        }
    }
}

/// The "liked songs" folder: every favorited call, newest first.
struct FavoriteCallsView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FavoriteCall.createdAt, order: .reverse) private var favorites: [FavoriteCall]
    @Query private var cachedConversations: [CachedConversation]
    @Query private var downloadedCalls: [DownloadedCall]

    private var resolvedConversations: [Conversation] {
        let cachedByID = Dictionary(cachedConversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return favorites.map { favorite in
            cachedByID[favorite.conversationID].map(Conversation.init(cache:))
                ?? Conversation(
                    id: favorite.conversationID,
                    title: favorite.title,
                    createdAt: favorite.createdAt,
                    duration: 0
                )
        }
    }

    var body: some View {
        List {
            if favorites.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "heart",
                    description: Text("Tap the ⋮ menu on any call and choose Add to Favorites.")
                )
            } else {
                Section {
                    Button {
                        guard let first = resolvedConversations.first else { return }
                        Haptics.tap()
                        Task { await player.play(first, queue: resolvedConversations) }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.headline)
                    }
                }
                Section {
                    ForEach(resolvedConversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            downloadedCall: downloadedCalls.first { $0.conversationID == conversation.id },
                            isFavorite: true,
                            onToggleFavorite: { FavoritesStore.toggle(conversation, in: modelContext) }
                        ) {
                            Task { await player.play(conversation, queue: resolvedConversations) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A followed teammate's page: all calls they own, newest first — like an
/// artist page in Spotify.
struct ArtistDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var favorites: [FavoriteCall]
    @Query private var downloadedCalls: [DownloadedCall]

    let artist: FollowedArtist

    @State private var conversations: [Conversation] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.indigo)
                    Text(artist.name)
                        .font(.title3.bold())
                    Text(artist.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if !conversations.isEmpty {
                Section {
                    Button {
                        guard let first = conversations.first else { return }
                        Haptics.tap()
                        Task { await player.play(first, queue: conversations) }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.headline)
                    }
                }
            }

            Section {
                if conversations.isEmpty, !isLoading, errorMessage == nil {
                    Text("No calls with \(artist.name) yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        downloadedCall: downloadedCalls.first { $0.conversationID == conversation.id },
                        isFavorite: favorites.contains { $0.conversationID == conversation.id },
                        onToggleFavorite: { FavoritesStore.toggle(conversation, in: modelContext) }
                    ) {
                        Task { await player.play(conversation, queue: conversations) }
                    }
                    .task {
                        if conversation.id == conversations.last?.id {
                            await load(resetting: false)
                        }
                    }
                }
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Unfollow") {
                    modelContext.delete(artist)
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .task {
            await load(resetting: true)
        }
        .refreshable {
            await load(resetting: true)
        }
    }

    private func load(resetting: Bool) async {
        if resetting {
            page = 1
            pageCount = 1
        } else {
            guard !isLoading, page <= pageCount else { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // Participant filter, not owner: shows every call they were on
            // (matching what search returns), not just calls they own.
            let result = try await appState.repository.list(
                page: page,
                size: 25,
                participantEmails: [artist.email]
            )
            if resetting {
                conversations = result.0
            } else {
                conversations.append(contentsOf: result.0)
            }
            pageCount = max(result.1?.pageCount ?? page, 1)
            page += 1
            errorMessage = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// Directory of org teammates with follow toggles.
struct FollowPeopleView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FollowedArtist.name) private var followedArtists: [FollowedArtist]

    @State private var users: [AttentionUser] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var query = ""

    private var followedEmails: Set<String> {
        Set(followedArtists.map(\.email))
    }

    private var filteredUsers: [AttentionUser] {
        let myEmail = appState.myEmail.lowercased()
        let usable = users.filter {
            guard let email = $0.email?.nilIfBlank?.lowercased() else { return false }
            return email != myEmail
        }
        guard let needle = query.lowercased().nilIfBlank else { return usable }
        return usable.filter {
            ($0.displayName ?? "").lowercased().contains(needle)
                || ($0.email ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading teammates…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(filteredUsers, id: \.email) { user in
                let email = (user.email ?? "").lowercased()
                let isFollowing = followedEmails.contains(email)
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(isFollowing ? .indigo : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName ?? email)
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isFollowing ? "Following" : "Follow") {
                        Haptics.tap()
                        toggleFollow(email: email, name: user.displayName ?? email)
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(isFollowing ? .secondary : .indigo)
                }
            }
        }
        .navigationTitle("Follow People")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search teammates")
        .task {
            await loadUsers()
        }
        .refreshable {
            await loadUsers()
        }
    }

    private func toggleFollow(email: String, name: String) {
        guard !email.isEmpty else { return }
        let descriptor = FetchDescriptor<FollowedArtist>(predicate: #Predicate { $0.email == email })
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
        } else {
            modelContext.insert(FollowedArtist(email: email, name: name))
        }
        try? modelContext.save()
    }

    private func loadUsers() async {
        do {
            users = try await appState.repository.users()
                .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct ConversationRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.playlists) private var playlists
    let conversation: Conversation
    var isUnplayed: Bool = false
    var downloadedCall: DownloadedCall?
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?
    /// Tap anywhere on the row: play immediately (Spotify behavior).
    let onPlay: () -> Void

    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""

    private var isCurrent: Bool {
        player.currentConversation?.id == conversation.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if isCurrent {
                            SoundBars(animating: player.isPlaying)
                        } else if isUnplayed {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                        }
                        Text(conversation.title)
                            .font(.headline)
                            .lineLimit(2)
                            .foregroundStyle(isCurrent ? Color.indigo : Color.primary)
                    }
                    Text(conversation.subtitle)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? Color.indigo.opacity(0.8) : Color.secondary)
                    HStack(spacing: 6) {
                        Text(conversation.duration.shortDuration)
                        if let createdAt = conversation.createdAt {
                            Text("·")
                            Text(createdAt.compactRelativeLabel)
                        }
                        if isFavorite {
                            Text("·")
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                        if downloadedCall != nil {
                            Text("·")
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                        }
                        if downloads.isDownloading(conversation.id) {
                            Text("·")
                            ProgressView()
                                .controlSize(.mini)
                        }
                        if !conversation.isPlayable {
                            Text("·")
                            Text("Processing")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    player.enqueue([conversation])
                } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                if let onToggleFavorite {
                    Button {
                        Haptics.tap()
                        onToggleFavorite()
                    } label: {
                        Label(
                            isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite ? "heart.slash" : "heart"
                        )
                    }
                }
                Menu {
                    ForEach(playlists) { playlist in
                        Button {
                            Haptics.tap()
                            playlist.toggle(conversation)
                            try? modelContext.save()
                        } label: {
                            if playlist.contains(conversation.id) {
                                Label(playlist.name, systemImage: "checkmark")
                            } else {
                                Text(playlist.name)
                            }
                        }
                    }
                    Button {
                        newPlaylistName = ""
                        isNamingPlaylist = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                } label: {
                    Label("Add to Playlist", systemImage: "music.note.list")
                }
                if let webURL = conversation.webURL {
                    ShareLink(item: webURL) {
                        Label("Share Call Link", systemImage: "square.and.arrow.up")
                    }
                }
                if let downloadedCall {
                    Button(role: .destructive) {
                        downloads.delete(downloadedCall)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if !downloads.isDownloading(conversation.id) {
                    Button {
                        Task { await downloads.download(conversation) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .rotationEffect(.degrees(90))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .alert("New Playlist", isPresented: $isNamingPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let playlist = Playlist(name: name)
                playlist.toggle(conversation)
                modelContext.insert(playlist)
                try? modelContext.save()
                Haptics.success()
            }
        } message: {
            Text("“\(conversation.title)” will be added to it.")
        }
    }
}

/// Spotify-style animated equalizer bars shown next to the currently playing call.
struct SoundBars: View {
    var animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.indigo)
                        .frame(
                            width: 3,
                            height: animating
                                ? 4 + 10 * abs(sin(time * 2.7 + Double(index) * 1.9))
                                : 5
                        )
                }
            }
            .frame(width: 15, height: 15, alignment: .bottom)
        }
    }
}

struct ContinueListeningCard: View {
    let conversation: Conversation
    let bookmark: PlaybackBookmark?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if let bookmark, bookmark.duration > 0 {
                    ProgressView(value: bookmark.position, total: max(bookmark.duration, 1))
                        .tint(.indigo)
                    Text("\(max(0, bookmark.duration - bookmark.position).shortDuration) left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(conversation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "play.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.indigo)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Buckets a newest-first conversation list under "Today", "Yesterday", etc.
func groupConversationsByDate(_ conversations: [Conversation]) -> [(label: String, items: [Conversation])] {
    let calendar = Calendar.current
    let now = Date()
    var groups: [(label: String, items: [Conversation])] = []
    for conversation in conversations {
        let label: String
        if let date = conversation.createdAt {
            if calendar.isDateInToday(date) {
                label = "Today"
            } else if calendar.isDateInYesterday(date) {
                label = "Yesterday"
            } else if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) {
                label = "This Week"
            } else if let month = calendar.dateInterval(of: .month, for: now), month.contains(date) {
                label = "This Month"
            } else {
                label = "Earlier"
            }
        } else {
            label = "Earlier"
        }
        if groups.last?.label == label {
            groups[groups.count - 1].items.append(conversation)
        } else {
            groups.append((label, [conversation]))
        }
    }
    return groups
}

extension Date {
    /// "Today", "Yesterday", or a short date ("Aug 7", adding the year when it's not this year).
    var compactRelativeLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(.dateTime.year().month(.abbreviated).day())
    }
}

struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(for: subviews, proposalWidth: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposalWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                element.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(element.size))
                x += element.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, proposalWidth: CGFloat) -> [Row] {
        guard proposalWidth > 0 else {
            return []
        }

        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.width + size.width + spacing > proposalWidth, !current.elements.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.elements.append(Row.Element(subview: subview, size: size))
            current.width += size.width + spacing
            current.height = max(current.height, size.height)
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        struct Element {
            let subview: LayoutSubview
            let size: CGSize
        }

        var elements: [Element] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

extension Conversation {
    init(id: String, title: String, createdAt: Date?, duration: TimeInterval) {
        self.id = id
        self.userUUID = nil
        self.title = title
        self.createdAt = createdAt
        self.finishedAt = nil
        self.duration = duration
        self.ownerName = nil
        self.participants = []
        self.transcript = []
        self.videoStatus = "READY"
        self.mediaStorageStatus = "READY"
        self.transcriptStatus = nil
        self.isArchived = false
        self.isPrivate = false
        self.isInternal = false
        self.labels = [:]
        self.extractedIntelligence = [:]
        self.confirmedExtractedIntelligence = [:]
        self.externalOpportunity = nil
        self.linkedCRMRecords = []
        self.externalAccounts = []
        self.externalContacts = []
        self.scorecardResults = []
    }
}

enum LibraryDateRange: String, CaseIterable, Identifiable {
    case all
    case sevenDays
    case thirtyDays
    case ninetyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All time"
        case .sevenDays: return "Last 7 days"
        case .thirtyDays: return "Last 30 days"
        case .ninetyDays: return "Last 90 days"
        }
    }

    var bounds: (from: Date?, to: Date?) {
        let calendar = Calendar.current
        let to = Date()
        switch self {
        case .all:
            return (nil, nil)
        case .sevenDays:
            return (calendar.date(byAdding: .day, value: -7, to: to), to)
        case .thirtyDays:
            return (calendar.date(byAdding: .day, value: -30, to: to), to)
        case .ninetyDays:
            return (calendar.date(byAdding: .day, value: -90, to: to), to)
        }
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .systemIndigo
        view.activeTintColor = .systemIndigo
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

enum SpeakerPalette {
    static let colors: [Color] = [.indigo, .teal, .orange, .pink, .purple, .blue, .green, .brown]

    /// Stable color per speaker, in order of first appearance in the transcript.
    static func colorMap(for transcript: [TranscriptSegment]) -> [String: Color] {
        var map: [String: Color] = [:]
        for segment in transcript {
            let key = segment.speaker?.stableID ?? ""
            if map[key] == nil {
                map[key] = colors[map.count % colors.count]
            }
        }
        return map
    }
}

/// One scrubber that combines seek, progress, and speaker chapters:
/// the track is drawn from speaker-colored segments, dimmed after the playhead.
struct CallScrubber: View {
    let segments: [TranscriptSegment]
    let duration: TimeInterval
    let currentTime: TimeInterval
    let speakerColors: [String: Color]
    let onSeek: (TimeInterval) -> Void

    @State private var dragTime: TimeInterval?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let effectiveTime = dragTime ?? currentTime
            let progress = min(max(0, effectiveTime / max(duration, 1)), 1)

            ZStack(alignment: .leading) {
                track(width: width)
                    .opacity(0.3)
                track(width: width)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: max(0, progress * width))
                    }
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 3, height: 30)
                    .shadow(radius: 1)
                    .offset(x: min(max(0, progress * width - 1.5), width - 3))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(0, value.location.x / width), 1)
                        dragTime = fraction * max(duration, 1)
                    }
                    .onEnded { value in
                        let fraction = min(max(0, value.location.x / width), 1)
                        onSeek(fraction * max(duration, 1))
                        dragTime = nil
                    }
            )
        }
    }

    private func track(width: CGFloat) -> some View {
        // One Canvas pass instead of a SwiftUI view per segment: with hundreds
        // of segments the per-tick view diffing was measurable on long calls.
        Canvas { context, size in
            let barRect = CGRect(x: 0, y: (size.height - 8) / 2, width: size.width, height: 8)
            context.fill(Path(roundedRect: barRect, cornerRadius: 4), with: .color(Color.secondary.opacity(0.25)))

            for segment in segments {
                let start = min(max(0, segment.startTime / max(duration, 1)), 1)
                let end = min(max(start, segment.endTime / max(duration, 1)), 1)
                let rect = CGRect(
                    x: start * size.width,
                    y: (size.height - 18) / 2,
                    width: max(2, (end - start) * size.width),
                    height: 18
                )
                let color = speakerColors[segment.speaker?.stableID ?? ""] ?? .indigo
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .frame(height: 30)
    }
}
