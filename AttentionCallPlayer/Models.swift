import Foundation
import SwiftData

struct ConversationsResponse: Decodable {
    let data: [ConversationResource]
    let meta: PageMeta?
}

struct PageMeta: Decodable {
    let pageCount: Int?
    let totalRecords: Int?
    let pageNumber: Int?
    let pageSize: Int?
}

struct ConversationResource: Decodable {
    let id: String
    let attributes: ConversationAttributes
}

struct ConversationAttributes: Decodable {
    let uuid: String?
    let title: String?
    let createdAt: Date?
    let finishedAt: Date?
    let mediaDuration: Double?
    let userUUID: String?
    let teamUUID: String?
    let user: AttentionUser?
    let participants: [Participant]?
    let attendees: [Participant]?
    /// List endpoints often return a plain string; detail with `detailedTranscript=true` returns segments.
    let transcript: FlexibleTranscript?
    let videoStatus: String?
    let mediaStorageStatus: String?
    let transcriptStatus: String?
    let archived: Bool?
    let `private`: Bool?
    let isInternal: Bool?
    let labels: [String: StringValue]?
    let extractedIntelligence: [String: ExtractedIntelligenceItem]?
    let confirmedExtractedIntelligence: [String: ExtractedIntelligenceItem]?
    let externalOpportunity: ExternalOpportunity?
    let linkedCrmRecords: [LinkedCRMRecord]?
    let externalAccounts: [LinkedCRMRecord]?
    let externalContacts: [LinkedCRMRecord]?
    let scorecardResults: [ScorecardResult]?
}

enum FlexibleTranscript: Decodable, Hashable {
    case segments([TranscriptSegment])
    case plainText(String)
    case empty

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .empty
        } else if let segments = try? container.decode([TranscriptSegment].self) {
            self = .segments(segments)
        } else if let text = try? container.decode(String.self) {
            self = text.nilIfBlank == nil ? .empty : .plainText(text)
        } else {
            self = .empty
        }
    }

    var segments: [TranscriptSegment] {
        switch self {
        case .segments(let value):
            return value
        case .plainText, .empty:
            return []
        }
    }
}

struct Conversation: Identifiable, Hashable {
    let id: String
    let userUUID: String?
    let title: String
    let createdAt: Date?
    let finishedAt: Date?
    let duration: TimeInterval
    let ownerName: String?
    let participants: [Participant]
    let transcript: [TranscriptSegment]
    let videoStatus: String?
    let mediaStorageStatus: String?
    let transcriptStatus: String?
    let isArchived: Bool
    let isPrivate: Bool
    let isInternal: Bool
    let labels: [String: StringValue]
    let extractedIntelligence: [String: ExtractedIntelligenceItem]
    let confirmedExtractedIntelligence: [String: ExtractedIntelligenceItem]
    let externalOpportunity: ExternalOpportunity?
    let linkedCRMRecords: [LinkedCRMRecord]
    let externalAccounts: [LinkedCRMRecord]
    let externalContacts: [LinkedCRMRecord]
    let scorecardResults: [ScorecardResult]

    init(resource: ConversationResource) {
        let attributes = resource.attributes
        id = attributes.uuid ?? resource.id
        userUUID = attributes.userUUID
        title = attributes.title?.nilIfBlank ?? "Untitled call"
        createdAt = attributes.createdAt
        finishedAt = attributes.finishedAt
        duration = attributes.mediaDuration ?? 0
        ownerName = attributes.user?.displayName
        participants = attributes.participants ?? attributes.attendees ?? []
        transcript = attributes.transcript?.segments ?? []
        videoStatus = attributes.videoStatus
        mediaStorageStatus = attributes.mediaStorageStatus
        transcriptStatus = attributes.transcriptStatus
        isArchived = attributes.archived ?? false
        isPrivate = attributes.private ?? false
        isInternal = attributes.isInternal ?? false
        labels = attributes.labels ?? [:]
        extractedIntelligence = attributes.extractedIntelligence ?? [:]
        confirmedExtractedIntelligence = attributes.confirmedExtractedIntelligence ?? [:]
        externalOpportunity = attributes.externalOpportunity
        linkedCRMRecords = attributes.linkedCrmRecords ?? []
        externalAccounts = attributes.externalAccounts ?? []
        externalContacts = attributes.externalContacts ?? []
        scorecardResults = attributes.scorecardResults ?? []
    }

