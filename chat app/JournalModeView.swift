//
//  JournalModeView.swift
//  chat app
//

import PhotosUI
import SwiftUI
import UIKit

struct JournalModeView: View {
    @ObservedObject var journalStore: JournalStore
    @ObservedObject var locationAuthorization: LocationAuthorizationManager
    var calendarContextLines: [String]
    var existingConversationMessages: [ConversationMessage]
    var onStartSession: (JournalPromptContext) -> Void
    var onPhotoContextUpdated: (JournalPromptContext) -> Void
    var onFinish: (JournalEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedEntry: JournalEntry?
    @State private var importErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let selectedEntry {
                    JournalEntryDetailView(
                        entry: selectedEntry,
                        journalStore: journalStore,
                        onBack: {
                            withAnimation(.snappy) {
                                self.selectedEntry = nil
                            }
                        }
                    )
                } else if journalStore.isJournaling {
                    activeJournalView
                } else {
                    journalHomeView
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(journalStore.isJournaling ? "ジャーナリング" : "日記")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") {
                    dismiss()
                }
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
    }

    private var journalHomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.snappy) {
                    let context = journalStore.startSession(
                        ignoring: existingConversationMessages,
                        calendarContextLines: calendarContextLines
                    )
                    onStartSession(context)
                }
                dismiss()
            } label: {
                Label("会話で聞き取りを始める", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            quickEntrySection
            historySection
        }
    }

    private var quickEntrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("すぐ見る")
                .font(.headline)

            if let todayEntry = journalStore.todayEntry {
                Button {
                    selectedEntry = todayEntry
                } label: {
                    JournalEntryRow(entry: todayEntry, systemImage: "sun.max")
                }
                .buttonStyle(.plain)
            }

            if let yesterdayEntry = journalStore.yesterdayEntry {
                Button {
                    selectedEntry = yesterdayEntry
                } label: {
                    JournalEntryRow(entry: yesterdayEntry, systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
            } else {
                Label("昨日の日記はまだありません", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("蓄積された日記")
                .font(.headline)

            if journalStore.entries.isEmpty {
                ContentUnavailableView("日記はまだありません", systemImage: "book.closed")
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(journalStore.entries.prefix(14)) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            JournalEntryRow(entry: entry, systemImage: "book.pages")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var activeJournalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            activeSummaryHeader
            photoPickerSection
            locationSection
            calendarSection
            journalMessagesSection
            finishButton
        }
    }

    private var activeSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("会話で聞き取り中", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                Spacer()
                Text("\(journalStore.draft.messages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label("\(journalStore.draft.photoItems.count)枚", systemImage: "photo")
                Label("\(journalStore.todayLocationSamples.count)地点", systemImage: "location")
                Label("\(journalStore.calendarContextLines.count)件", systemImage: "calendar")
                Label("\(filledSlotCount)/\(JournalSlot.allCases.count)項目", systemImage: "checklist")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(JournalSlot.allCases) { slot in
                    let status = journalStore.draft.slotStatuses[slot.rawValue] ?? .missing
                    Label(slot.rawValue, systemImage: status == .filled ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(status == .filled ? .green : .secondary)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var filledSlotCount: Int {
        JournalSlot.allCases.filter {
            journalStore.draft.slotStatuses[$0.rawValue] == .filled
        }.count
    }

    private var photoPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("写真")
                    .font(.headline)
                Spacer()
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 12,
                    matching: .images
                ) {
                    Label("選ぶ", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }

            if let importErrorMessage {
                Text(importErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if journalStore.draft.photoItems.isEmpty {
                Text("未選択")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 10) {
                    ForEach(journalStore.draft.photoItems) { photo in
                        JournalPhotoMemoRow(photo: photo, journalStore: journalStore)
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("移動履歴")
                    .font(.headline)
                Spacer()
                Text(locationAuthorization.authorizationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(locationAuthorization.latestLocationSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if journalStore.todayLocationSamples.isEmpty {
                Text("今日の位置記録はまだありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(journalStore.todayLocationSamples.suffix(5)) { point in
                        JournalLocationRow(point: point)
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("予定")
                    .font(.headline)
                Spacer()
                Text("\(journalStore.calendarContextLines.count)件")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if journalStore.calendarContextLines.isEmpty {
                Text("予定素材はありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(journalStore.calendarContextLines.prefix(5)), id: \.self) { line in
                        Label(line, systemImage: "calendar")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var journalMessagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会話素材")
                .font(.headline)

            if journalStore.draft.messages.isEmpty {
                Text("まだありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(journalStore.draft.messages.suffix(8)) { message in
                        JournalMessageRow(message: message)
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var finishButton: some View {
        Button {
            let entry = journalStore.finishSession()
            onFinish(entry)
            withAnimation(.snappy) {
                selectedEntry = entry
            }
        } label: {
            Label("終了して日記を表示", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var lastError: String?

            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension
                    try journalStore.addPhoto(data: data, fileExtension: fileExtension)
                } catch {
                    lastError = "写真を読み込めませんでした: \(error.localizedDescription)"
                }
            }

            importErrorMessage = lastError
            selectedPhotoItems = []

            if lastError == nil, !items.isEmpty {
                onPhotoContextUpdated(journalStore.promptContext())
                dismiss()
            }
        }
    }
}

private struct JournalEntryRow: View {
    var entry: JournalEntry
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(entry.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct JournalEntryDetailView: View {
    var entry: JournalEntry
    var journalStore: JournalStore
    var onBack: () -> Void

    private let photoColumns = [
        GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                Label("一覧に戻る", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                    .font(.title3.weight(.bold))
                Text(entry.overview)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))

            JournalBulletSection(title: "出来事", values: entry.eventNotes)
            JournalBulletSection(title: "気持ち", values: entry.feelingNotes)
            JournalBulletSection(title: "明日に持ち越すこと", values: entry.carryOvers)

            if !entry.photos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("写真")
                        .font(.headline)
                    LazyVGrid(columns: photoColumns, alignment: .leading, spacing: 8) {
                        ForEach(entry.photos) { photo in
                            JournalPhotoThumbnail(photo: photo, journalStore: journalStore)
                        }
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }

            if !entry.locations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("移動メモ")
                        .font(.headline)
                    ForEach(entry.locations.prefix(10)) { point in
                        JournalLocationRow(point: point)
                    }
                }
                .padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("日記本文")
                    .font(.headline)
                Text(entry.markdown)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct JournalBulletSection: View {
    var title: String
    var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if values.isEmpty {
                Text("なし")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(value)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct JournalMessageRow: View {
    var message: JournalMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(message.createdAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(message.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        switch message.speaker {
        case .user:
            .blue
        case .assistant:
            .purple
        case .system:
            .secondary
        }
    }
}

private struct JournalPhotoMemoRow: View {
    var photo: JournalPhotoItem
    @ObservedObject var journalStore: JournalStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            JournalPhotoThumbnail(photo: photo, journalStore: journalStore)
                .frame(width: 72, height: 72)

            TextField(
                "写真メモ",
                text: Binding(
                    get: { currentMemo },
                    set: { journalStore.updatePhotoMemo(photoID: photo.id, memo: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
        }
    }

    private var currentMemo: String {
        journalStore.draft.photoItems.first(where: { $0.id == photo.id })?.userMemo ?? photo.userMemo
    }
}

private struct JournalPhotoThumbnail: View {
    var photo: JournalPhotoItem
    var journalStore: JournalStore

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: journalStore.photoURL(for: photo).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.secondary.opacity(0.08))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if !photo.userMemo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(photo.userMemo)
                    .font(.caption2)
                    .lineLimit(2)
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
            }
        }
    }
}

private struct JournalLocationRow: View {
    var point: JournalLocationPoint

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(point.recordedAt, style: .time)
                    .font(.caption.weight(.semibold))
                Text(point.coordinateText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("+/-\(Int(point.horizontalAccuracy))m")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    NavigationStack {
        JournalModeView(
            journalStore: JournalStore(),
            locationAuthorization: LocationAuthorizationManager(),
            calendarContextLines: [],
            existingConversationMessages: [],
            onStartSession: { _ in },
            onPhotoContextUpdated: { _ in },
            onFinish: { _ in }
        )
    }
}
