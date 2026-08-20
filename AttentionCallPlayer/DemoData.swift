import Foundation

/// Self-contained sample library used when the API key is the demo key.
/// Exists so App Review can exercise the whole app without an Attention
/// account or access to real customer calls. Audio files are bundled and the
/// transcripts below carry the exact segment timings of that audio.
enum DemoLibrary {
    static let demoKey = "DEMO"

    static func isDemoKey(_ key: String?) -> Bool {
        key?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == demoKey
    }

    // MARK: People

    private static let sarah = Participant(id: "demo-user-sarah", email: "sarah.chen@demo.attention.tech", name: "Sarah Chen", organizer: true, status: nil, type: "internal")
    private static let michael = Participant(id: "demo-michael", email: "michael.torres@acmecorp.com", name: "Michael Torres", organizer: false, status: nil, type: "external")
    private static let priya = Participant(id: "demo-user-priya", email: "priya.patel@demo.attention.tech", name: "Priya Patel", organizer: true, status: nil, type: "internal")
    private static let dev = Participant(id: "demo-dev", email: "dev.kapoor@northwind.io", name: "Dev Kapoor", organizer: false, status: nil, type: "external")
    private static let james = Participant(id: "demo-user-james", email: "james.walker@demo.attention.tech", name: "James Walker", organizer: true, status: nil, type: "internal")
    private static let dana = Participant(id: "demo-dana", email: "dana.kim@globex.com", name: "Dana Kim", organizer: false, status: nil, type: "external")

    static let users: [AttentionUser] = [
        AttentionUser(uuid: "demo-user-sarah", firstName: "Sarah", lastName: "Chen", email: "sarah.chen@demo.attention.tech"),
        AttentionUser(uuid: "demo-user-priya", firstName: "Priya", lastName: "Patel", email: "priya.patel@demo.attention.tech"),
        AttentionUser(uuid: "demo-user-james", firstName: "James", lastName: "Walker", email: "james.walker@demo.attention.tech")
    ]

    // MARK: Calls

    static let conversations: [Conversation] = [
        Conversation(
            demoID: "demo-1",
            userUUID: "demo-user-sarah",
            title: "Acme Corp — Discovery Call",
            createdAt: Date().addingTimeInterval(-5 * 3600),
            duration: 74.9,
            ownerName: "Sarah Chen",
            participants: [sarah, michael],
            transcript: segments([
                (sarah, 0.00, 8.99, "Hi Michael, thanks for making time today. Before we dive in, I'd love to hear how the rollout of your new support platform is going."),
                (michael, 9.44, 19.44, "Happy to be here, Sarah. Honestly, the rollout has been smoother than expected, but our team is drowning in follow up work after every customer call."),
                (sarah, 19.89, 27.74, "That's exactly what we hear from a lot of support leaders. Roughly how many calls does your team handle in a typical week?"),
                (michael, 28.19, 36.42, "Somewhere around four hundred. Every call needs notes, a summary, and updates in the CRM, and that eats hours."),
                (sarah, 36.87, 47.42, "Got it. So if we could automate the notes and the CRM updates, your team would get most of that time back. What would success look like for you by the end of the quarter?"),
                (michael, 47.87, 58.56, "If my agents spend thirty percent less time on admin work, that's a clear win. I'd also love better visibility into what customers are actually asking for."),
                (sarah, 59.01, 67.94, "That's very doable. Let me walk you through how the platform captures every conversation and turns it into structured data automatically."),
                (michael, 68.39, 74.40, "Sounds great. If the demo goes well, I can pull in our head of operations next week.")
            ])
        ),
        Conversation(
            demoID: "demo-2",
            userUUID: "demo-user-priya",
            title: "Northwind Renewal — Pricing Discussion",
            createdAt: Date().addingTimeInterval(-2 * 86400),
            duration: 56.7,
            ownerName: "Priya Patel",
            participants: [priya, dev],
            transcript: segments([
                (priya, 0.00, 8.94, "Hi Dev, good to reconnect. I know the renewal is coming up in about six weeks, so I wanted to walk through the proposal together."),
                (dev, 9.39, 17.01, "Thanks Priya. Overall the team is happy, but finance asked me to take a hard look at the per seat cost this year."),
                (priya, 17.46, 26.62, "Completely fair. You're currently on forty five seats, and usage data shows about ninety percent weekly active, which is excellent."),
                (dev, 27.07, 34.68, "Right, adoption isn't the issue. It's really about budget. Is there flexibility if we commit to two years?"),
                (priya, 35.13, 43.35, "There is. On a two year term I can bring the per seat price down about twelve percent, and we'd lock that rate for the full term."),
                (dev, 43.80, 50.35, "That could work. Can you send over the revised numbers so I can review them with finance on Thursday?"),
                (priya, 50.80, 56.25, "Absolutely, you'll have them by end of day tomorrow, along with a summary of this call.")
            ])
        ),
        Conversation(
            demoID: "demo-3",
            userUUID: "demo-user-james",
            title: "Globex Onboarding Kickoff",
            createdAt: Date().addingTimeInterval(-5 * 86400),
            duration: 53.7,
            ownerName: "James Walker",
            participants: [james, dana],
            transcript: segments([
                (james, 0.00, 8.00, "Welcome aboard, Dana. Today I want to agree on the rollout plan and make sure your team gets value in the first two weeks."),
                (dana, 8.45, 15.68, "Thanks James. Our main goal is getting the sales team recording and reviewing calls before the end of the month."),
                (james, 16.13, 25.42, "Perfect. Step one is connecting your calendar and dialer, which takes about fifteen minutes. Step two is a training session for the team."),
                (dana, 25.87, 31.75, "Can we schedule the training for next Tuesday? Most of the team is in the office that day."),
                (james, 32.20, 40.77, "Tuesday works. I'll also set up weekly digests so managers see highlights from every customer conversation automatically."),
                (dana, 41.22, 45.82, "That would be a huge help. What do you need from us before Tuesday?"),
                (james, 46.27, 53.25, "Just admin access to your workspace and a list of team emails. I'll send a checklist right after this call.")
            ])
        )
    ]

