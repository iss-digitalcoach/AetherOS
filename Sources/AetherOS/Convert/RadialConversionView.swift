import SwiftUI

enum ConversionState: Equatable {
    case running, done, failed(String)
}

/// View-local state without the `@State` macro (its compiler plugin ships only with full Xcode).
final class LocalState<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

/// The selected file sits in the middle; every available conversion orbits it as a button.
struct RadialConversionView: View {
    let files: [URL]
    let conversions: [Conversion]
    let states: [String: ConversionState]
    let selection: Int
    var onSelect: (Int) -> Void
    var onRun: (Int) -> Void

    @StateObject private var appearedState = LocalState(false)
    private var appeared: Bool { appearedState.value }
    private let radius: CGFloat = 112
    private let buttonSize: CGFloat = 60

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)

            center

            ForEach(Array(conversions.enumerated()), id: \.element.id) { i, c in
                let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(max(conversions.count, 1))
                button(c, index: i)
                    .offset(x: appeared ? cos(angle) * radius : 0, y: appeared ? sin(angle) * radius : 0)
                    .scaleEffect(appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.72).delay(Double(i) * 0.04), value: appeared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appearedState.value = true }
        .onDisappear { appearedState.value = false }
    }

    private var center: some View {
        VStack(spacing: 6) {
            ZStack {
                if files.count > 1 {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: files[1].path))
                        .resizable().frame(width: 52, height: 52).rotationEffect(.degrees(10)).offset(x: 10, y: -4).opacity(0.6)
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: files[0].path))
                    .resizable().frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 110)
            if conversions.indices.contains(selection) {
                Text(conversions[selection].title)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .id(selection)
                    .transition(.opacity.combined(with: .offset(y: 3)))
            }
        }
        .animation(.smooth(duration: 0.15), value: selection)
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appeared)
    }

    private func button(_ c: Conversion, index i: Int) -> some View {
        let selected = i == selection
        let state = states[c.id]
        return Button { onSelect(i); onRun(i) } label: {
            ZStack {
                Circle()
                    .fill(.primary.opacity(selected ? 0.14 : 0.07))
                    .overlay(Circle().strokeBorder(.primary.opacity(selected ? 0.35 : 0.12), lineWidth: selected ? 1.2 : 0.7))
                    .shadow(color: .primary.opacity(selected ? 0.25 : 0), radius: 10)
                VStack(spacing: 3) {
                    switch state {
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                    case nil: Image(systemName: c.symbol).font(.system(size: 15, weight: .medium))
                    }
                    Text(c.label).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .scaleEffect(selected ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .onContinuousHover { if case .active = $0, selection != i { onSelect(i) } }
        .help(c.title)
    }
}
