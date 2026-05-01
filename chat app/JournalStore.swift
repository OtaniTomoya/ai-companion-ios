//
//  JournalStore.swift
//  chat app
//

import Combine
import CoreLocation
import Foundation

@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    @Published private(set) var draft: JournalDraft = .empty()
    @Published private(set) var isJournaling = false
    @Published private(set) var locationSamples: [JournalLocationPoint] = []
    @Published private(set) var calendarContextLines: [String] = []

    private let fileManager: FileManager
    private let entriesURL: URL
    private let locationsURL: URL
    private let photosDirectoryURL: URL
    private var importedConversationMessageIDs = Set<UUID>()
    private var lastRecordedLocation: CLLocation?
    private let minimumLocationRecordInterval: TimeInterval = 10
    private let minimumLocationRecordDistance: CLLocationDistance = 5

    private let requiredSlots = JournalSlot.labels
    private let baseOptionalSlots = [
        "うまくいったこと",
        "疲れたこと・気になっていること",
        "もう少し深掘りしたい出来事"
    ]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Journals", isDirectory: true)
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Journals", isDirectory: true)

        entriesURL = baseDirectory.appendingPathComponent("journal_entries.json")
        locationsURL = baseDirectory.appendingPathComponent("journal_locations.json")
        photosDirectoryURL = baseDirectory.appendingPathComponent("Photos", isDirectory: true)

        ensureStorageDirectories()
        loadEntries()
        loadLocations()
    }

    var todayEntry: JournalEntry? {
        entry(forDayOffset: 0)
    }

    var yesterdayEntry: JournalEntry? {
        entry(forDayOffset: -1)
    }

    var todayLocationSamples: [JournalLocationPoint] {
        locationSamples.filter { Calendar.current.isDateInToday($0.recordedAt) }
    }

    @discardableResult
    func startSession(
        ignoring existingConversationMessages: [ConversationMessage] = [],
        calendarContextLines: [String] = []
    ) -> JournalPromptContext {
        draft = .empty()
        draft.locationItems = todayLocationSamples
        self.calendarContextLines = Array(calendarContextLines.prefix(10))
        isJournaling = true
        importedConversationMessageIDs = Set(existingConversationMessages.map(\.id))
        return promptContext()
    }

    func cancelSession() {
        isJournaling = false
        draft = .empty()
        calendarContextLines = []
        importedConversationMessageIDs.removeAll()
    }

    func addUserText(_ text: String, source: JournalMessageSource = .text) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendMessage(speaker: .user, text: trimmed, source: source)
    }

    func addConversationMessages(_ messages: [ConversationMessage]) -> [String] {
        guard isJournaling else { return [] }

        for message in messages where !importedConversationMessageIDs.contains(message.id) {
            guard message.speaker != .system else { continue }
            importedConversationMessageIDs.insert(message.id)

            let speaker: JournalSpeaker = message.speaker == .assistant ? .assistant : .user
            appendMessage(
                speaker: speaker,
                text: message.text,
                source: .conversation,
                createdAt: message.date
            )
        }

        return []
    }

    func promptContext() -> JournalPromptContext {
        JournalPromptContext(
            dateText: Self.dayFormatter.string(from: draft.date),
            requiredSlots: requiredSlots,
            optionalSlots: optionalSlots(),
            availableContext: availableContextLines(),
            progressSummary: progressSummary(),
            slotStatuses: slotStatusParams()
        )
    }

    @discardableResult
    func updateSlotStatuses(_ statuses: [String: JournalSlotStatus]) -> Bool {
        var didChange = false

        for (rawLabel, status) in statuses {
            guard let label = JournalSlot.canonicalLabel(for: rawLabel) else { continue }
            let currentStatus = draft.slotStatuses[label] ?? .missing

            // Filled slots stay filled unless we later add an explicit correction flow.
            let nextStatus: JournalSlotStatus = currentStatus == .filled ? .filled : status
            if currentStatus != nextStatus {
                draft.slotStatuses[label] = nextStatus
                didChange = true
            } else if draft.slotStatuses[label] == nil {
                draft.slotStatuses[label] = nextStatus
                didChange = true
            }
        }

        return didChange
    }

    @discardableResult
    func updateCalendarContextLines(_ lines: [String]) -> Bool {
        let normalized = Array(lines.prefix(10))
        guard normalized != calendarContextLines else { return false }
        calendarContextLines = normalized
        return true
    }

    func addPhoto(data: Data, fileExtension: String?) throws {
        let id = UUID()
        let normalizedExtension = normalizeFileExtension(fileExtension)
        let fileName = "\(id.uuidString).\(normalizedExtension)"
        let destinationURL = photosDirectoryURL.appendingPathComponent(fileName)

        try data.write(to: destinationURL, options: [.atomic])

        draft.photoItems.append(
            JournalPhotoItem(
                id: id,
                fileName: fileName,
                importedAt: Date(),
                capturedAt: nil,
                userMemo: ""
            )
        )

        appendMessage(
            speaker: .assistant,
            text: "写真を受け取ったよ。この写真のことも日記に入れておくね。",
            source: .photoPrompt
        )
    }

    func updatePhotoMemo(photoID: UUID, memo: String) {
        guard let index = draft.photoItems.firstIndex(where: { $0.id == photoID }) else { return }
        draft.photoItems[index].userMemo = memo
    }

    func photoURL(for photo: JournalPhotoItem) -> URL {
        photosDirectoryURL.appendingPathComponent(photo.fileName)
    }

    func recordLocation(_ location: CLLocation) {
        guard shouldRecord(location) else { return }

        let point = JournalLocationPoint(
            id: UUID(),
            recordedAt: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speed: location.speed >= 0 ? location.speed : nil
        )

        locationSamples.append(point)
        pruneOldLocationSamples()
        lastRecordedLocation = location

        if isJournaling {
            draft.locationItems = todayLocationSamples
        }

        saveLocations()
    }

    func finishSession() -> JournalEntry {
        draft.locationItems = todayLocationSamples
        let entry = makeEntry(from: draft)

        if let index = entries.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: entry.date) }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }

        entries.sort { $0.date > $1.date }
        saveEntries()

        isJournaling = false
        draft = .empty()
        calendarContextLines = []
        importedConversationMessageIDs.removeAll()

        return entry
    }

    func entry(forDayOffset offset: Int) -> JournalEntry? {
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return nil }
        return entries.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    private func appendMessage(
        speaker: JournalSpeaker,
        text: String,
        source: JournalMessageSource,
        createdAt: Date = Date()
    ) {
        draft.messages.append(
            JournalMessage(
                id: UUID(),
                createdAt: createdAt,
                speaker: speaker,
                text: text,
                source: source
            )
        )
    }

    private func optionalSlots() -> [String] {
        var slots = baseOptionalSlots
        if !draft.photoItems.isEmpty {
            slots.append("写真から思い出せる出来事")
        }
        if !draft.locationItems.isEmpty {
            slots.append("移動履歴から思い出せる場所・時間帯")
        }
        if !calendarContextLines.isEmpty {
            slots.append("予定表から思い出せる出来事・時間帯")
        }
        return slots
    }

    private func availableContextLines() -> [String] {
        var lines = ["会話での聞き取り"]
        if !draft.photoItems.isEmpty {
            lines.append("選択済み写真 \(draft.photoItems.count)枚")
        }
        if !draft.locationItems.isEmpty {
            lines.append("今日の位置サンプル \(draft.locationItems.count)件")
        }
        lines.append(contentsOf: calendarContextLines)
        return lines
    }

    private func progressSummary() -> String {
        let userMessages = draft.messages.filter { $0.speaker == .user }
        let slotSummary = slotStatusSummary()
        guard !userMessages.isEmpty else {
            return "まだ聞き取り開始前。項目状態: \(slotSummary)。まず今日全体の印象から聞く。"
        }

        let recentTexts = userMessages
            .suffix(3)
            .map(\.text)
            .joined(separator: " / ")
        return "ユーザー回答 \(userMessages.count)件。項目状態: \(slotSummary)。最近の回答: \(recentTexts)"
    }

    private func slotStatusParams() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: JournalSlot.labels.map { label in
                (label, (draft.slotStatuses[label] ?? .missing).rawValue)
            }
        )
    }

    private func slotStatusSummary() -> String {
        JournalSlot.labels
            .map { label in
                "\(label)=\((draft.slotStatuses[label] ?? .missing).rawValue)"
            }
            .joined(separator: ", ")
    }

    private func makeEntry(from draft: JournalDraft) -> JournalEntry {
        let userTexts = draft.messages
            .filter { $0.speaker == .user }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let photoMemos = draft.photoItems
            .map(\.userMemo)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let events = Array((userTexts + photoMemos).prefix(8))
        let feelings = extractFeelingNotes(from: userTexts)
        let carryOvers = extractCarryOvers(from: userTexts)
        let overview = makeOverview(from: userTexts, photoCount: draft.photoItems.count, locationCount: draft.locationItems.count)
        let title = "\(Self.dayFormatter.string(from: draft.date)) のジャーナル"
        let markdown = makeMarkdown(
            title: title,
            overview: overview,
            events: events,
            feelings: feelings,
            carryOvers: carryOvers,
            photos: draft.photoItems,
            locations: draft.locationItems
        )

        return JournalEntry(
            id: todayEntry?.id ?? draft.id,
            date: draft.date,
            createdAt: todayEntry?.createdAt ?? draft.startedAt,
            updatedAt: Date(),
            title: title,
            overview: overview,
            eventNotes: events,
            feelingNotes: feelings,
            carryOvers: carryOvers,
            messages: draft.messages,
            photos: draft.photoItems,
            locations: draft.locationItems,
            markdown: markdown
        )
    }

    private func makeOverview(from userTexts: [String], photoCount: Int, locationCount: Int) -> String {
        var parts = Array(userTexts.prefix(2))

        if photoCount > 0 {
            parts.append("写真\(photoCount)枚を一緒に振り返った。")
        }

        if locationCount > 0 {
            parts.append("移動ログ\(locationCount)件を日記の材料にした。")
        }

        if parts.isEmpty {
            return "今日はまだ短い記録だけの日記。"
        }

        return parts.joined(separator: " ")
    }

    private func extractFeelingNotes(from texts: [String]) -> [String] {
        let keywords = ["楽しかった", "嬉しかった", "よかった", "疲れた", "不安", "悔しい", "安心", "しんどい", "眠い"]
        let notes = texts.filter { text in
            keywords.contains { text.contains($0) }
        }

        return notes.isEmpty ? Array(texts.prefix(1)) : Array(notes.prefix(4))
    }

    private func extractCarryOvers(from texts: [String]) -> [String] {
        let keywords = ["明日", "あとで", "次", "やる", "持ち越し", "忘れない"]
        return Array(
            texts.filter { text in
                keywords.contains { text.contains($0) }
            }
            .prefix(4)
        )
    }

    private func makeMarkdown(
        title: String,
        overview: String,
        events: [String],
        feelings: [String],
        carryOvers: [String],
        photos: [JournalPhotoItem],
        locations: [JournalLocationPoint]
    ) -> String {
        var lines: [String] = [
            "# \(title)",
            "",
            "## 今日の要約",
            overview,
            "",
            "## 出来事"
        ]

        lines.append(contentsOf: bulletLines(events))
        lines.append("")
        lines.append("## 気持ち")
        lines.append(contentsOf: bulletLines(feelings))
        lines.append("")
        lines.append("## 写真メモ")
        lines.append(contentsOf: bulletLines(photoSummaryLines(photos)))
        lines.append("")
        lines.append("## 移動メモ")
        lines.append(contentsOf: bulletLines(locationSummaryLines(locations)))
        lines.append("")
        lines.append("## 明日に持ち越すこと")
        lines.append(contentsOf: bulletLines(carryOvers))

        return lines.joined(separator: "\n")
    }

    private func bulletLines(_ values: [String]) -> [String] {
        if values.isEmpty {
            return ["- なし"]
        }
        return values.map { "- \($0)" }
    }

    private func photoSummaryLines(_ photos: [JournalPhotoItem]) -> [String] {
        photos.map { photo in
            let memo = photo.userMemo.trimmingCharacters(in: .whitespacesAndNewlines)
            return memo.isEmpty ? "写真 \(photo.fileName)" : memo
        }
    }

    private func locationSummaryLines(_ locations: [JournalLocationPoint]) -> [String] {
        let candidates = sampledLocationsForSummary(locations)
        return candidates.map { location in
            "\(Self.timeFormatter.string(from: location.recordedAt)) \(location.coordinateText)"
        }
    }

    private func sampledLocationsForSummary(_ locations: [JournalLocationPoint]) -> [JournalLocationPoint] {
        guard locations.count > 8 else { return locations }

        let stride = max(locations.count / 8, 1)
        return locations.enumerated()
            .filter { index, _ in index % stride == 0 }
            .map(\.element)
            .prefix(8)
            .map { $0 }
    }

    private func normalizeFileExtension(_ fileExtension: String?) -> String {
        let ext = fileExtension?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard let ext, !ext.isEmpty else { return "jpg" }
        return ext == "jpeg" ? "jpg" : ext
    }

    private func shouldRecord(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else { return false }

        guard let lastRecordedLocation else { return true }

        guard location.timestamp > lastRecordedLocation.timestamp else { return false }

        let timeInterval = location.timestamp.timeIntervalSince(lastRecordedLocation.timestamp)
        let distance = location.distance(from: lastRecordedLocation)
        return timeInterval >= minimumLocationRecordInterval || distance >= minimumLocationRecordDistance
    }

    private func pruneOldLocationSamples() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else { return }
        locationSamples.removeAll { $0.recordedAt < cutoff }
    }

    private func ensureStorageDirectories() {
        do {
            try fileManager.createDirectory(at: entriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: photosDirectoryURL, withIntermediateDirectories: true)
        } catch {
            assertionFailure("Failed to create journal storage directories: \(error.localizedDescription)")
        }
    }

    private func loadEntries() {
        do {
            let data = try Data(contentsOf: entriesURL)
            entries = try JSONDecoder().decode([JournalEntry].self, from: data)
                .sorted { $0.date > $1.date }
        } catch {
            entries = []
        }
    }

    private func saveEntries() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: entriesURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save journal entries: \(error.localizedDescription)")
        }
    }

    private func loadLocations() {
        do {
            let data = try Data(contentsOf: locationsURL)
            locationSamples = try JSONDecoder().decode([JournalLocationPoint].self, from: data)
            pruneOldLocationSamples()
        } catch {
            locationSamples = []
        }
    }

    private func saveLocations() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(locationSamples)
            try data.write(to: locationsURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save journal locations: \(error.localizedDescription)")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
