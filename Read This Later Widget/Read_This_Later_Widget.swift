//
//  Read_This_Later_Widget.swift
//  Read This Later Widget
//
//  Created by Michael Shear on 20/06/2026.
//

import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), items: Self.samples(count: context.family == .systemSmall ? 1 : 3))
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        completion(SimpleEntry(date: Date(), items: recentUnreadItems(limit: limit(for: context.family))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = SimpleEntry(date: Date(), items: recentUnreadItems(limit: limit(for: context.family)))
        // ReadLaterStore.save() proactively reloads this widget whenever any
        // client saves/syncs, so this periodic refresh is just a fallback.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func limit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 3
        default: return 5
        }
    }

    private func recentUnreadItems(limit: Int) -> [ReadLaterItem] {
        Array(ReadLaterStore.shared.visible().filter { !$0.read }.prefix(limit))
    }

    private static func samples(count: Int) -> [ReadLaterItem] {
        (1...count).map { ReadLaterItem(url: "https://example.com/\($0)", title: "Sample saved article \($0)") }
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let items: [ReadLaterItem]
}

struct Read_This_Later_WidgetEntryView: View {
    var entry: Provider.Entry

    var body: some View {
        if entry.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                Text("All caught up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.items, id: \.url) { item in
                    Link(destination: URL(string: item.url) ?? URL(string: "https://example.com")!) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                            if let host = URL(string: item.url)?.host {
                                Text(host)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if item.url != entry.items.last?.url {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Read_This_Later_Widget: Widget {
    let kind: String = "Read_This_Later_Widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                Read_This_Later_WidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                Read_This_Later_WidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Recent Unread")
        .description("Shows your most recently saved unread articles.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemMedium) {
    Read_This_Later_Widget()
} timeline: {
    SimpleEntry(date: .now, items: [
        ReadLaterItem(url: "https://example.com/1", title: "A short article worth reading"),
        ReadLaterItem(url: "https://example.com/2", title: "Another saved piece"),
        ReadLaterItem(url: "https://example.com/3", title: "Third item in the list"),
    ])
    SimpleEntry(date: .now, items: [])
}
