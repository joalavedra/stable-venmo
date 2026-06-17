import SwiftUI

/// Venmo's shell: a social feed home and a profile tab, with the signature raised
/// "Pay or Request" button anchored in the center of the bottom bar.
struct MainView: View {
    enum Tab { case home, me }

    @State private var tab: Tab = .home
    @State private var showCompose = false

    var body: some View {
        Group {
            switch tab {
            case .home: FeedView()
            case .me: ProfileView()
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showCompose) { PayView(presetAmount: 0) }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            tabItem(.home, system: "house.fill", label: "Home")
            Spacer()
            composeButton
            Spacer()
            tabItem(.me, system: "person.crop.circle.fill", label: "Me")
        }
        .padding(.horizontal, 40)
        .padding(.top, 10)
        .background(
            Color.white
                .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(alignment: .top) { Divider() }
    }

    private func tabItem(_ target: Tab, system: String, label: String) -> some View {
        Button { tab = target } label: {
            VStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 22))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tab == target ? Theme.blue : Theme.subtle)
            .frame(width: 64)
        }
    }

    private var composeButton: some View {
        Button { showCompose = true } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Theme.blue)
                        .frame(width: 56, height: 56)
                        .shadow(color: Theme.blue.opacity(0.35), radius: 8, y: 3)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Pay/Request").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.subtle)
            }
        }
        .offset(y: -6)
    }
}
