import Foundation
import Security
import SwiftData

enum AppError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case unexpectedResponse
    case attentionError(status: Int, message: String)
    case fileMissing

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an org-level Attention API key in Settings first."
        case .invalidURL:
            return "The request URL could not be built."
        case .unexpectedResponse:
            return "Attention returned an unexpected response."
        case .attentionError(let status, let message):
            return "Attention returned \(status): \(message)"
        case .fileMissing:
            return "The downloaded file is no longer available."
        }
    }
}

final class KeychainStore {
    private let service = "com.extend.attentioncallplayer"
    private let account = "attention-api-key"
    private let defaultsKey = "attention.apiKey.fallback"

    func readAPIKey() -> String? {
        if let keychainValue = readFromKeychain()?.nilIfBlank {
            return keychainValue
        }
        return UserDefaults.standard.string(forKey: defaultsKey)?.nilIfBlank
    }

    func saveAPIKey(_ apiKey: String) {
        let normalized = Self.normalizedAPIKey(apiKey)
        deleteAPIKey()
        guard !normalized.isEmpty else {
            return
        }

        // Always persist a fallback — unsigned simulator builds can fail Keychain writes.
        UserDefaults.standard.set(normalized, forKey: defaultsKey)

        guard let data = normalized.data(using: .utf8) else {
            return
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func deleteAPIKey() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func normalizedAPIKey(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

final class AttentionAPIClient {
    private let baseURL = URL(string: "https://api.attention.tech/v2")!
    private let session: URLSession
    private let keychain: KeychainStore

    init(keychain: KeychainStore, session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    /// True when the stored key is the App Review demo key: the app then runs
    /// against the bundled sample library instead of the Attention API.
    var isDemoMode: Bool {
        DemoLibrary.isDemoKey(keychain.readAPIKey())
    }

    func listConversations(
        page: Int,
        size: Int = 25,
        search: String? = nil,
        participantEmails: [String] = [],
        ownerEmail: String? = nil,
        hideInternal: Bool = false,
        fromDate: Date? = nil,
        toDate: Date? = nil
    ) async throws -> ConversationsResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "filter[hide_pending]", value: "true"),
            URLQueryItem(name: "filter[hide_failed]", value: "true"),
            URLQueryItem(name: "filter[hide_transcript]", value: "false"),
            URLQueryItem(name: "detailedTranscript", value: "false")
        ]

        if hideInternal {
            items.append(URLQueryItem(name: "filter[hide_internal]", value: "true"))
        }

        if let search = search?.nilIfBlank {
            items.append(URLQueryItem(name: "filter[title]", value: search))
        }

        for email in participantEmails.compactMap(\.nilIfBlank) {
            items.append(URLQueryItem(name: "filter[participants.email]", value: email))
        }

        if let ownerEmail = ownerEmail?.nilIfBlank {
            items.append(URLQueryItem(name: "filter[owner.email]", value: ownerEmail))
        }

        if let fromDate {
            items.append(URLQueryItem(name: "fromDateTime", value: ISO8601DateFormatter.withoutFractions.string(from: fromDate)))
        }

        if let toDate {
            items.append(URLQueryItem(name: "toDateTime", value: ISO8601DateFormatter.withoutFractions.string(from: toDate)))
        }

        return try await request(path: "/conversations", queryItems: items)
    }

    func getConversation(id: String, includeTranscript: Bool = true) async throws -> ConversationResource {
        try await request(path: "/conversations/\(id)", queryItems: [
            URLQueryItem(name: "detailedTranscript", value: includeTranscript ? "true" : "false"),
            URLQueryItem(name: "filter[include_internal_participants]", value: "true")
        ])
    }

    func generateMediaDownloadURL(conversationID: String) async throws -> URL {
        let response: MediaDownloadResponse = try await request(path: "/conversations/\(conversationID)/media/download", method: "POST")
        return response.url
    }

    func createSnippet(_ draft: SnippetDraft) async throws -> CreatedSnippetResponse {
        if isDemoMode {
            return DemoLibrary.createdSnippet()
        }
        func payload(includeReference: Bool) -> CreateSnippetRequest {
            let start = max(0, draft.startTime)
            let end = max(start + 1, draft.duration > 0 ? min(draft.endTime, draft.duration) : draft.endTime)
            return CreateSnippetRequest(
                userUUID: draft.userUUID,
                conversationID: draft.conversationID,
                reference: includeReference ? draft.reference : nil,
                video: SnippetTimespan(
                    startTime: start,
                    endTime: end,
                    duration: end - start
                ),
                notes: draft.notes.nilIfBlank,
                title: draft.title.nilIfBlank ?? "Snippet",
                inLibrary: draft.addToLibrary,
                libraryItemInfo: draft.addToLibrary
                    ? SnippetLibraryInfo(myLibrary: draft.myLibrary, folderPath: draft.libraryFolder.nilIfBlank)
                    : nil,
                internalSnippet: draft.requireLogin,
                notifyViews: draft.notifyOnViews
            )
        }

        do {
            return try await request(path: "/snippets", method: "POST", body: payload(includeReference: true))
        } catch {
            // The transcript-reference indices are the most fragile part of the payload;
            // if the server chokes on them, retry once without the reference.
            guard draft.reference != nil else { throw error }
            return try await request(path: "/snippets", method: "POST", body: payload(includeReference: false))
        }
    }

    func askAttention(conversationID: String, prompt: String) async throws -> [AskAttentionItem] {
        // deal_id is a required key, but only one of deal_id / conversations_ids
        // may carry a value — so it's sent empty when asking about conversations.
        let body = AskAttentionRequest(conversationsIDs: [conversationID], dealID: "", prompt: prompt)
        return try await request(
            path: "/ask_attention/v2",
            method: "POST",
            queryItems: [
                URLQueryItem(name: "include_timestamps", value: "true"),
                URLQueryItem(name: "summarize", value: "false")
            ],
            body: body
        )
    }

    func listUsers() async throws -> [AttentionUser] {
        let response: ListUsersResponse = try await request(path: "/users")
        return response.data
    }

    /// Lists direct subfolders of a library folder (or root when folderUUID is nil).
    func listLibraryFolders(userUUID: String, folderUUID: String? = nil, myLibrary: Bool) async throws -> LibraryFolder {
        var items = [
            URLQueryItem(name: "userUUID", value: userUUID),
            URLQueryItem(name: "myLibrary", value: myLibrary ? "true" : "false")
        ]
        if let folderUUID {
            items.append(URLQueryItem(name: "folderUUID", value: folderUUID))
        }
        let response: LibraryFolderStructureResponse = try await request(path: "/library/folders", queryItems: items)
        return response.data
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = []
    ) async throws -> Response {
        try await request(path: path, method: method, queryItems: queryItems, body: Optional<EmptyBody>.none)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Response {
        guard let apiKey = keychain.readAPIKey()?.nilIfBlank else {
            throw AppError.missingAPIKey
        }

        let cleanedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: baseURL.absoluteString + "/" + cleanedPath) else {
            throw AppError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder.attention.encode(body)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.unexpectedResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(AttentionErrorResponse.self, from: data).detail) ??
                String(data: data, encoding: .utf8) ??
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw AppError.attentionError(status: httpResponse.statusCode, message: message)
        }

        do {
            return try JSONDecoder.attention.decode(Response.self, from: data)
        } catch {
            let preview = String(data: data.prefix(280), encoding: .utf8) ?? "non-utf8 body"
            throw AppError.attentionError(
                status: httpResponse.statusCode,
                message: "Could not parse Attention response: \(error.localizedDescription). Body starts with: \(preview)"
            )
        }
    }
}

struct ConversationRepository {
    let client: AttentionAPIClient

