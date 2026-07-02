import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var usage: UsageStore

    @State private var totals = UsageTotals()
    @State private var wpm = 0
    @State private var apps: [AppUsage] = []
    @State private var daily: [Date: Int] = [:]
    @State private var currentStreak = 0
    @State private var longestStreak = 0

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    wpmCard
                    totalWordsCard
                    dictationsCard
                }
                HStack(alignment: .top, spacing: 16) {
                    appUsageCard
                    streakCard
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .onAppear(perform: refresh)
        .onChange(of: usage.revision) { _, _ in refresh() }
    }

    private func refresh() {
        totals = usage.totals()
        wpm = usage.averageWPM()
        apps = usage.perAppWords()
        let since = calendar.date(byAdding: .weekOfYear, value: -20, to: Date()) ?? Date()
        daily = usage.dailyWords(since: since)
        let streaks = Streaks.compute(activeDays: Set(daily.filter { $0.value > 0 }.keys), today: Date(), calendar: calendar)
        currentStreak = streaks.current
        longestStreak = streaks.longest
    }

    // MARK: - Row 1

    private var wpmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            EyebrowText(text: "Words per minute")
            HStack(spacing: 14) {
                WPMGauge(value: wpm)
                Text("\(wpm)")
                    .font(.echoDisplay(32))
                    .tracking(-0.6)
                    .foregroundStyle(Color.echoText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    private var totalWordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            EyebrowText(text: "Total words dictated")
            Text("\(totals.words.formatted())")
                .font(.echoDisplay(32))
                .tracking(-0.6)
                .foregroundStyle(Color.echoText)
            if totals.wordsThisMonth > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(totals.wordsThisMonth.formatted()) this month")
                        .font(.echoMono(10, medium: true))
                }
                .foregroundStyle(Color.echoAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    private var dictationsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            EyebrowText(text: "Dictations")
            Text("\(totals.dictations.formatted())")
                .font(.echoDisplay(32))
                .tracking(-0.6)
                .foregroundStyle(Color.echoText)
            Text("\(totals.activeDays) active days")
                .font(.echoMono(10))
                .foregroundStyle(Color.echoSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .echoCard()
    }

    // MARK: - Row 2

    private var appUsageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            EyebrowText(text: "App usage")
            if apps.isEmpty {
                Text("Dictate into any app and it shows up here.")
                    .font(.echo(12))
                    .foregroundStyle(Color.echoSecondary)
                    .padding(.vertical, 12)
            } else {
                let maxWords = apps.map(\.words).max() ?? 1
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(apps) { app in
                        AppUsageBar(app: app, fraction: Double(app.words) / Double(maxWords))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .echoCard()
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(currentStreak) day streak")
                    .font(.echoDisplay(17))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
                Spacer()
                EyebrowText(text: "Longest | \(longestStreak)")
            }
            StreakHeatmap(daily: daily)
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
        .echoCard()
    }
}

/// Half-circle gauge, cyan on a hairline track. Scale caps at 200 WPM.
private struct WPMGauge: View {
    let value: Int

    var body: some View {
        ZStack {
            arc(fraction: 1, color: Color.echoHairline)
            arc(fraction: min(Double(value) / 200, 1), color: Color.echoAccent)
        }
        .frame(width: 64, height: 32)
    }

    private func arc(fraction: Double, color: Color) -> some View {
        Circle()
            .trim(from: 0, to: 0.5 * fraction)
            .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            .rotationEffect(.degrees(180))
            .frame(width: 64, height: 64)
            .offset(y: 16)
            .clipped()
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
                .frame(width: 90, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.echoAccent.opacity(0.25 + 0.75 * fraction))
                    .frame(width: max(10, geometry.size.width * fraction))
            }
            .frame(height: 14)
            Text("\(app.words.formatted())")
                .font(.echoMono(10))
                .foregroundStyle(Color.echoSecondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// GitHub-style calendar: columns are weeks (oldest → newest), rows Sun–Sat,
/// intensity in four cyan steps.
private struct StreakHeatmap: View {
    let daily: [Date: Int]

    private let calendar = Calendar.current
    private let weekCount = 18
    private let cellSize: CGFloat = 9
    private let cellGap: CGFloat = 3

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
        VStack(alignment: .leading, spacing: 4) {
            monthLabels(for: columns)
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

    private func monthLabels(for columns: [[Date?]]) -> some View {
        HStack(alignment: .top, spacing: cellGap) {
            ForEach(columns.indices, id: \.self) { columnIndex in
                let label = monthLabel(for: columns[columnIndex])
                Text(label ?? " ")
                    .font(.echoMono(8))
                    .foregroundStyle(Color.echoSecondary)
                    .frame(width: cellSize, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: 10, alignment: .top)
        .clipped()
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
