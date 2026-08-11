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
    @Query(sort: \DownloadedCall.createdAt, order: .reverse) private var downloadedCalls: [DownloadedCall]

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

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                            Button("Retry") {
                                Task { await refresh() }
                            }
                        }
                    }
                }

                if let continueItem = continueListeningTarget {
                    Section("Continue Listening") {
                        Button {
                            Task { await player.play(continueItem.conversation, queue: conversations) }
                        } label: {
                            ContinueListeningCard(
                                conversation: continueItem.conversation,
                                bookmark: continueItem.bookmark
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !downloadedCalls.isEmpty {
                    Section {
                        Button {
                            appState.tab = .downloads
                        } label: {
                            HStack {
                                Label("Downloaded calls", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(downloadedCalls.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                recentCallSections
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

    @ViewBuilder
    private var recentCallSections: some View {
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
                            downloadedCall: downloadedByID[conversation.id]
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
                                await loadMoreIfNeeded()
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

    /// Most recently resumed unfinished call, skipping whatever is already loaded
    /// in the mini player so the section never duplicates it.
    private var continueListeningTarget: (conversation: Conversation, bookmark: PlaybackBookmark?)? {
        let currentID = player.currentConversation?.id
        for bookmark in bookmarks {
            guard bookmark.conversationID != currentID else { continue }
            // Treat calls within 30s of the end as finished.
            if bookmark.duration > 0, bookmark.position >= bookmark.duration - 30 { continue }
            if let conversation = conversation(for: bookmark.conversationID) {
                return (conversation, bookmark)
            }
        }
        // Nothing in progress: suggest the newest call, unless the player already has one loaded.
        if currentID == nil {
            if let conversation = conversations.first {
                return (conversation, nil)
            }
            if let cached = cachedConversations.first {
                return (Conversation(cache: cached), nil)
            }
        }
        return nil
    }
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecentSearch.updatedAt, order: .reverse) private var recentSearches: [RecentSearch]
    @Query(sort: \SuggestedEmail.updatedAt, order: .reverse) private var suggestedEmails: [SuggestedEmail]
    @Query private var downloadedCalls: [DownloadedCall]

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
            + [dateRange != .all, hideInternal, callsIOwn].filter { $0 }.count
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
            .searchable(text: $titleQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search call titles")
            .searchSuggestions {
                searchSuggestionsContent
            }
            .onSubmit(of: .search) {
                runSearch()
            }
            .onChange(of: titleQuery) { _, newValue in
                if newValue.isEmpty, hasSearched {
                    runSearch()
                }
            }
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

    @ViewBuilder
    private var searchSuggestionsContent: some View {
        if titleQuery.contains("@") {
            // Typing an email routes to the participant filter instead of title search.
            ForEach(EmailSuggestionStore.suggestions(matching: titleQuery, from: suggestedEmails)) { suggestion in
                Button {
                    addParticipant(suggestion.email)
                    titleQuery = ""
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.name ?? suggestion.email)
                            if suggestion.name != nil {
                                Text(suggestion.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        } else if titleQuery.isEmpty {
            ForEach(recentSearches.prefix(6)) { item in
                Button {
                    applyRecentSearch(item.query)
                } label: {
                    Label(item.query, systemImage: "clock.arrow.circlepath")
                }
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
                            downloadedCall: downloaded
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
        searchTask = Task { await search(resetting: true) }
    }

    private func clearAllFilters() {
        participantEmails = []
        dateRange = .all
        hideInternal = false
        callsIOwn = false
    }

    private func addParticipant(_ email: String) {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), !participantEmails.contains(normalized) else { return }
        participantEmails.append(normalized)
    }

    private func applyRecentSearch(_ value: String) {
        if value.contains("@") {
            addParticipant(value)
        } else {
            titleQuery = value
            runSearch()
        }
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

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    @Query(sort: \DownloadedCall.createdAt, order: .reverse) private var downloadedCalls: [DownloadedCall]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
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
            // Overlay instead of an inline row so deleting the last download lets the
            // row's removal animation finish before the empty state fades in.
            .overlay {
                if downloadedCalls.isEmpty, downloads.downloadingTitles.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Swipe a call in Library to save it for offline listening."))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3).delay(0.35), value: downloadedCalls.isEmpty)
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

struct SearchFiltersSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SuggestedEmail.updatedAt, order: .reverse) private var suggestedEmails: [SuggestedEmail]

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

                    TextField(participantEmails.isEmpty ? "Participant email" : "Add another participant", text: $emailDraft)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .focused($emailFocused)
                        .submitLabel(.return)
                        .onSubmit { commitEmail(emailDraft) }

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
            TextField("My email", text: $draftEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($emailFocused)
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
            Button {
                appState.tab = .downloads
            } label: {
                HStack {
                    Label("Manage downloads", systemImage: "arrow.down.circle")
                    Spacer()
                    Text("\(downloadedCalls.count) · \(formattedSize(downloadedCalls.reduce(0) { $0 + $1.fileSize }))")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
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
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 58))
                }
                transportButton(icon: "goforward.\(Int(player.skipInterval))", caption: "\(Int(player.skipInterval))s") {
                    player.skip(by: player.skipInterval)
                }
                transportButton(icon: "forward.end.fill", caption: "Speaker") {
                    player.skipToNextSpeaker()
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

                if !followPlayback, !selection.isSelecting, player.activeSegment() != nil {
                    Button {
                        followPlayback = true
                        scrollRequestID = player.activeSegment()?.id
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
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
            Button("Create snippet", systemImage: "scissors", action: onCreateSnippet)
            Button("Select range…", systemImage: "selection.pin.in.out", action: onStartRange)
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

    @State private var padBefore: TimeInterval = 30
    @State private var padAfter: TimeInterval = 30

    private var windowStart: TimeInterval { max(0, start - padBefore) }
    private var windowEnd: TimeInterval { end + padAfter }

    private var visibleSegments: [TranscriptSegment] {
        segments.filter { $0.endTime >= windowStart && $0.startTime <= windowEnd }
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
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

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

/// Browses the Attention snippet library folder tree, loading one level at a time.
struct LibraryFolderPickerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let userUUID: String
    let myLibrary: Bool
    let onSelect: (String) -> Void

    private struct Crumb: Hashable {
        let uuid: String
        let name: String
    }

    @State private var crumbs: [Crumb] = []
    @State private var subfolders: [LibrarySubFolder] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private var currentPath: String {
        crumbs.map { "/" + $0.name }.joined()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(currentPath)
                        dismiss()
                    } label: {
                        Label(
                            crumbs.isEmpty ? "Use root folder" : "Use “\(crumbs.last?.name ?? "")”",
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                }

                Section(crumbs.isEmpty ? "Folders" : currentPath) {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading folders…").foregroundStyle(.secondary)
                        }
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.secondary)
                    } else if subfolders.isEmpty {
                        Text("No subfolders").foregroundStyle(.secondary)
                    }
                    ForEach(subfolders) { folder in
                        Button {
                            crumbs.append(Crumb(uuid: folder.uuid, name: folder.name))
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if let count = folder.totalElements, count > 0 {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(myLibrary ? "My Library" : "Org Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if !crumbs.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            crumbs.removeLast()
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                }
            }
            .task(id: crumbs) {
                await loadCurrentLevel()
            }
        }
    }

    private func loadCurrentLevel() async {
        isLoading = true
        loadError = nil
        subfolders = []
        do {
            let folder = try await appState.client.listLibraryFolders(
                userUUID: userUUID,
                folderUUID: crumbs.last?.uuid,
                myLibrary: myLibrary
            )
            subfolders = folder.subFolders ?? []
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct SnippetComposerView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State var draft: SnippetDraft
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var createdURL: URL?
    @State private var didCopy = false
    @State private var showFullTranscript = false
    @State private var isPickingFolder = false

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
            }
            // Folder paths differ between the personal and org libraries.
            .onChange(of: draft.myLibrary) {
                draft.libraryFolder = ""
            }
            .sheet(isPresented: $isPickingFolder) {
                LibraryFolderPickerView(
                    userUUID: draft.userUUID,
                    myLibrary: draft.myLibrary
                ) { path in
                    draft.libraryFolder = path
                }
                .environmentObject(appState)
            }
        }
    }

    private var composerForm: some View {
            Form {
                Section("Clip") {
                    TextField("Title", text: $draft.title)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
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
                    if draft.addToLibrary {
                        Picker("Library", selection: $draft.myLibrary) {
                            Text("My library").tag(true)
                            Text("Org library").tag(false)
                        }
                        Button {
                            isPickingFolder = true
                        } label: {
                            HStack {
                                Text("Folder")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(draft.libraryFolder.nilIfBlank ?? "Root")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Share options")
                } footer: {
                    Text("Require login limits viewing to people in your Attention org. Add to library also saves the snippet to your personal or org snippet library on the web, not just as a share link.")
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

struct ConversationRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadManager
    let conversation: Conversation
    var isUnplayed: Bool = false
    var downloadedCall: DownloadedCall?
    /// Tap anywhere on the row: play immediately (Spotify behavior).
    let onPlay: () -> Void

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
