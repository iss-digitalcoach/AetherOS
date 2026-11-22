import SwiftUI

struct HUDView: View {
    @Bindable var model: HUDViewModel
    let style: HUDStyle
    var onDismiss: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Namespace private var selectionNS

    static let size = CGSize(width: 720, height: 480)

    private var themes: ThemeEngine { model.services.themes }
    private var isDark: Bool { style == .notch || scheme == .dark }

    var body: some View {
        switch style {
        case .classic: classic
        case .notch: notch
        }
    }

    // MARK: Chrome

    private var classic: some View {
        let theme = themes.current
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        return ZStack {
            GlassBackground(theme: theme, isDark: isDark, isActive: model.isVisible)
            content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(rimGradient, lineWidth: 1))
        .onAppear { focused = true }
    }

    /// Grows out of the physical notch: starts as a notch-sized black pill and springs open.
    private var notch: some View {
        let theme = themes.current
        let expanded = model.notchExpanded
        let w = expanded ? Self.size.width : model.notch.width
        let h = expanded ? Self.size.height : model.notch.height
        let r: CGFloat = expanded ? 34 : 10
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0), style: .continuous)

        return ZStack(alignment: .top) {
            ZStack {
                GlassBackground(theme: theme, isDark: true, isActive: expanded)
                Color.black.opacity(0.80)          // blend with the physical notch
                content
                    .padding(.top, model.notch.height)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.92, anchor: .top)
                    .animation(.easeOut(duration: 0.22).delay(expanded ? 0.10 : 0), value: expanded)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .frame(width: w, height: h, alignment: .top)
            .clipShape(shape)
            .overlay(shape.stroke(.white.opacity(expanded ? 0.12 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 24, y: 10)
            .animation(.spring(response: 0.46, dampingFraction: 0.78), value: expanded)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    /// Light catches the top-left edge; the opposite edge fades out.
    private var rimGradient: LinearGradient {
        LinearGradient(
            colors: isDark ? [.white.opacity(0.38), .white.opacity(0.06), .white.opacity(0.14)]
                           : [.white.opacity(0.95), .black.opacity(0.05), .black.opacity(0.10)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Shared content

    private var content: some View {
        VStack(spacing: 0) {
            searchField
            hairline
            ZStack {
                switch model.mode {
                case .ai:
                    aiPane.transition(paneTransition)
                case .convert:
                    RadialConversionView(
                        files: model.convertFiles, conversions: model.conversions,
                        states: model.conversionStates, selection: model.conversionSelection,
                        onSelect: { model.conversionSelection = $0 },
                        onRun: { model.runConversion($0) })
                        .transition(paneTransition)
                case .search:
                    resultList.transition(paneTransition)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.smooth(duration: 0.28), value: model.mode)
            hairline
            footer
        }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.tab) { model.moveSelection(1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private var paneTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).combined(with: .offset(y: 6)),
                    removal: .opacity)
    }

    private var hairline: some View {
        Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
    }

    private var placeholder: String {
        model.mode == .convert ? "Pick a conversion, or type to search" : "Search, calculate, or type ? to ask Aether"
    }

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: model.mode == .ai ? "sparkles" : model.mode == .convert ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .light, design: .rounded))
                .focused($focused)
                .onSubmit { model.submit(dismiss: onDismiss) }
            ProgressView().controlSize(.small)
                .opacity(model.isStreaming ? 1 : 0)
                .scaleEffect(model.isStreaming ? 1 : 0.6)
                .animation(.snappy(duration: 0.2), value: model.isStreaming)
            micButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var micButton: some View {
        let on = model.voice.isListening
        return Button { model.toggleVoice() } label: {
            Image(systemName: on ? "mic.fill" : "mic")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.primary.opacity(on ? 0.16 : 0.06)))
                .overlay(Circle().strokeBorder(.primary.opacity(on ? 0.4 : 0), lineWidth: 1))
                .symbolEffect(.pulse, isActive: on)
                .scaleEffect(on ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: on)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: .command)
        .help("Voice input (⌘D)")
    }

    // MARK: Search results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, item in
                        row(item, selected: i == model.selection)
                            .id(item.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                            .onTapGesture { model.selection = i; model.submit(dismiss: onDismiss) }
                            .onContinuousHover { phase in
                                if case .active = phase, model.selection != i { model.selection = i }
                            }
                    }
                }
                .padding(10)
                .animation(.smooth(duration: 0.22), value: model.results.map(\.id))
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selection) { _, new in
                if model.results.indices.contains(new) {
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(model.results[new].id) }
                }
            }
        }
    }

    private func row(_ item: SearchItem, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 30)
                .background(.primary.opacity(selected ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.primary.opacity(selected ? 1 : 0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            if selected {
                // One pill that glides between rows instead of fading in and out.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(isDark ? 0.10 : 0.07))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(isDark ? 0.14 : 0.10), lineWidth: 0.5))
                    .matchedGeometryEffect(id: "selection", in: selectionNS)
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
    }

    // MARK: AI

    private var aiPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.toolLog, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                    if let err = model.errorMessage {
                        Text(err).foregroundStyle(.red).font(.system(size: 13))
                    }
                    if model.aiText.isEmpty && model.isStreaming {
                        Text("Thinking")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .phaseAnimator([0.35, 1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
                    } else {
                        Text(model.aiText)
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .animation(.smooth(duration: 0.2), value: model.toolLog)
            }
            .scrollIndicators(.hidden)

            if let p = model.pendingApproval {
                HStack {
                    Text(p.summary).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Deny") { model.resolveApproval(false) }
                    Button("Allow") { model.resolveApproval(true) }
                        .buttonStyle(.borderedProminent).tint(.primary)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 14).padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.pendingApproval?.tool)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if model.mode == .convert, let status = model.conversionStatus {
                Label(status, systemImage: "checkmark.circle")
                    .lineLimit(1)
                    .transition(.opacity)
                if !model.lastOutputs.isEmpty {
                    Button("Reveal") { model.revealLastOutput() }
                        .buttonStyle(.plain).foregroundStyle(.primary)
                }
            } else if model.voice.isListening {
                Label("Listening… pause to send", systemImage: "waveform")
                    .transition(.opacity)
            } else if let err = model.voice.error {
                Label(err, systemImage: "mic.slash").lineLimit(1)
            } else {
                Label(model.context.appName ?? "No app", systemImage: "scope")
                if model.context.selectedText != nil {
                    Label("Selection attached", systemImage: "text.cursor")
                }
                if !SystemContextFetcher.isTrusted {
                    Label("Grant Accessibility for context", systemImage: "exclamationmark.triangle")
                }
            }
            Spacer()
            Text(model.mode == .convert ? "↑↓ choose  ↩ convert  esc" : "↑↓  ↩  esc")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.vertical, 10)
        .animation(.smooth(duration: 0.2), value: model.conversionStatus)
        .animation(.smooth(duration: 0.2), value: model.voice.isListening)
    }
}