    func list(
        page: Int,
        size: Int = 25,
        search: String? = nil,
        participantEmails: [String] = [],
        ownerEmail: String? = nil,
        hideInternal: Bool = false,
        fromDate: Date? = nil,
        toDate: Date? = nil
    ) async throws -> ([Conversation], PageMeta?) {
        if client.isDemoMode {
            // Page 2+ returns empty so pagination terminates cleanly.
            guard page <= 1 else { return ([], PageMeta(pageCount: 1, totalRecords: nil, pageNumber: page, pageSize: size)) }
            return DemoLibrary.list(
                search: search,
                participantEmails: participantEmails,
                ownerEmail: ownerEmail,
                hideInternal: hideInternal
            )
        }
        let response = try await client.listConversations(
            page: page,
            size: size,
            search: search,
            participantEmails: participantEmails,
            ownerEmail: ownerEmail,
            hideInternal: hideInternal,
            fromDate: fromDate,
            toDate: toDate
        )
        return (response.data.map(Conversation.init(resource:)), response.meta)
    }

    func details(id: String) async throws -> Conversation {
        if client.isDemoMode {
            return try DemoLibrary.conversation(id: id)
        }
        return Conversation(resource: try await client.getConversation(id: id, includeTranscript: true))
    }

    func mediaURL(for conversationID: String) async throws -> URL {
        if client.isDemoMode {
            return try DemoLibrary.mediaURL(for: conversationID)
        }
        return try await client.generateMediaDownloadURL(conversationID: conversationID)
    }

