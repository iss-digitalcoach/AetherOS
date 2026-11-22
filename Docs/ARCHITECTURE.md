# AetherOS — Architecture & Implementation Plan

Swift 6 (strict concurrency), SwiftUI + AppKit, Metal, macOS 14+. Apple Silicon first.

## 1. Reality check (what the platform allows)

| Wish | What's actually possible | Plan |
|---|---|---|
| "Replace" native floating windows with a Metal overlay | Third-party apps can't restyle other apps' windows. SIP blocks injection. | Own every surface *we* draw (HUD, widgets, bar replacement). Don't touch foreign windows except via AX (move/resize). |
| Hide/restyle native menu bar and Dock | Menu bar auto-hide is a user setting; Dock auto-hide via `defaults`/`com.apple.dock`. No API restyles them. | Offer a one-click "auto-hide" toggle (guided; the user changes the System Settings option or approves a `defaults write` + `killall Dock`). Draw **our own** bar (a borderless `NSPanel` at `.statusBar` level on each screen) with widgets. Same approach as SketchyBar/Ice. |
| Metal frosted glass over the desktop | Metal can't sample other apps' pixels without ScreenCaptureKit (needs Screen Recording permission). | Use compositor blur (`NSVisualEffectView`, `.behindWindow`) for the backdrop and **layer our Metal shader on top** (tint, grain, cursor-following specular, rim glow). Optional later: ScreenCaptureKit + MPS Gaussian for fully custom blur. |
| "Sub-millisecond search" | Achievable in-memory for ~10⁴–10⁵ entries. | Pre-lowercased UTF-8 key arrays + allocation-free scoring (implemented). Files via Spotlight (`NSMetadataQuery`) feeding the index. |
| "Neural Engine" | Core ML can target the ANE; MPS/MLX run on the GPU. MLX does not use the ANE. | Embeddings: Core ML sentence model (ANE) *or* MLX (GPU). Chat: Ollama/MLX. Don't promise ANE for LLM decoding. |
| System command execution by an LLM | Highest-risk feature. | Tool allow-list, home-directory sandbox, per-call user approval for anything mutating (implemented). |

## 2. Layers (Clean Architecture + MVVM)

```
Presentation   HUDView, ThemeEngine-driven styling        SwiftUI, @Observable view models (@MainActor)
Application    HUDViewModel, use cases (search, ask, snap) orchestration; no UI types leak down
Domain         SearchItem, SystemContext, Theme, AgentTool, AgentEvent   plain Sendable values / protocols
Infrastructure SearchIndex(actor), LocalAIAgentService(actor), SystemContextFetcher (AX),
               WindowManager (AX), HotkeyManager (Carbon), GlassRenderer (Metal), VectorStore (actor, planned)
```

Concurrency rules: UI + AX + AppKit on `@MainActor`; indexes, network, and vector store are **actors**; everything crossing boundaries is `Sendable`; streaming uses `AsyncThrowingStream` with `onTermination` cancelling the underlying task (so Esc cancels the HTTP request).

## 3. Module map (this repo)

| File | Responsibility |
|---|---|
| `App/AetherOSApp.swift` | `@main`, `.accessory` activation policy, MenuBarExtra, Carbon `⌥Space` hotkey |
| `HUD/HUDPanel.swift` | `NSPanel` (`.nonactivatingPanel`, borderless, all-spaces, key-capable) + `HUDController` (capture context → position → fade in; auto-hide on resign key) |
| `Glass/GlassRenderer.swift` | `NSVisualEffectView` blur + `MTKView` pipeline compiled from embedded MSL; uniforms driven by `Theme`; cursor-eased specular trail, orbiting rim sheen, animated grain, accent glow; premultiplied alpha |
| `Theme/ThemeEngine.swift` | JSON themes in `~/Library/Application Support/AetherOS/Themes`, `DispatchSource` watcher → instant hot-swap |
| `Search/SearchIndex.swift` | Actor; fuzzy subsequence scorer; apps + built-in commands |
| `Windows/WindowManager.swift` | AX window snapping (halves, maximize, center) with coordinate-space conversion |
| `AI/LocalAIAgentService.swift` | Ollama `/api/chat` NDJSON streaming, context injection, bounded tool loop, approval gate |
| `AI/AgentTools.swift` | `AgentTool` protocol; `list_directory`, `read_text_file`, `rename_item` (confirm) in a home-dir `PathGuard` |
| `Context/SystemContextFetcher.swift` | AXUIElement: focused window title/document, selected text, focused-field value (secure fields skipped), 250 ms AX timeout |
| `HUD/HUDViewModel.swift`, `HUDView.swift` | State machine (search ↔ AI), keyboard navigation, approval UI |

## 4. Key flows

**Summon:** hotkey → `HUDController.show()` → `SystemContextFetcher.capture()` (the panel is non-activating, so the previous app is still frontmost and its selection is intact) → panel ordered front, key → `HUDViewModel.begin(with:)`.

**Ask AI:** `?question` or "Ask Aether" → `LocalAIAgentService.respond` → system prompt + `<system_context>` block → stream tokens → if the model emits `tool_calls`: look up tool → approval (if mutating) → run → append `tool` message → loop (max 4 rounds).

**Theme hot-swap:** edit JSON → directory watcher fires → decode → `ThemeEngine.current` changes → SwiftUI + shader uniforms update next frame.

## 5. Theme JSON

