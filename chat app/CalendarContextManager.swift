//
//  CalendarContextManager.swift
//  chat app
//

import Combine
import EventKit
import Foundation
import UIKit

enum CalendarContextAuthorizationState: Equatable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case legacyAuthorized
    case unknown

    var canReadEvents: Bool {
        switch self {
        case .fullAccess, .legacyAuthorized:
            true
        case .notDetermined, .restricted, .denied, .writeOnly, .unknown:
            false
        }
    }

    var label: String {
        switch self {
        case .notDetermined:
            "未選択"
        case .restricted:
            "制限あり"
        case .denied:
            "拒否"
        case .writeOnly:
            "追加のみ許可"
        case .fullAccess, .legacyAuthorized:
            "読み取り許可済み"
        case .unknown:
            "不明"
        }
    }
}

struct CalendarContextEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String

    var contextLine: String {
        let day = Self.dayFormatter.string(from: startDate)
        let timeText: String
        if isAllDay {
            timeText = "終日"
        } else {
            timeText = "\(Self.timeFormatter.string(from: startDate))-\(Self.timeFormatter.string(from: endDate))"
        }

        if let location, !location.isEmpty {
            return "\(day) \(timeText) \(title) @\(location)"
        }
        return "\(day) \(timeText) \(title)"
    }

    init(event: EKEvent) {
        let normalizedTitle = event.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "予定"
        let normalizedLocation = event.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        id = [
            event.eventIdentifier ?? UUID().uuidString,
            String(event.startDate.timeIntervalSince1970)
        ].joined(separator: "-")
        title = Self.truncated(normalizedTitle, maxLength: 36)
        startDate = event.startDate
        endDate = event.endDate
        isAllDay = event.isAllDay
        location = normalizedLocation.flatMap { $0.isEmpty ? nil : Self.truncated($0, maxLength: 28) }
        calendarTitle = event.calendar.title
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

@MainActor
final class CalendarContextManager: ObservableObject {
    @Published private(set) var authorizationState: CalendarContextAuthorizationState
    @Published private(set) var upcomingEvents: [CalendarContextEvent] = []
    @Published private(set) var hasFetchedEvents = false
    @Published private(set) var lastErrorMessage: String?

    private let eventStore = EKEventStore()
    private let maximumContextEventCount = 10

    init() {
        authorizationState = Self.authorizationState(from: EKEventStore.authorizationStatus(for: .event))
    }

    var authorizationSummary: String {
        authorizationState.label
    }

    var contextSummaryLines: [String] {
        upcomingEvents
            .prefix(maximumContextEventCount)
            .map { "カレンダー: \($0.contextLine)" }
    }

    var eventsSummary: String {
        if !authorizationState.canReadEvents {
            return "予定は未取得"
        }
        if !hasFetchedEvents {
            return "予定は未取得"
        }
        if upcomingEvents.isEmpty {
            return "今日と明日の予定はありません"
        }
        return "今日と明日の予定 \(upcomingEvents.count)件"
    }

    func refreshAuthorizationStatus() {
        authorizationState = Self.authorizationState(from: EKEventStore.authorizationStatus(for: .event))
    }

    func requestFullAccessAndRefresh() {
        Task {
            await requestFullAccess()
        }
    }

    func refreshUpcomingEventsIfAuthorized() {
        Task {
            await refreshUpcomingEvents()
        }
    }

    func clearEvents() {
        upcomingEvents = []
        hasFetchedEvents = false
        lastErrorMessage = nil
        refreshAuthorizationStatus()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @discardableResult
    func refreshUpcomingEvents() async -> [CalendarContextEvent] {
        refreshAuthorizationStatus()
        guard authorizationState.canReadEvents else {
            upcomingEvents = []
            hasFetchedEvents = false
            return []
        }

        let now = Date()
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: now)
        guard let endDate = calendar.date(byAdding: .day, value: 2, to: startDate) else {
            upcomingEvents = []
            hasFetchedEvents = false
            return []
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { shouldInclude($0, now: now) }
            .sorted {
                if $0.startDate == $1.startDate {
                    return ($0.title ?? "") < ($1.title ?? "")
                }
                return $0.startDate < $1.startDate
            }
            .prefix(maximumContextEventCount)
            .map(CalendarContextEvent.init(event:))

        upcomingEvents = Array(events)
        hasFetchedEvents = true
        lastErrorMessage = nil
        return upcomingEvents
    }

    private func requestFullAccess() async {
        do {
            let granted = try await requestCalendarFullAccess()
            refreshAuthorizationStatus()
            if granted {
                _ = await refreshUpcomingEvents()
            } else {
                upcomingEvents = []
                hasFetchedEvents = false
                lastErrorMessage = "カレンダーへのアクセスが許可されませんでした。"
            }
        } catch {
            refreshAuthorizationStatus()
            upcomingEvents = []
            hasFetchedEvents = false
            lastErrorMessage = "カレンダー権限の要求に失敗しました: \(error.localizedDescription)"
        }
    }

    private func requestCalendarFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    private func shouldInclude(_ event: EKEvent, now: Date) -> Bool {
        let title = event.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
        guard !title.isEmpty else { return false }

        if event.calendar.type == .birthday {
            return false
        }

        if event.isAllDay && event.endDate <= now {
            return false
        }

        let calendarTitle = event.calendar.title.lowercased()
        let lowercasedTitle = title.lowercased()
        let joined = "\(calendarTitle) \(lowercasedTitle)"
        let allDayNoiseKeywords = ["祝日", "休日", "誕生日", "holiday", "holidays", "birthday"]
        if event.isAllDay && allDayNoiseKeywords.contains(where: { joined.contains($0) }) {
            return false
        }

        return true
    }

    private static func authorizationState(from status: EKAuthorizationStatus) -> CalendarContextAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .legacyAuthorized
        case .writeOnly:
            return .writeOnly
        case .fullAccess:
            return .fullAccess
        @unknown default:
            return .unknown
        }
    }
}