    var subtitle: String {
        // Prefer real names; fall back to the mailbox part of an email so rows stay short.
        let names = participants.compactMap { participant -> String? in
            guard let display = participant.displayName?.nilIfBlank else { return nil }
            if display.contains("@") {
                return String(display.split(separator: "@").first ?? "").nilIfBlank
            }
            return display
        }
        guard !names.isEmpty else { return ownerName ?? "Attention recording" }
        let shown = names.prefix(3).joined(separator: ", ")
        let extra = names.count - min(3, names.count)
        return extra > 0 ? "\(shown) +\(extra)" : shown
    }

    var isPlayable: Bool {
        mediaStorageStatus?.caseInsensitiveCompare("READY") == .orderedSame ||
            videoStatus?.caseInsensitiveCompare("READY") == .orderedSame
    }

    var artworkInitials: String {
        let source = participants.first?.displayName ?? title
        let parts = source.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? "A" : initials.uppercased()
    }
}

extension Conversation {
    /// Link to this call in the Attention web dashboard.
    var webURL: URL? {
        URL(string: "https://app.attention.tech/conversations/all-calls/\(id)")
    }

    init(cache: CachedConversation) {
        id = cache.id
        userUUID = nil
        title = cache.title
        createdAt = cache.createdAt
        finishedAt = cache.finishedAt
        duration = cache.duration
        ownerName = cache.ownerName
        participants = (try? JSONDecoder.attention.decode([Participant].self, from: Data(cache.participantsJSON.utf8))) ?? []
        transcript = []
        videoStatus = cache.videoStatus
        mediaStorageStatus = cache.mediaStorageStatus
        transcriptStatus = cache.transcriptStatus
        isArchived = cache.isArchived
        isPrivate = cache.isPrivate
        isInternal = cache.isInternal
        labels = [:]
        extractedIntelligence = [:]
        confirmedExtractedIntelligence = [:]
        externalOpportunity = nil
        linkedCRMRecords = []
        externalAccounts = []
        externalContacts = []
        scorecardResults = []
    }
}

struct AttentionUser: Decodable, Hashable {
    let uuid: String?
    let firstName: String?
    let lastName: String?
    let email: String?

    var displayName: String? {
        [firstName, lastName].compactMap { $0?.nilIfBlank }.joined(separator: " ").nilIfBlank ?? email
    }
}

struct ListUsersResponse: Decodable {
    let data: [AttentionUser]
}

struct Participant: Codable, Hashable, Identifiable {
    let id: String?
    let email: String?
    let name: String?
    let organizer: Bool?
    let status: String?
    let type: String?

    var displayName: String? {
        name?.nilIfBlank ?? email?.nilIfBlank
    }

    var stableID: String {
        id ?? email ?? name ?? UUID().uuidString
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    let speaker: Participant?
    let words: [TranscriptWord]

    var id: String {
        "\(speaker?.stableID ?? "unknown")-\(startTime)"
    }

    var text: String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var startTime: TimeInterval {
        words.first?.startTimestamp ?? 0
    }

    var endTime: TimeInterval {
        words.last?.endTimestamp ?? startTime
    }
}

struct TranscriptWord: Codable, Hashable, Identifiable {
    let endTimestamp: TimeInterval
    let startTimestamp: TimeInterval
    let text: String

    var id: String {
        "\(startTimestamp)-\(endTimestamp)-\(text)"
    }
}

struct MediaDownloadResponse: Decodable {
    let url: URL
}

struct CreatedSnippetResponse: Decodable {
    let id: String
    let url: URL
    let shareCode: String?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case shareCode = "share_code"
    }
}

struct AskAttentionResponse: Decodable {
    let answer: String?
    let content: String?
    let text: String?

    var displayText: String {
        answer ?? content ?? text ?? "No answer returned."
    }
}

struct ScorecardResult: Decodable, Hashable, Identifiable {
    let uuid: String?
    let title: String?
    let summary: ScorecardSummary?
    let items: [ScorecardItem]?

    var id: String {
        uuid ?? title ?? UUID().uuidString
    }
}

