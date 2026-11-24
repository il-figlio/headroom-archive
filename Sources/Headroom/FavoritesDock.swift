import SwiftUI

/// Pinned-app icon strip inside the panel; renders nothing while empty so it
/// costs zero layout space for users who haven't pinned anything.
/// Total height when shown: 28 icon + 6 padding + 8 vertical = ~43px incl. hairline.
struct FavoritesDock: View {
    @ObservedObject var store = FavoritesStore.shared
    var body: some View {
        if store.items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { app in FavoriteButton(app: app, store: store) }
                    }.padding(.horizontal, 16).padding(.vertical, 4)
                }
                Divider().padding(.horizontal, 16)
            }
        }
    }
}

private struct FavoriteButton: View {
    let app: FavoriteApp
    @ObservedObject var store: FavoritesStore
    @State private var hover = false
    var body: some View {
        Button { store.activate(app) } label: {
            Group {
                if let icon = store.icon(for: app) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                if store.isRunning(app) {
                    Circle().fill(Color(nsColor: .systemGreen)).frame(width: 5, height: 5).offset(x: 2, y: 2)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .hoverDetail(app.name, [store.isRunning(app) ? "Running · click to bring forward" : "Click to open"], hovering: $hover)
        .accessibilityLabel("Open \(app.name)")
        .contextMenu {
            Button("Remove from Dock") {
                store.toggle(bundleIdentifier: app.bundleIdentifier, name: app.name, bundlePath: app.bundlePath)
            }
        }
    }
}
