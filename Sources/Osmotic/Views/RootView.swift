import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.screen {
            case .cameras: CamerasView()
            case .connecting: ConnectingView()
            case .library: LibraryView()
            }
        }
        .font(Theme.bodyFont)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AluminumPlate().ignoresSafeArea() }
        .motion(Motion.quick, value: model.screen)
        // A card plugged in or pulled out, on any screen.
        .onChange(of: model.cards.cards) { model.cardsChanged() }
        .onAppear {
            model.arrivalNotifier.openMain = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// The strip across the top of every screen: the printed wordmark on the left, the tabs centered and
/// whatever status that screen wants on the right, aligned with the panels below. The window buttons
/// sit in the title-bar band above it (the content starts under that band), so no room is kept here.
struct TopPlate<Center: View, Trailing: View>: View {
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            HStack(spacing: Theme.s3) {
                // "osmotic." — the dot sits on the baseline like a period, as in the app icon's "o.".
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(verbatim: "Pocket Transfer")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Circle().fill(Theme.accent).frame(width: 4.5, height: 4.5)
                        .shadow(Depth.glow(Theme.accent, 0.4))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pocket Transfer")
                Spacer()
                trailing
            }
            center
        }
        .padding(.horizontal, Theme.s3)
        .frame(height: 56)
    }
}

/// The Settings key on the plate: the same door as ⌘, and the menu item, where a hand looks for it.
struct SettingsKey: View {
    var body: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape.fill")
        }
        .buttonStyle(.compactKey)
        .help("Open Osmotic's settings")
    }
}

extension TopPlate where Center == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.center = EmptyView()
        self.trailing = trailing()
    }
}
