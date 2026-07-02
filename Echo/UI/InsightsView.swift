import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var usage: UsageStore

    private let calendar = Calendar.current

    /// All card data, derived fresh on every render — no cached copy to go
    /// stale. Queries are a handful of indexed reads on a tiny local DB.
    private struct Snapshot {
        var totals: UsageTotals
        var wpm: Int
        var apps: [AppUsage]
        var daily: [Date: Int]
        var currentStreak: Int
        var longestStreak: Int
    }

    private func makeSnapshot() -> Snapshot {
        _ = usage.revision // explicit dependency on the store's write counter
        let since = calendar.date(byAdding: .weekOfYear, value: -20, to: Date()) ?? Date()
        let daily = usage.dailyWords(since: since)
        let streaks = Streaks.compute(
            activeDays: Set(daily.filter { $0.value > 0 }.keys),
            today: Date(),
            calendar: calendar
        )
        return Snapshot(
            totals: usage.totals(),
            wpm: usage.averageWPM(),
            apps: usage.perAppWords(),
            daily: daily,
            currentStreak: streaks.current,
            longestStreak: streaks.longest
        )
    }

    var body: some View {
        let snapshot = makeSnapshot()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    wpmCard(snapshot.wpm)
                    totalWordsCard(snapshot.totals)
                    dictationsCard(snapshot.totals)
                }
                HStack(alignment: .top, spacing: 16) {
                    appUsageCard(snapshot.apps)
                    streakCard(snapshot)
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - Row 1 (equal fixed heights so the cards align)

    private let statCardHeight: CGFloat = 104

    private func statCard(eyebrow: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EyebrowText(text: eyebrow)
            Spacer(minLength: 0)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: statCardHeight)
        .echoCard()
    }

    private func wpmCard(_ wpm: Int) -> some View {
        statCard(eyebrow: "Words per minute") {
            HStack(alignment: .center, spacing: 12) {
                WPMGauge(value: wpm)
                Text("\(wpm)")
                    .font(.echoDisplay(30))
                    .tracking(-0.6)
                    .foregroundStyle(Color.echoText)
            }
        }
    }

    private func totalWordsCard(_ totals: UsageTotals) -> some View {
        statCard(eyebrow: "Total words dictated") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(totals.words.formatted())")
                    .font(.echoDisplay(30))
                    .tracking(-0.6)
                    .foregroundStyle(Color.echoText)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(totals.wordsThisMonth.formatted()) this month")
                        .font(.echoMono(10, medium: true))
                }
                .foregroundStyle(Color.echoAccent)
                .opacity(totals.wordsThisMonth > 0 ? 1 : 0)
            }
        }
    }

    private func dictationsCard(_ totals: UsageTotals) -> some View {
        statCard(eyebrow: "Dictations") {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(totals.dictations.formatted())")
                    .font(.echoDisplay(30))
                    .tracking(-0.6)
                    .foregroundStyle(Color.echoText)
                Text(totals.activeDays == 1 ? "1 active day" : "\(totals.activeDays) active days")
                    .font(.echoMono(10))
                    .foregroundStyle(Color.echoSecondary)
            }
        }
    }

    // MARK: - Row 2 (equal fixed heights)

    private let detailCardHeight: CGFloat = 200

    private func appUsageCard(_ apps: [AppUsage]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EyebrowText(text: "App usage")
            if apps.isEmpty {
                Spacer()
                Text("Dictate into any app and it shows up here.")
                    .font(.echo(12))
                    .foregroundStyle(Color.echoSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                let maxWords = apps.map(\.words).max() ?? 1
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(apps) { app in
                        AppUsageBar(app: app, fraction: Double(app.words) / Double(maxWords))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: detailCardHeight)
        .echoCard()
    }

    private func streakCard(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.currentStreak == 1 ? "1 day streak" : "\(snapshot.currentStreak) day streak")
                    .font(.echoDisplay(16))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
                Spacer()
                EyebrowText(text: "Longest | \(snapshot.longestStreak)")
            }
            Spacer(minLength: 0)
            StreakHeatmap(daily: snapshot.daily)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("LESS")
                    .font(.echoMono(8))
                    .foregroundStyle(Color.echoSecondary)
                ForEach([0.15, 0.4, 0.7, 1.0], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.echoAccent.opacity(opacity))
                        .frame(width: 8, height: 8)
                }
                Text("MORE")
                    .font(.echoMono(8))
                    .foregroundStyle(Color.echoSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: detailCardHeight)
        .echoCard()
    }
}