```json
{
  "name": "Aether Night",
  "accent": "#7C9CFF", "tintColor": "#0B0E18", "tintOpacity": 0.38,
  "glowColor": "#6F86FF", "glowIntensity": 0.6,
  "grain": 0.05, "specular": 0.8, "cornerRadius": 22
}
```
Custom shaders (planned): theme may reference a `.metal` file; the renderer compiles it with `makeLibrary(source:)` and falls back to the built-in on error.

## 6. Roadmap (not yet implemented)

1. **Own menu bar replacement** — per-screen `NSPanel` at `.statusBar` level; widgets (CPU/RAM via `host_statistics`, active model status from `/api/ps`, micro-notepad). Auto-hide native bar by guided setting.
2. **Files & clipboard search** — `NSMetadataQuery` → index; clipboard history (poll `NSPasteboard.changeCount`, exclude concealed/transient types, encrypted at rest).
3. **Local RAG** — `FSEvents` watcher → chunker (≈512 tokens, overlap) → embeddings (Core ML/ANE or MLX) → vectors in an actor-owned store (flat Float16 matrix, cosine via `MPSMatrixMultiplication`/Accelerate; SQLite for metadata). Brute force is fine up to ~10⁵ chunks; add HNSW beyond that. Expose as a `search_documents` tool.
4. **Script Kit** — `~/Library/Application Support/AetherOS/Scripts`, header comments declare name/args/UI; run through `Process` with a scrubbed environment, stdout JSON protocol rendered as SwiftUI components.
5. **Embedded inference** — `mlx-swift` backend behind the same `Transport` seam as Ollama.
6. **Packaging** — Xcode app target, hardened runtime, notarization; Accessibility usage description; sandbox **off** (AX + arbitrary file access are incompatible with App Sandbox), so distribute outside the Mac App Store.

## 7. Security & privacy

- All inference local; the only network endpoint is `localhost`.
- Accessibility is requested explicitly, secure text fields are never read, context is truncated to 8 KB and shown in the footer ("Selection attached").
- Tools: allow-list, home-directory sandbox with symlink resolution, no shell tool by default; mutating tools require per-call approval and refuse to overwrite.
- Prompt-injection: file contents and selected text are *data*. Mutating actions always go through the user-facing approval regardless of what the model says.

## 8. Performance

- HUD is created once; show/hide only toggles ordering and `isPaused` on the `MTKView` (no GPU work while hidden — wire `isActive` to visibility in the next iteration).
- Search runs off-main in an actor; each keystroke cancels the previous task.
- Shader is a single fullscreen triangle, no texture fetches; cost is negligible on any M-series GPU.

## 9. Build & run

```bash
swift build && .build/debug/AetherOS      # menu-bar app; ⌥Space opens the HUD
ollama pull qwen2.5:7b && ollama serve    # for the AI features
```
Grant Accessibility to the binary/terminal when prompted to enable selection capture and window snapping.

## 10. Update: settings, notch HUD, conversion ring, productivity

- **Settings** (`Settings/`): model picker fed by Ollama `/api/tags`, server URL, temperature, theme + appearance override, which HUD `⌥Space` opens, tool toggles, permission shortcuts. Stored in `UserDefaults`; `Services` is the shared composition root.
- **Two HUDs**: `⌥Space` = style chosen in Settings (Classic by default), `⌥⇧Space` = the other. The Notch HUD is a full-size transparent panel flush with the top screen edge; SwiftUI animates a clip shape from the physical notch size (`NSScreen.safeAreaInsets`/`auxiliaryTop*Area`) to the full card. It is always dark to blend with the notch.
- **Conversion ring** (`Convert/`): the Finder selection is read via AppleScript when the HUD opens; options come from `ConversionCatalog` (sips, textutil, afconvert, zip, AVFoundation, PDFKit — all built in). Outputs never overwrite.
- **Productivity** (`Search/QueryRouter.swift`, `Productivity/`): calculator, unit conversion, clipboard history (memory only, skips concealed/transient items), `f` file search (mdfind), `note`, `timer`, `g` web search, quit-running-app, window layouts, sleep display, dark-mode toggle, keep-awake.
- Build note: with only the Command Line Tools installed, SwiftUI's `@State` macro plugin is unavailable, so view-local state uses `@StateObject`.

## 11. Update: optimizer, universal build

- **Optimizer** (`Optimizer/`): five independent tools sharing `Disk` helpers. Safety rules live in code, not UI: all paths must resolve inside the home folder; `Disk.moveToTrash` is the only delete except `CacheCleaner`, which may only empty children of an allow-listed set of roots (`~/Library/Caches`, `~/Library/Logs`, Xcode DerivedData, `~/.npm/_cacache`, `~/.Trash`) and rechecks the resolved path first. Organizer logs each move to JSON for undo. Apple apps (`com.apple.*`) and AetherOS itself are never listed for removal. Scans run in detached tasks and return `Sendable` values; every destructive action goes through a confirmation dialog.
- **Battery**: `pmset -g batt` (status), `system_profiler SPPowerDataType` (health), `ps` rolled up per `.app` (CPU hogs).
- **Efficiency**: the glass shader is paused while the launcher is hidden; eco mode halves its frame rate; frecency (launch counts) ranks results.
- **Build**: `scripts/build-app.sh` compiles arm64 and x86_64 separately (they share an output folder, so each binary is copied out), merges with `lipo`, signs with a bundle-id designated requirement so TCC approvals survive rebuilds, and emits universal, Intel-only and Apple-Silicon-only archives.