struct ScorecardSummary: Decodable, Hashable {
    let averageScore: Double?
    let min: Int?
    let max: Int?
    let summaryText: String?
}

struct ScorecardItem: Decodable, Hashable, Identifiable {
    let uuid: String?
    let title: String?
    let description: String?
    let evidences: [String]?
    let numericResult: NumericScorecardResult?

    var id: String {
        uuid ?? title ?? UUID().uuidString
    }
}

struct NumericScorecardResult: Decodable, Hashable {
    let score: Int?
    let min: Int?
    let max: Int?
}

struct ExtractedIntelligenceItem: Decodable, Hashable, Identifiable {
    let id: String?
    let key: String?
    let value: String?
    let title: String?
    let category: String?
    let source: String?
    let scopeInsight: String?

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case title
        case category
        case source
        case scopeInsight = "scope_insight"
    }
}

struct ExternalOpportunity: Decodable, Hashable {
    let uuid: String?
    let title: String?
}

struct LinkedCRMRecord: Decodable, Hashable, Identifiable {
    let id: String
    let code: String
}

enum StringValue: Decodable, Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([StringValue])
    case object([String: StringValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([StringValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: StringValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted()
        case .bool(let value):
            return value ? "Yes" : "No"
        case .array(let values):
            return values.map(\.description).joined(separator: ", ")
        case .object(let values):
            return values.map { "\($0.key): \($0.value.description)" }.sorted().joined(separator: ", ")
        case .null:
            return ""
        }
    }
}

@Model
final class CachedConversation {
    @Attribute(.unique) var id: String
    var title: String
    var createdAt: Date?
    var finishedAt: Date?
    var duration: TimeInterval
    var ownerName: String?
    var participantsJSON: String
    var videoStatus: String?
    var mediaStorageStatus: String?
    var transcriptStatus: String?
    var isArchived: Bool
    var isPrivate: Bool
    var isInternal: Bool
    var updatedAt: Date

    init(conversation: Conversation) {
        id = conversation.id
        title = conversation.title
        createdAt = conversation.createdAt
        finishedAt = conversation.finishedAt
        duration = conversation.duration
        ownerName = conversation.ownerName
        participantsJSON = (try? String(data: JSONEncoder().encode(conversation.participants), encoding: .utf8)) ?? "[]"
        videoStatus = conversation.videoStatus
        mediaStorageStatus = conversation.mediaStorageStatus
        transcriptStatus = conversation.transcriptStatus
        isArchived = conversation.isArchived
        isPrivate = conversation.isPrivate
        isInternal = conversation.isInternal
        updatedAt = Date()
    }

    func update(from conversation: Conversation) {
        title = conversation.title
        createdAt = conversation.createdAt
        finishedAt = conversation.finishedAt
        duration = conversation.duration
        ownerName = conversation.ownerName
        participantsJSON = (try? String(data: JSONEncoder().encode(conversation.participants), encoding: .utf8)) ?? "[]"
        videoStatus = conversation.videoStatus
        mediaStorageStatus = conversation.mediaStorageStatus
        transcriptStatus = conversation.transcriptStatus
        isArchived = conversation.isArchived
        isPrivate = conversation.isPrivate
        isInternal = conversation.isInternal
        updatedAt = Date()
    }
}

@Model
final class PlaybackBookmark {
    @Attribute(.unique) var conversationID: String
    var title: String
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    /// Played to the end at least once. Distinct from position, which resets
    /// to 0 on completion so replays start over.
    var completed: Bool = false

    init(conversationID: String, title: String, position: TimeInterval, duration: TimeInterval, completed: Bool = false) {
        self.conversationID = conversationID
        self.title = title
        self.position = position
        self.duration = duration
        self.completed = completed
        self.updatedAt = Date()
    }
}

/// Local record of a snippet created in this app. The Attention API can create
/// snippets but has no endpoint to list them back, so this is the app's memory.
@Model
final class SavedSnippet {
    @Attribute(.unique) var snippetID: String
    var title: String
    var callTitle: String
    var conversationID: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var urlString: String
    var createdAt: Date
    /// Notes are write-once on the API side (create only), so this mirrors
    /// what was sent at creation.
    var notes: String = ""
    /// Library placement chosen at creation (client-side record — the API
    /// can't list folder contents back).
    var inLibrary: Bool = false
    var inMyLibrary: Bool = true
    /// Legacy server folder path; unused now that folders are local-only.
    var libraryFolder: String = ""
    /// Device-local folder name; empty string means unfiled.
    var localFolder: String = ""

    init(
        snippetID: String,
        title: String,
        callTitle: String,
        conversationID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        urlString: String,
        notes: String = "",
        inLibrary: Bool = false,
        inMyLibrary: Bool = true,
        localFolder: String = ""
    ) {
        self.snippetID = snippetID
        self.title = title
        self.callTitle = callTitle
        self.conversationID = conversationID
        self.startTime = startTime
        self.endTime = endTime
        self.urlString = urlString
        self.notes = notes
        self.inLibrary = inLibrary
        self.inMyLibrary = inMyLibrary
        self.localFolder = localFolder
        self.createdAt = Date()
    }

    var url: URL? {
        URL(string: urlString)
    }
}

/// Device-local playlist — the Attention API has no playlist concept.
/// Calls are referenced by ID and resolved against the conversation cache.
@Model
final class Playlist {
    @Attribute(.unique) var uuid: String
    var name: String
    var createdAt: Date
    /// Ordered call IDs; titles stored alongside so entries survive cache eviction.
    var conversationIDs: [String] = []
    var titlesByID: [String: String] = [:]

    init(name: String) {
        self.uuid = UUID().uuidString
        self.name = name
        self.createdAt = Date()
    }

    func contains(_ conversationID: String) -> Bool {
        conversationIDs.contains(conversationID)
    }

    func toggle(_ conversation: Conversation) {
        if let index = conversationIDs.firstIndex(of: conversation.id) {
            conversationIDs.remove(at: index)
            titlesByID[conversation.id] = nil
        } else {
            conversationIDs.append(conversation.id)
            titlesByID[conversation.id] = conversation.title
        }
    }
}

/// Device-local snippet folder — plain organization, nothing on Attention's side.
@Model
final class SnippetFolder {
    @Attribute(.unique) var name: String
    var createdAt: Date

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

/// A teammate you follow, Spotify-artist style. Device-local; their calls are
/// fetched live by filtering conversations on owner email.
@Model
final class FollowedArtist {
    @Attribute(.unique) var email: String
    var name: String
    var createdAt: Date

    init(email: String, name: String) {
        self.email = email
        self.name = name
        self.createdAt = Date()
    }
}

/// Device-local favorites — the Attention API has no favorites concept.
@Model
final class FavoriteCall {
    @Attribute(.unique) var conversationID: String
    var title: String
    var createdAt: Date

    init(conversationID: String, title: String) {
        self.conversationID = conversationID
        self.title = title
        self.createdAt = Date()
    }
}

@Model
final class DownloadedCall {
    @Attribute(.unique) var conversationID: String
    var title: String
    var localPath: String
    var duration: TimeInterval
    var createdAt: Date
    var fileSize: Int64

    init(conversationID: String, title: String, localPath: String, duration: TimeInterval, fileSize: Int64 = 0) {
        self.conversationID = conversationID
        self.title = title
        self.localPath = localPath
        self.duration = duration
        self.fileSize = fileSize
        self.createdAt = Date()
    }
}

@Model
final class RecentSearch {
    @Attribute(.unique) var query: String
    var updatedAt: Date

    init(query: String) {
        self.query = query
        self.updatedAt = Date()
    }
}

@Model
final class SuggestedEmail {
    @Attribute(.unique) var email: String
    var name: String?
    var source: String
    var updatedAt: Date

    init(email: String, name: String? = nil, source: String) {
        self.email = email.lowercased()
        self.name = name
        self.source = source
        self.updatedAt = Date()
    }
}

extension JSONDecoder {
    static var attention: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractions
        return decoder
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractions = custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = ISO8601DateFormatter.withFractions.date(from: string) {
            return date
        }
        if let date = ISO8601DateFormatter.withoutFractions.date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let withoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension TimeInterval {
    var shortDuration: String {
        guard isFinite else { return "0:00" }
        let seconds = Int(self)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remaining))"
        }
        return "\(minutes):\(String(format: "%02d", remaining))"
    }
}