/// Half-circle gauge drawn as a real arc path (no clipping tricks).
/// Scale caps at 200 WPM.
private struct WPMGauge: View {
    let value: Int

    var body: some View {
        ZStack(alignment: .bottom) {
            GaugeArc(fraction: 1)
                .stroke(Color.echoHairline, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            GaugeArc(fraction: min(Double(value) / 200, 1))
                .stroke(Color.echoAccent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        .frame(width: 60, height: 34)
    }
}

private struct GaugeArc: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard fraction > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.maxY - 4)
        let radius = min(rect.width / 2, rect.height) - 4
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(180 + 180 * fraction),
            clockwise: false
        )
        return path
    }
}

private struct AppUsageBar: View {
    let app: AppUsage
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(app.name)
                .font(.echo(12, .medium))
                .foregroundStyle(Color.echoText)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.echoAccent.opacity(0.25 + 0.75 * fraction))
                    .frame(width: max(10, geometry.size.width * fraction))
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 13)
            Text("\(app.words.formatted())")
                .font(.echoMono(10))
                .foregroundStyle(Color.echoSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// GitHub-style calendar: columns are weeks (oldest → newest), rows Sun–Sat,
/// intensity in four cyan steps. Month labels are positioned absolutely so
/// they never truncate.
private struct StreakHeatmap: View {
    let daily: [Date: Int]

    private let calendar = Calendar.current
    private let weekCount = 18
    private let cellSize: CGFloat = 9
    private let cellGap: CGFloat = 3

    private var columnStride: CGFloat { cellSize + cellGap }

    private var weeks: [[Date?]] {
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday
        guard let thisWeekStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: today) else { return [] }
        return (0..<weekCount).reversed().map { weekOffset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekOffset, to: thisWeekStart) else {
                return Array(repeating: nil, count: 7)
            }
            return (0..<7).map { dayOffset in
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart), day <= today else {
                    return nil
                }
                return day
            }
        }
    }

    private var maxWords: Int {
        max(daily.values.max() ?? 1, 1)
    }

    var body: some View {
        let columns = weeks
        VStack(alignment: .leading, spacing: 5) {
            // Month labels, absolutely positioned at their column's x offset.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: 10)
                ForEach(columns.indices, id: \.self) { columnIndex in
                    if let label = monthLabel(for: columns[columnIndex]) {
                        Text(label)
                            .font(.echoMono(8))
                            .foregroundStyle(Color.echoSecondary)
                            .fixedSize()
                            .offset(x: CGFloat(columnIndex) * columnStride)
                    }
                }
            }
            HStack(alignment: .top, spacing: cellGap) {
                ForEach(columns.indices, id: \.self) { columnIndex in
                    VStack(spacing: cellGap) {
                        ForEach(0..<7, id: \.self) { rowIndex in
                            cell(for: columns[columnIndex][rowIndex])
                        }
                    }
                }
            }
        }
    }

    /// Label a column when it contains the first day of a month.
    private func monthLabel(for week: [Date?]) -> String? {
        for case let day? in week where calendar.component(.day, from: day) == 1 {
            return day.formatted(.dateTime.month(.abbreviated))
        }
        return nil
    }

    @ViewBuilder
    private func cell(for day: Date?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        if let day {
            let words = daily[day] ?? 0
            if words == 0 {
                shape
                    .fill(Color.echoHairline)
                    .frame(width: cellSize, height: cellSize)
            } else {
                let fraction = Double(words) / Double(maxWords)
                let opacity = fraction > 0.75 ? 1.0 : fraction > 0.5 ? 0.7 : fraction > 0.25 ? 0.4 : 0.15
                shape
                    .fill(Color.echoAccent.opacity(opacity))
                    .frame(width: cellSize, height: cellSize)
                    .help("\(words.formatted()) words · \(day.formatted(date: .abbreviated, time: .omitted))")
            }
        } else {
            shape
                .fill(.clear)
                .frame(width: cellSize, height: cellSize)
        }
    }
}
