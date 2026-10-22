import SwiftUI

@main
struct FreeCountTrafficApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Theme.orange)
        }
    }
}

enum Screen: Equatable {
    case home
    case analysis(SourceKind)
    case history
    case detail(UUID)
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var screen: Screen = .home

    var body: some View {
        Group {
            switch screen {
            case .home:
                HomeView(onSource: { screen = .analysis($0) }, onHistory: { screen = .history })
            case .analysis(let kind):
                AnalysisView(source: kind, onBack: { screen = .home }, onResults: { screen = .detail($0) })
            case .history:
                HistoryView(onBack: { screen = .home }, onOpen: { screen = .detail($0) })
            case .detail(let id):
                SessionDetailView(id: id, onBack: { screen = .history })
            }
        }
        .onChange(of: model.autotestStage) { stage in
            if stage == 1, let id = model.lastSessionId { screen = .detail(id) }
        }
        .task {
            // CI hook: `-autotest_video <file>` / `-autotest_rtsp <url>` jumps straight into a headless counting run.
            if model.autotestRequested {
                screen = .analysis(model.autotestSource)
                model.runAutotest()
            }
        }
    }
}
