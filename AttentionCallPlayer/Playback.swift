import AVFoundation
import Foundation
import MediaPlayer
import SwiftData
import UIKit

@MainActor
final class PlayerManager: ObservableObject {
    let repository: ConversationRepository
    var modelContext: ModelContext? {
        didSet { restoreQueueIfNeeded() }
    }

    @Published private(set) var player = AVPlayer()
    @Published private(set) var currentConversation: Conversation?
    @Published private(set) var currentTranscript: [TranscriptSegment] = []
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var queue: [Conversation] = []
    @Published var playbackRate: Float = UserDefaults.standard.object(forKey: "attention.playbackRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "attention.playbackRate")
            if isPlaying {
                player.rate = playbackRate
            }
            updateNowPlaying()
        }
    }
    @Published var skipInterval: Double = UserDefaults.standard.object(forKey: "attention.skipInterval") as? Double ?? 15 {
        didSet {
            UserDefaults.standard.set(skipInterval, forKey: "attention.skipInterval")
            let center = MPRemoteCommandCenter.shared()
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        }
    }
    /// Whether the next queued call starts automatically when the current one ends.
    @Published var autoplayQueueEnabled = UserDefaults.standard.object(forKey: "attention.autoplayQueue") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplayQueueEnabled, forKey: "attention.autoplayQueue")
        }
    }
    @Published var smartSpeedEnabled = UserDefaults.standard.bool(forKey: "attention.smartSpeed") {
        didSet {
            UserDefaults.standard.set(smartSpeedEnabled, forKey: "attention.smartSpeed")
            if smartSpeedEnabled {
                startSmartSpeedLoopIfNeeded()
            } else {
                smartSpeedTask?.cancel()
            }
        }
    }
    @Published var errorMessage: String?

    private var timeObserver: Any?
    private var smartSpeedTask: Task<Void, Never>?
    private var wasPlayingBeforeInterruption = false
    /// When set, playback auto-pauses at this time (used for snippet previews).
    @Published private(set) var previewStopTime: TimeInterval?
    /// All transcript words flattened and sorted once per track, so per-tick
    /// lookups can binary-search instead of scanning the whole call.
    private var flatWords: [TranscriptWord] = []
    private var lastBookmarkSave = Date.distantPast
    private var cachedArtwork: (conversationID: String, artwork: MPMediaItemArtwork)?

    init(repository: ConversationRepository) {
        self.repository = repository
        configureAudioSession()
        configureRemoteCommands()
        addTimeObserver()
        observeAudioSessionNotifications()
    }

    deinit {
        // Time observer cleanup is skipped here because PlayerManager is MainActor-isolated.
    }

    func play(_ conversation: Conversation, localURL: URL? = nil, queue: [Conversation] = [], autoplay: Bool = true) async {
        var detailed = conversation
        do {
            detailed = try await repository.details(id: conversation.id)
        } catch {
            // Offline (or API failure): a downloaded file can still play, just without a transcript.
            guard localURL != nil else {
                errorMessage = error.localizedDescription
                return
            }
        }

        currentConversation = detailed
        currentTranscript = detailed.transcript
        flatWords = detailed.transcript.flatMap(\.words)
        self.queue = queue.filter { $0.id != conversation.id }
        persistQueue()
        let resumeAt = bookmarkPosition(for: detailed.id)

        if let localURL {
            await startItem(url: localURL, resumeAt: resumeAt, conversationID: detailed.id, allowRetry: false, autoplay: autoplay)
            return
        }

        do {
            let url = try await playbackURL(for: detailed, localURL: nil)
            await startItem(url: url, resumeAt: resumeAt, conversationID: detailed.id, allowRetry: true, autoplay: autoplay)
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    private func startItem(url: URL, resumeAt: TimeInterval, conversationID: String, allowRetry: Bool, autoplay: Bool = true) async {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let loadedDuration = try? await item.asset.load(.duration), loadedDuration.isNumeric {
            duration = loadedDuration.seconds
        } else if let currentConversation {
            duration = currentConversation.duration
        }
        seek(to: resumeAt)
        if autoplay {
            activateAudioSession()
            player.playImmediately(atRate: playbackRate)
        }
        isPlaying = autoplay
        observeItemEnd(item)
        observeItemFailure(item, conversationID: conversationID, resumeAt: resumeAt, allowRetry: allowRetry)
        updateNowPlaying()
        startSmartSpeedLoopIfNeeded()
    }

    private func observeItemFailure(_ item: AVPlayerItem, conversationID: String, resumeAt: TimeInterval, allowRetry: Bool) {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard allowRetry, let self else { return }
                do {
                    let freshURL = try await self.repository.mediaURL(for: conversationID)
                    await self.startItem(url: freshURL, resumeAt: resumeAt, conversationID: conversationID, allowRetry: false)
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.isPlaying = false
                }
            }
        }
    }

    func playPause() {
        if isPlaying {
            pause()
        } else {
            activateAudioSession()
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            updateNowPlaying()
            startSmartSpeedLoopIfNeeded()
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        previewStopTime = nil
        saveBookmark()
        updateNowPlaying()
        smartSpeedTask?.cancel()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: TimeInterval) {
        let bounded = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = bounded
        previewStopTime = nil
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
        saveBookmark()
        updateNowPlaying()
    }

    /// Play just [start, end] and pause when the window finishes (snippet preview).
    func previewWindow(start: TimeInterval, end: TimeInterval) {
        guard end > start else { return }
        seek(to: start)
        previewStopTime = end
        if !isPlaying {
            activateAudioSession()
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            updateNowPlaying()
        }
    }

    func skipToNextSpeaker() {
        guard let next = currentTranscript.first(where: { $0.startTime > currentTime + 0.4 }) else {
            return
        }
        seek(to: next.startTime)
    }

    func skipToPreviousSpeaker() {
        let earlier = currentTranscript.last(where: { $0.startTime < currentTime - 1.0 })
        seek(to: earlier?.startTime ?? 0)
    }

    func playNext() {
        if let next = queue.first {
            let remaining = Array(queue.dropFirst())
            Task {
                await play(next, queue: remaining)
            }
            return
        }
        // Queue is empty: roll into the newest unplayed call (Apple Podcasts behavior).
        guard let next = nextUnplayedConversation() else {
            pause()
            return
        }
        Task {
            await play(next)
        }
    }

    private func nextUnplayedConversation() -> Conversation? {
        guard let modelContext else { return nil }
        let playedIDs = Set(((try? modelContext.fetch(FetchDescriptor<PlaybackBookmark>())) ?? []).map(\.conversationID))
        let currentID = currentConversation?.id
        return ((try? modelContext.fetch(FetchDescriptor<CachedConversation>())) ?? [])
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .map(Conversation.init(cache:))
            .first { $0.id != currentID && !playedIDs.contains($0.id) && $0.isPlayable }
    }

    private func observeAudioSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            Task { @MainActor in
                self?.handleInterruption(type: type, shouldResume: shouldResume)
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
            Task { @MainActor in
                self?.handleRouteChange(reason: reason)
            }
        }
    }

    /// Pause for phone calls/Siri/timers and resume afterward when iOS says it's appropriate.
    private func handleInterruption(type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                pause()
            }
        case .ended:
            if wasPlayingBeforeInterruption, shouldResume, !isPlaying {
                playPause()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// Headphones unplugged / AirPods removed: pause instead of blasting the loudspeaker.
    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    func enqueue(_ conversations: [Conversation]) {
        let currentID = currentConversation?.id
        let incoming = conversations.filter { $0.id != currentID }
        var seen = Set(queue.map(\.id))
        for conversation in incoming where !seen.contains(conversation.id) {
            queue.append(conversation)
            seen.insert(conversation.id)
        }
        persistQueue()
    }

    func removeFromQueue(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        persistQueue()
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        persistQueue()
    }

    func clearQueue() {
        queue.removeAll()
        persistQueue()
    }

    private let queueDefaultsKey = "attention.queueIDs"

    private func persistQueue() {
        UserDefaults.standard.set(queue.map(\.id), forKey: queueDefaultsKey)
    }

    /// Rebuild the queue from cached conversations after a relaunch.
    private func restoreQueueIfNeeded() {
        guard queue.isEmpty, let modelContext else { return }
        let ids = UserDefaults.standard.stringArray(forKey: queueDefaultsKey) ?? []
        guard !ids.isEmpty else { return }
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedConversation>())) ?? []
        let byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = ids.compactMap { byID[$0].map(Conversation.init(cache:)) }
    }

    func currentWord(at time: TimeInterval? = nil) -> TranscriptWord? {
        let current = time ?? currentTime
        guard let index = indexOfLastWord(startingAtOrBefore: current) else { return nil }
        let word = flatWords[index]
        return current <= word.endTimestamp ? word : nil
    }

    /// Binary search over the flattened, time-sorted word list.
    private func indexOfLastWord(startingAtOrBefore time: TimeInterval) -> Int? {
        var low = 0
        var high = flatWords.count
        while low < high {
            let mid = (low + high) / 2
            if flatWords[mid].startTimestamp <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? low - 1 : nil
    }

    func activeSegment(at time: TimeInterval? = nil) -> TranscriptSegment? {
        let current = time ?? currentTime
        return currentTranscript.first {
            $0.startTime <= current && current <= $0.endTime
        }
    }

    private func playbackURL(for conversation: Conversation, localURL: URL?) async throws -> URL {
        if let localURL {
            return localURL
        }
        return try await repository.mediaURL(for: conversation.id)
    }

    private func configureAudioSession() {
        do {
            // .allowAirPlay is only valid with .playAndRecord and returns OSStatus -50
            // on real devices; .playback routes to AirPlay automatically.
            // Deliberately NOT activated here: activating at launch would stop
            // whatever the user is listening to (e.g. Spotify) before they press play.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pause()
            }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: self.skipInterval)
            }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skip(by: -self.skipInterval)
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playNext()
            }
            return .success
        }
        // AirPods stem squeeze sends toggle, not discrete play/pause.
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.playPause()
            }
            return .success
        }
        // Triple-squeeze: restart the current call (standard previous-track semantics).
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.seek(to: 0)
            }
            return .success
        }
    }

    private func addTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds
                if let stopAt = self.previewStopTime, time.seconds >= stopAt {
                    self.pause()
                }
                // Bookmarks are a SwiftData fetch + disk write; every 5s is plenty
                // (pause/seek/track-change save immediately). Lock-screen info is
                // NOT updated here: iOS extrapolates elapsed time from the rate.
                if Date().timeIntervalSince(self.lastBookmarkSave) > 5 {
                    self.saveBookmark()
                }
            }
        }
    }

    private func observeItemEnd(_ item: AVPlayerItem) {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.autoplayQueueEnabled {
                    self.playNext()
                } else {
                    self.pause()
                }
            }
        }
    }

    private func bookmarkPosition(for conversationID: String) -> TimeInterval {
        guard let modelContext else {
            return 0
        }
        let descriptor = FetchDescriptor<PlaybackBookmark>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        return (try? modelContext.fetch(descriptor).first?.position) ?? 0
    }

    private func saveBookmark() {
        guard let currentConversation, currentTime.isFinite, currentTime > 2, let modelContext else {
            return
        }
        lastBookmarkSave = Date()
        let conversationID = currentConversation.id
        let title = currentConversation.title
        let descriptor = FetchDescriptor<PlaybackBookmark>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        if let bookmark = try? modelContext.fetch(descriptor).first {
            bookmark.position = currentTime
            bookmark.duration = duration
            bookmark.updatedAt = Date()
        } else {
            modelContext.insert(PlaybackBookmark(
                conversationID: conversationID,
                title: title,
                position: currentTime,
                duration: duration
            ))
        }
        try? modelContext.save()
    }

    private func updateNowPlaying() {
        guard let currentConversation else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentConversation.title,
            MPMediaItemPropertyArtist: currentConversation.subtitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPMediaItemPropertyPlaybackDuration: duration
        ]

        if cachedArtwork?.conversationID != currentConversation.id {
            let initials = currentConversation.artworkInitials
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 512, height: 512)) { _ in
                CallArtworkRenderer.brandImage() ?? CallArtworkRenderer.image(initials: initials)
            }
            cachedArtwork = (currentConversation.id, artwork)
        }
        info[MPMediaItemPropertyArtwork] = cachedArtwork?.artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startSmartSpeedLoopIfNeeded() {
        smartSpeedTask?.cancel()
        guard smartSpeedEnabled else {
            return
        }
        smartSpeedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await MainActor.run {
                    self?.skipSilenceIfNeeded()
                }
            }
        }
    }

    private func skipSilenceIfNeeded() {
        guard smartSpeedEnabled, isPlaying, !flatWords.isEmpty else {
            return
        }
        let nextIndex = (indexOfLastWord(startingAtOrBefore: currentTime).map { $0 + 1 }) ?? 0
        guard nextIndex < flatWords.count else { return }
        let nextWord = flatWords[nextIndex]
        let gap = nextWord.startTimestamp - currentTime
        if gap > 2.0 {
            seek(to: max(0, nextWord.startTimestamp - 0.25))
        }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    let repository: ConversationRepository
    var modelContext: ModelContext?

    @Published private(set) var progressByID: [String: Double] = [:]
    /// Titles of in-flight downloads so the Downloads tab can show them.
    @Published private(set) var downloadingTitles: [String: String] = [:]
    @Published var errorMessage: String?

    init(repository: ConversationRepository) {
        self.repository = repository
    }

    var downloadLimit: Int {
        max(1, UserDefaults.standard.object(forKey: "attention.downloadLimit") as? Int ?? 20)
    }

    func setDownloadLimit(_ limit: Int) {
        UserDefaults.standard.set(limit, forKey: "attention.downloadLimit")
        enforceLimit(maxCount: limit)
        objectWillChange.send()
    }

    func isDownloading(_ conversationID: String) -> Bool {
        progressByID[conversationID] != nil
    }

    func download(_ conversation: Conversation) async {
        do {
            progressByID[conversation.id] = 0.05
            downloadingTitles[conversation.id] = conversation.title
            let mediaURL = try await repository.mediaURL(for: conversation.id)
            let (temporaryURL, response) = try await URLSession.shared.download(from: mediaURL)
            let destination = try destinationURL(for: conversation)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? response.expectedContentLength
            saveDownload(conversation: conversation, url: destination, size: max(0, size))
            progressByID[conversation.id] = nil
            downloadingTitles[conversation.id] = nil
        } catch {
            progressByID[conversation.id] = nil
            downloadingTitles[conversation.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ download: DownloadedCall) {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: download.localPath))
        modelContext?.delete(download)
        try? modelContext?.save()
    }

    func localURL(for download: DownloadedCall) throws -> URL {
        let url = URL(fileURLWithPath: download.localPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppError.fileMissing
        }
        return url
    }

    func enforceLimit(maxCount: Int) {
        guard let modelContext else {
            return
        }
        var descriptor = FetchDescriptor<DownloadedCall>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = maxCount + 50
        guard let downloads = try? modelContext.fetch(descriptor), downloads.count > maxCount else {
            return
        }
        for download in downloads.dropFirst(maxCount) {
            delete(download)
        }
    }

    private func destinationURL(for conversation: Conversation) throws -> URL {
        let directory = try downloadsDirectory()
        let fileName = "\(conversation.id).mp4"
        return directory.appendingPathComponent(fileName)
    }

    private func downloadsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func saveDownload(conversation: Conversation, url: URL, size: Int64) {
        guard let modelContext else {
            return
        }
        let conversationID = conversation.id
        let title = conversation.title
        let duration = conversation.duration
        let descriptor = FetchDescriptor<DownloadedCall>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.localPath = url.path
            existing.fileSize = size
            existing.createdAt = Date()
        } else {
            modelContext.insert(DownloadedCall(
                conversationID: conversationID,
                title: title,
                localPath: url.path,
                duration: duration,
                fileSize: size
            ))
        }
        try? modelContext.save()
        enforceLimit(maxCount: downloadLimit)
    }
}

enum CallArtworkRenderer {
    static func brandImage() -> UIImage? {
        UIImage(named: "BrandLogo")
    }

    static func image(initials: String) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 150, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let string = NSAttributedString(string: initials, attributes: attributes)
            let rect = CGRect(x: 0, y: 170, width: size.width, height: 180)
            string.draw(in: rect)
        }
    }
}
