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
                AnalysisView(source: kind, onBack: { screen = .home })
            case .history:
                HistoryView(onBack: { screen = .home }, onOpen: { screen = .detail($0) })
            case .detail(let id):
                SessionDetailView(id: id, onBack: { screen = .history })
            }
        }
        .task {
            // CI hook: `-autotest_video <file>` jumps straight into a headless counting run.
            if model.autotestRequested {
                screen = .analysis(.video)
                model.runAutotest()
            }
        }
    }
}
