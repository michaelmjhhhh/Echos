import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var usage: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let calendar = Calendar.current

    var body: some View {
        let snapshot = usage.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    wpmCard(snapshot.wpm)
                    totalWordsCard(snapshot.totals)
                    dictationsCard(snapshot.totals)
                }
                .echoStagger(0, reduceMotion: reduceMotion)
                HStack(alignment: .top, spacing: Spacing.m) {
                    appUsageCard(Array(snapshot.apps.prefix(6)))
                    streakCard(snapshot)
                }
                .echoStagger(1, reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    EyebrowText(text: "Results")
                    Text("\(snapshot.totals.words.formatted()) recognized words · \(snapshot.totals.expandedWords.formatted()) output words after snippets")
                        .font(.echo(12)).foregroundStyle(Color.echoText)
                    Text("\(snapshot.outcomes["pasteDispatched", default: 0]) paste requests · \(snapshot.outcomes["copied", default: 0]) copied · \(snapshot.outcomes["awaitingCopy", default: 0]) awaiting copy · \(snapshot.outcomes["cancelled", default: 0]) cancelled")
                        .font(.echo(11)).foregroundStyle(Color.echoSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).echoCard()
                Text("Words count recognized speech before snippet expansion. A paste request does not confirm that text appeared in another app. Older records may include expanded text.")
                    .font(.echo(11)).foregroundStyle(Color.echoSecondary)
                if let error = usage.persistenceError {
                    Text(error).font(.echo(11)).foregroundStyle(Color.echoWarning)
                }
            }
            .echoContentColumn()
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
            HStack(alignment: .center, spacing: Spacing.s) {
                WPMGauge(value: wpm, reduceMotion: reduceMotion)
                Text("\(wpm)")
                    .font(.echoDisplay(30))
                    .tracking(-0.6)
                    .foregroundStyle(Color.echoText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.spring, value: wpm)
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
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.spring, value: totals.words)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: IconSize.caption, weight: .bold))
                        .accessibilityHidden(true)
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
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.spring, value: totals.dictations)
                Text(totals.activeDays == 1 ? "1 active day" : "\(totals.activeDays) active days")
                    .font(.echoMono(10))
                    .foregroundStyle(Color.echoSecondary)
            }
        }
    }

    // MARK: - Row 2 (equal fixed heights)

    private let detailCardHeight: CGFloat = 200

    private func appUsageCard(_ apps: [AppUsage]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            EyebrowText(text: "Dictation target apps")
            if apps.isEmpty {
                Spacer()
                EchoEmptyState(icon: "app.dashed") {
                    Text("The app active when dictation starts appears here.")
                        .font(.echo(12))
                }
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

    private func streakCard(_ snapshot: UsageSnapshot) -> some View {
        let since = calendar.date(byAdding: .weekOfYear, value: -20, to: Date()) ?? Date()
        let recentDaily = snapshot.daily.filter { $0.key >= since }
        let activeDays = recentDaily.values.filter { $0 > 0 }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.currentStreak == 1 ? "1 day streak" : "\(snapshot.currentStreak) day streak")
                    .font(.echoDisplay(16))
                    .tracking(-0.2)
                    .foregroundStyle(Color.echoText)
                Spacer()
                EyebrowText(text: "Longest | \(snapshot.longestStreak)")
            }
            Spacer(minLength: 0)
            StreakHeatmap(daily: recentDaily)
                // 126 individual cells are VoiceOver noise — one summary instead.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dictation activity calendar")
                .accessibilityValue(
                    "\(snapshot.currentStreak) day current streak, longest \(snapshot.longestStreak), active on \(activeDays) recent days"
                )
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
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: detailCardHeight)
        .echoCard()
    }
}

/// Half-circle gauge drawn as a real arc path (no clipping tricks).
/// Scale caps at 200 WPM. Sweeps up from zero on first appearance.
private struct WPMGauge: View {
    let value: Int
    let reduceMotion: Bool

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            GaugeArc(fraction: 1)
                .stroke(Color.echoHairline, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            GaugeArc(fraction: appeared ? min(Double(value) / 200, 1) : 0)
                .stroke(Color.echoAccent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        .frame(width: 60, height: 34)
        // Decorative — the number beside it carries the value.
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(Motion.spring) { appeared = true }
            }
        }
    }
}

private struct GaugeArc: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

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
        // Truncation recovery + exact value, on the whole row.
        .help("\(app.words.formatted()) recognized words with \(app.name) as the intended destination")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("\(app.words.formatted()) words")
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