    // MARK: Lookups

    static func conversation(id: String) throws -> Conversation {
        guard let match = conversations.first(where: { $0.id == id }) else {
            throw AppError.unexpectedResponse
        }
        return match
    }

    static func mediaURL(for conversationID: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: "DemoCall-\(conversationID)", withExtension: "m4a") else {
            throw AppError.fileMissing
        }
        return url
    }

    static func list(
        search: String?,
        participantEmails: [String],
        ownerEmail: String?,
        hideInternal: Bool
    ) -> ([Conversation], PageMeta?) {
        var results = conversations
        if let search = search?.nilIfBlank {
            results = results.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        let emails = (participantEmails + [ownerEmail].compactMap { $0 }).compactMap(\.nilIfBlank).map { $0.lowercased() }
        if !emails.isEmpty {
            results = results.filter { conversation in
                emails.allSatisfy { email in
                    conversation.participants.contains { $0.email?.lowercased() == email }
                }
            }
        }
        let meta = PageMeta(pageCount: 1, totalRecords: results.count, pageNumber: 1, pageSize: max(results.count, 1))
        return (results, meta)
    }

    static func ask(conversationID: String, prompt: String) -> [AskAttentionItem] {
        let conversation = (try? conversation(id: conversationID)) ?? conversations[0]
        let sources = conversation.transcript.prefix(2).map { segment in
            AskAttentionSegment(startSec: segment.startTime, endSec: segment.endTime, text: segment.text)
        }
        let output = """
        This is a sample answer generated in demo mode. In a live workspace, Ask \
        Attention analyzes the full call and answers questions like “\(prompt)” with \
        citations into the transcript. Tap a source below to jump to that moment in the call.
        """
        return [
            AskAttentionItem(
                output: output,
                conversationID: conversation.id,
                error: nil,
                segments: Array(sources),
                title: conversation.title
            )
        ]
    }

    static func createdSnippet() -> CreatedSnippetResponse {
        CreatedSnippetResponse(
            id: "demo-snippet-\(UUID().uuidString.prefix(8))",
            url: URL(string: "https://app.attention.tech/snippet/demo-preview")!,
            shareCode: nil
        )
    }

    // MARK: Builders

    /// Words get plausible timings by splitting each spoken segment's real
    /// audio window proportionally to word length.
    private static func segments(_ lines: [(Participant, TimeInterval, TimeInterval, String)]) -> [TranscriptSegment] {
        lines.map { speaker, start, end, text in
            TranscriptSegment(speaker: speaker, words: words(text: text, start: start, end: end))
        }
    }

    private static func words(text: String, start: TimeInterval, end: TimeInterval) -> [TranscriptWord] {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let totalWeight = tokens.reduce(0.0) { $0 + Double($1.count + 1) }
        let span = max(0.1, end - start)
        var cursor = start
        return tokens.enumerated().map { index, token in
            let weight = Double(token.count + 1) / totalWeight
            let wordEnd = index == tokens.count - 1 ? end : min(end, cursor + span * weight)
            defer { cursor = wordEnd }
            return TranscriptWord(endTimestamp: wordEnd, startTimestamp: cursor, text: token + " ")
        }
    }
}

extension Conversation {
    /// Full-fidelity demo call (transcript, participants, playable media).
    init(
        demoID: String,
        userUUID: String,
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        ownerName: String,
        participants: [Participant],
        transcript: [TranscriptSegment]
    ) {
        self.id = demoID
        self.userUUID = userUUID
        self.title = title
        self.createdAt = createdAt
        self.finishedAt = createdAt.addingTimeInterval(duration)
        self.duration = duration
        self.ownerName = ownerName
        self.participants = participants
        self.transcript = transcript
        self.videoStatus = "READY"
        self.mediaStorageStatus = "READY"
        self.transcriptStatus = "READY"
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