    func ask(conversationID: String, prompt: String) async throws -> [AskAttentionItem] {
        if client.isDemoMode {
            // Small delay so the loading state reads naturally.
            try? await Task.sleep(for: .milliseconds(600))
            return DemoLibrary.ask(conversationID: conversationID, prompt: prompt)
        }
        return try await client.askAttention(conversationID: conversationID, prompt: prompt)
    }

    func users() async throws -> [AttentionUser] {
        if client.isDemoMode {
            return DemoLibrary.users
        }
        return try await client.listUsers()
    }
}

enum EmailSuggestionStore {
    static func upsert(email: String?, name: String?, source: String, in context: ModelContext) {
        guard let email = email?.lowercased().nilIfBlank, email.contains("@") else { return }
        let descriptor = FetchDescriptor<SuggestedEmail>(predicate: #Predicate { $0.email == email })
        if let existing = try? context.fetch(descriptor).first {
            if let name, existing.name?.nilIfBlank == nil {
                existing.name = name
            }
            existing.source = source
            existing.updatedAt = Date()
        } else {
            context.insert(SuggestedEmail(email: email, name: name, source: source))
        }
    }

    static func harvest(from conversations: [Conversation], in context: ModelContext) {
        for conversation in conversations {
            for participant in conversation.participants {
                upsert(email: participant.email, name: participant.name, source: "call", in: context)
            }
        }
        try? context.save()
    }

    static func harvest(from users: [AttentionUser], in context: ModelContext) {
        for user in users {
            upsert(email: user.email, name: user.displayName, source: "org", in: context)
        }
        try? context.save()
    }

    static func suggestions(matching query: String, from emails: [SuggestedEmail], limit: Int = 8) -> [SuggestedEmail] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 1 else { return [] }
        return emails
            .filter {
                $0.email.contains(needle) || ($0.name?.lowercased().contains(needle) ?? false)
            }
            .sorted { lhs, rhs in
                let lOrg = lhs.source == "org"
                let rOrg = rhs.source == "org"
                if lOrg != rOrg { return lOrg && !rOrg }
                return lhs.email < rhs.email
            }
            .prefix(limit)
            .map { $0 }
    }
}

struct EmptyBody: Encodable {}

struct AttentionErrorResponse: Decodable {
    let detail: String?
    let title: String?
    let code: String?
}

struct CreateSnippetRequest: Encodable {
    let userUUID: String
    let conversationID: String
    let reference: SnippetReference?
    let video: SnippetTimespan
    let notes: String?
    let title: String
    let inLibrary: Bool
    let libraryItemInfo: SnippetLibraryInfo?
    let internalSnippet: Bool
    let notifyViews: Bool

    enum CodingKeys: String, CodingKey {
        case userUUID = "user_uuid"
        case conversationID = "conversation_id"
        case reference
        case video
        case notes
        case title
        case inLibrary = "in_library"
        case libraryItemInfo = "library_item_info"
        case internalSnippet = "internal"
        case notifyViews = "notify_views"
    }
}

struct SnippetReference: Encodable, Hashable {
    let characters: SnippetIndexRange
    let speakers: SnippetIndexRange
    let transcriptVersion: String

    enum CodingKeys: String, CodingKey {
        case characters
        case speakers
        case transcriptVersion = "transcript_version"
    }
}

struct SnippetIndexRange: Encodable, Hashable {
    let startIdx: String
    let endIdx: String

    enum CodingKeys: String, CodingKey {
        case startIdx = "start_idx"
        case endIdx = "end_idx"
    }
}

struct SnippetTimespan: Encodable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let duration: TimeInterval

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
    }
}

struct LibraryFolderStructureResponse: Decodable {
    let data: LibraryFolder
}

struct LibraryFolder: Decodable {
    let uuid: String
    let name: String?
    let path: String?
    let subFolders: [LibrarySubFolder]?
}

struct LibrarySubFolder: Decodable, Identifiable, Hashable {
    let uuid: String
    let name: String
    let totalElements: Int?
    let totalFolders: Int?

    var id: String { uuid }
}

struct SnippetLibraryInfo: Encodable {
    let myLibrary: Bool
    // Omitted for the root folder, per the API spec.
    let folderPath: String?

    enum CodingKeys: String, CodingKey {
        case myLibrary = "my_library"
        case folderPath = "folder_path"
    }
}

struct SnippetDraft: Identifiable, Hashable {
    let id: UUID
    var conversationID: String
    var userUUID: String
    var callTitle: String
    var title: String
    var notes: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var previewText: String
    var requireLogin: Bool
    var notifyOnViews: Bool
    var addToLibrary: Bool
    /// true = personal library, false = org/team library.
    var myLibrary: Bool
    var libraryFolder: String
    var reference: SnippetReference?

