import AppKit
import Charts
import SwiftUI

enum DashboardRange: String, CaseIterable, Identifiable {
  case hour = "1 Saat"
  case day = "24 Saat"
  case week = "7 Gün"

  var id: String { rawValue }
  var interval: TimeInterval {
    switch self {
    case .hour: return 3600
    case .day: return 24 * 3600
    case .week: return 7 * 24 * 3600
    }
  }
}

struct ApplicationHistorySample: Identifiable {
  let id: UUID
  let date: Date
  let watts: Double
}

struct EnergyDashboardActions {
  let activate: (ApplicationPowerUsage) -> Void
  let reveal: (ApplicationPowerUsage) -> Void
  let terminate: (ApplicationPowerUsage) -> Void
  let exportCSV: () -> Void
}

final class EnergyDashboardModel: ObservableObject {
  @Published var history: [EnergyHistoryPoint] = []
  @Published var currentUsages: [ApplicationPowerUsage] = []
  @Published var currentBatteryWatts = 0.0
  @Published var currentAttributedWatts = 0.0
  @Published var coverage = 0.0
  @Published var selectedRange = DashboardRange.hour
  @Published var selectedApplicationName: String?

  let actions: EnergyDashboardActions

  init(actions: EnergyDashboardActions) {
    self.actions = actions
  }

  var filteredHistory: [EnergyHistoryPoint] {
    let cutoff = Date().addingTimeInterval(-selectedRange.interval)
    let selected = history.filter { $0.date >= cutoff }
    let stride = max(Int(ceil(Double(selected.count) / 1_000)), 1)
    return selected.enumerated().compactMap { index, point in
      index.isMultiple(of: stride) || index == selected.count - 1 ? point : nil
    }
  }

  var selectedApplicationHistory: [ApplicationHistorySample] {
    guard let selectedApplicationName else { return [] }
    return filteredHistory.compactMap { point in
      guard
        let usage = point.applications.first(where: {
          $0.applicationName == selectedApplicationName
        })
      else { return nil }
      return ApplicationHistorySample(id: point.id, date: point.date, watts: usage.watts)
    }
  }

  var historicalTopApplications: [HistoricalApplicationUsage] {
    var totals: [String: (watts: Double, count: Int)] = [:]
    for point in filteredHistory {
      for app in point.applications {
        totals[app.applicationName, default: (0, 0)].watts += app.watts
        totals[app.applicationName, default: (0, 0)].count += 1
      }
    }
    return totals.map { name, value in
      HistoricalApplicationUsage(
        applicationName: name,
        watts: value.watts / Double(max(value.count, 1))
      )
    }.sorted { $0.watts > $1.watts }.prefix(8).map { $0 }
  }
}

struct EnergyDashboardView: View {
  @ObservedObject var model: EnergyDashboardModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text("Enerji Geçmişi").font(.title2.bold())
            Text("Pil akışı ve uygulamalara atfedilen enerji ayrı ölçümlerdir.")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Picker("Dönem", selection: $model.selectedRange) {
            ForEach(DashboardRange.allCases) { range in Text(range.rawValue).tag(range) }
          }.pickerStyle(.segmented).frame(width: 260)
          Button("CSV Dışa Aktar") { model.actions.exportCSV() }
        }

        HStack(spacing: 12) {
          metricCard("Pil Gücü", value: watts(model.currentBatteryWatts), color: .yellow)
          metricCard(
            "Uygulamalara Atfedilen", value: watts(model.currentAttributedWatts), color: .cyan)
          metricCard(
            "Ölçüm Kapsamı", value: "%\(Int((model.coverage * 100).rounded()))", color: .green)
        }

        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Pil Gücü").font(.headline)
            Chart(model.filteredHistory) { point in
              LineMark(
                x: .value("Zaman", point.date),
                y: .value("Watt", point.batteryWatts)
              )
              .foregroundStyle(by: .value("Durum", point.isCharging ? "Şarj" : "Pil"))
            }
            .chartForegroundStyleScale(["Pil": Color.yellow, "Şarj": Color.green])
            .frame(minHeight: 170)

            Text("Uygulamalara Atfedilen Güç").font(.headline)
            Chart(model.filteredHistory) { point in
              LineMark(
                x: .value("Zaman", point.date),
                y: .value("Watt", point.attributedApplicationWatts)
              ).foregroundStyle(.cyan)
            }.frame(minHeight: 150)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Dönemin En Çok Tüketenleri").font(.headline)
            Chart(model.historicalTopApplications) { app in
              BarMark(
                x: .value("Watt", app.watts),
                y: .value("Uygulama", app.applicationName)
              ).foregroundStyle(.orange.gradient)
            }.frame(width: 260, height: 330)
          }
        }

        Divider()
        if let selectedApplicationName = model.selectedApplicationName {
          HStack {
            Text("\(selectedApplicationName) Geçmişi").font(.headline)
            Spacer()
            Button("Seçimi Temizle") { model.selectedApplicationName = nil }
          }
          Chart(model.selectedApplicationHistory) { sample in
            LineMark(
              x: .value("Zaman", sample.date),
              y: .value("Watt", sample.watts)
            ).foregroundStyle(.orange)
          }.frame(height: 110)
        }
        Text("Şu Anki Uygulamalar").font(.headline)
        LazyVStack(spacing: 8) {
          ForEach(model.currentUsages) { usage in
            DisclosureGroup {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(usage.processes) { process in
                  HStack {
                    Text(process.processName).lineLimit(1)
                    Spacer()
                    Text(watts(process.watts)).monospacedDigit()
                  }.foregroundStyle(.secondary)
                }
                HStack {
                  Button("Geçmişi Göster") {
                    model.selectedApplicationName = usage.applicationName
                  }
                  Button("Uygulamaya Geç") { model.actions.activate(usage) }
                  Button("Finder'da Göster") { model.actions.reveal(usage) }
                  Button("Kapat", role: .destructive) { model.actions.terminate(usage) }
                }
              }.padding(.top, 6)
            } label: {
              HStack {
                Text(usage.applicationName).fontWeight(.medium)
                Text("\(usage.processes.count) süreç").foregroundStyle(.secondary)
                Spacer()
                Text(watts(usage.watts)).monospacedDigit()
                Text(share(usage)).foregroundStyle(.secondary).frame(
                  width: 48, alignment: .trailing)
              }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
          }
        }
      }
      .padding(20)
    }
    .frame(minWidth: 850, minHeight: 720)
  }

  private func metricCard(_ title: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
  }

  private func watts(_ value: Double) -> String {
    if value > 0 && value < 0.01 { return "<0,01 W" }
    return String(format: "%.2f W", locale: Locale(identifier: "tr_TR"), value)
  }

  private func share(_ usage: ApplicationPowerUsage) -> String {
    guard model.currentAttributedWatts > 0 else { return "%0" }
    return "%\(Int((usage.watts / model.currentAttributedWatts * 100).rounded()))"
  }
}

final class EnergyDashboardWindowController: NSWindowController {
  init(model: EnergyDashboardModel) {
    let hostingController = NSHostingController(rootView: EnergyDashboardView(model: model))
    let window = NSWindow(contentViewController: hostingController)
    window.title = "WattWhat Enerji Geçmişi"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 900, height: 760))
    window.center()
    window.isReleasedWhenClosed = false
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