    static func aroundCurrentMoment(
        conversation: Conversation,
        currentTime: TimeInterval,
        pad: TimeInterval = 30
    ) -> SnippetDraft? {
        guard let userUUID = conversation.userUUID?.nilIfBlank else { return nil }
        let start = max(0, currentTime - pad)
        let unboundedEnd = currentTime + pad
        let clippedEnd = max(
            start + 1,
            conversation.duration > 0 ? min(conversation.duration, unboundedEnd) : unboundedEnd
        )
        let overlapping = conversation.transcript.filter { $0.endTime >= start && $0.startTime <= clippedEnd }
        return SnippetDraft(
            id: UUID(),
            conversationID: conversation.id,
            userUUID: userUUID,
            callTitle: conversation.title,
            title: suggestedTitle(for: conversation, segments: overlapping),
            notes: "",
            startTime: start,
            endTime: clippedEnd,
            duration: conversation.duration,
            previewText: overlapping.map(\.text).joined(separator: " "),
            requireLogin: false,
            notifyOnViews: false,
            addToLibrary: false,
            myLibrary: true,
            libraryFolder: "",
            reference: transcriptReference(for: overlapping, in: conversation.transcript)
        )
    }

    static func fromSegments(
        conversation: Conversation,
        segments: [TranscriptSegment]
    ) -> SnippetDraft? {
        guard let userUUID = conversation.userUUID?.nilIfBlank, let first = segments.first, let last = segments.last else {
            return nil
        }
        return SnippetDraft(
            id: UUID(),
            conversationID: conversation.id,
            userUUID: userUUID,
            callTitle: conversation.title,
            title: suggestedTitle(for: conversation, segments: segments),
            notes: "",
            startTime: first.startTime,
            endTime: max(first.startTime + 1, last.endTime),
            duration: conversation.duration,
            previewText: segments.map(\.text).joined(separator: " "),
            requireLogin: false,
            notifyOnViews: false,
            addToLibrary: false,
            myLibrary: true,
            libraryFolder: "",
            reference: transcriptReference(for: segments, in: conversation.transcript)
        )
    }

    private static func suggestedTitle(for conversation: Conversation, segments: [TranscriptSegment]) -> String {
        if let speaker = segments.first?.speaker?.displayName {
            return "\(speaker) — \(conversation.title)"
        }
        return "\(conversation.title) clip"
    }

    private static func transcriptReference(
        for selected: [TranscriptSegment],
        in all: [TranscriptSegment]
    ) -> SnippetReference? {
        guard let first = selected.first, let last = selected.last,
              let startSpeaker = all.firstIndex(where: { $0.id == first.id }),
              let endSpeaker = all.firstIndex(where: { $0.id == last.id })
        else {
            return nil
        }

        var charStart = 0
        var cursor = 0
        for (index, segment) in all.enumerated() {
            let length = segment.text.count
            if index == startSpeaker {
                charStart = cursor
            }
            cursor += length + (index < all.count - 1 ? 1 : 0)
            if index == endSpeaker {
                return SnippetReference(
                    characters: SnippetIndexRange(startIdx: "\(charStart)", endIdx: "\(cursor)"),
                    speakers: SnippetIndexRange(startIdx: "\(startSpeaker)", endIdx: "\(endSpeaker)"),
                    transcriptVersion: "V2"
                )
            }
        }
        return nil
    }
}

struct AskAttentionRequest: Encodable {
    let conversationsIDs: [String]
    let dealID: String
    let prompt: String

    enum CodingKeys: String, CodingKey {
        case conversationsIDs = "conversations_ids"
        case dealID = "deal_id"
        case prompt
    }
}

struct AskAttentionItem: Decodable, Identifiable, Hashable {
    let output: String
    let conversationID: String
    // The API sends null here on success.
    let error: String?
    let segments: [AskAttentionSegment]?
    let title: String?

    var id: String {
        conversationID
    }

    enum CodingKeys: String, CodingKey {
        case output
        case conversationID = "conversation_id"
        case error
        case segments
        case title
    }
}

struct AskAttentionSegment: Decodable, Identifiable, Hashable {
    let startSec: TimeInterval?
    let endSec: TimeInterval?
    let text: String?

    var id: String {
        "\(startSec ?? 0)-\(endSec ?? 0)-\(text ?? "")"
    }

    enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec = "end_sec"
        case text
    }
}

extension JSONEncoder {
    static var attention: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

