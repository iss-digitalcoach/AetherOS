# AetherOS — User Guide

A launcher, local AI assistant and window/file toolkit for macOS. The AI model, speech recognition, clipboard history and conversions all run on your Mac. The one thing that goes online is AI web search, which you can switch off (see 3.7).

Requires macOS 14 or newer. Runs on Apple Silicon and Intel Macs. No admin rights or `sudo` needed for anything below.

---

## Install a downloaded build

**1. Which file?** Check your chip: Apple menu  → **About This Mac**. It says "Apple M1/M2/M3/M4…" (Apple Silicon) or "Intel".

| Your Mac | Download |
|---|---|
| Apple Silicon (M1 or newer) | `AetherOS-…-AppleSilicon.zip`, or the universal `.dmg` |
| Intel | `AetherOS-…-Intel.zip`, or the universal `.dmg` |
| Not sure | The universal `.dmg` works on both |

**2. Install (no admin password needed).**
1. Open the `.dmg` and drag **AetherOS** into your **Applications** folder, or into `~/Applications` if you don't have admin rights. For a zip, unzip it and drag the app there.
2. The first time, macOS may say it can't verify the app (builds that aren't notarized by Apple). Right-click AetherOS → **Open** → **Open**. If that still refuses, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine ~/Applications/AetherOS.app
```

(use `/Applications/AetherOS.app` if you installed it there).

3. Press **⌥ Space**. Then open ✦ in the menu bar → **Settings… → Tools** and click **Allow…** for each permission you want.
4. For the AI, install Ollama and a model (section 1.2 below).

Requires macOS 14 or newer.

## 1. Set up (building from source)

### 1.1 Build and run

```bash
cd ~/Desktop/TheFinalMacOS
swift build -c release
.build/release/AetherOS
```

A ✦ icon appears in the menu bar. Keep that Terminal window open: closing it quits AetherOS. Press **⌥ Space** to open the launcher.

To rebuild after changing code, quit AetherOS (✦ → Quit) and run the two commands above again.

### 1.1b Build the app for your website

```bash
INSTALL=1 scripts/build-app.sh
```

Builds `AetherOS.app` and copies it to `~/Applications`. Everything lands in `dist.noindex/`:

| File | For |
|---|---|
| `AetherOS-1.0.0.dmg` | The download to put on your site: one app that runs on **both** Apple Silicon and Intel |
| `AetherOS-1.0.0.zip` | Same universal app as a zip |
| `AetherOS-1.0.0-Intel.zip` | Smaller Intel-only build |
| `AetherOS-1.0.0-AppleSilicon.zip` | Smaller Apple-Silicon-only build |

Signing for public release (so Gatekeeper doesn't warn) needs an Apple Developer ID; see the comments at the top of the script. Change `BUNDLE_ID` first.

**Intel Macs:** everything works. The AI runs on the CPU there, so it is slower. Use a small model such as `qwen2.5:3b`, and expect the first answer to take longer.

### 1.2 Install Ollama (only needed for AI)

1. Download the Mac app from ollama.com/download (a zip, no installer).
2. Unzip it and drag `Ollama.app` into `~/Applications` (create the folder if needed).
3. Open it. If it offers to install the command-line tool, skip it; it may need admin rights and you don't need it.
4. Download a model in Terminal:

```bash
~/Applications/Ollama.app/Contents/Resources/ollama pull qwen2.5:7b
```

About 4–5 GB; needs roughly 8 GB of RAM. On smaller Macs use `qwen2.5:3b`. Then pick it in **Settings → AI**.

### 1.3 Permissions (all optional)

| Permission | Enables | Where |
|---|---|---|
| Accessibility | Selected-text context for the AI, window snapping | System Settings → Privacy & Security → Accessibility → switch on Terminal |
| Automation → Finder | Reading your Finder selection for the conversion ring | macOS asks the first time you open the launcher with Finder in front |
| Microphone + Speech Recognition | Voice input | Asked on first use of the mic button |
| Automation → System Events | The "Toggle Dark Mode" command | Asked on first use |

macOS may ask for a password or Touch ID to change Accessibility. If your account isn't an admin, skip it: search, launching, the AI and conversions all still work.

After granting Accessibility, quit and restart AetherOS.

---

## 2. The two launchers

| Shortcut | Opens |
|---|---|
| **⌥ Space** | The launcher style chosen in Settings (Classic by default) |
| **⌥ ⇧ Space** | The other style |

- **Classic** — a frosted glass card in the middle of the screen. Follows your system Light/Dark setting.
- **Notch** — grows out of the camera notch at the top of the screen (on Macs without a notch, out of the top-centre edge). Always dark so it blends with the notch.

Swap which one ⌥ Space opens in **Settings → Appearance → Launcher**. You can also open either from the ✦ menu.

**Keys:** ↑ ↓ (or Tab) move · Return runs · Esc closes. Mouse hover and click also work. Clicking elsewhere closes the launcher.

---

## 3. Features

### 3.1 Search and launch
Type to fuzzy-search installed apps and built-in commands. Typing "saf" finds Safari. Apps are read from `/Applications`, `/System/Applications` and `~/Applications`.

### 3.2 Calculator and unit conversion
Type an expression: `2+2*3`, `(1+2)^3/4`, `17 % 5`. Operators: `+ - * / ^ %` (`%` is remainder, not percent) and parentheses. Press Return to copy the result.

Units: `10 km to mi`, `72 f in c`, `5 gb to mb`, `3 lb to kg`. Supported: length, mass, temperature, volume, speed, data size, time.

### 3.3 Search prefixes

| Type | What happens |
|---|---|
| `clip` / `clip text` | Clipboard history. Return copies the entry back. |
| `f name` | Find files in your home folder (Spotlight). Return opens. |
| `note text` | Appends a timestamped line to your notes file. "Open Notes File" opens it. |
| `timer 10m` / `timer 90s tea` / `timer 1h` | Notification and sound when it ends. |
| `g query` | Web search in your default browser (DuckDuckGo). |
| `? question` | Ask the AI. |

Any normal search also offers "Search the web" and "Ask Aether" at the bottom of the list.

**Clipboard history privacy:** kept in memory only (never written to disk), last 100 text items, cleared when you quit. Items that password managers mark as secret or temporary are skipped. Turn it off in Settings → Tools.

### 3.4 Window management
Open the launcher, type a command, press Return. Apps and commands you use most rise to the top over time. The window you were using is the one that moves.

Left/Right/Top/Bottom Half · four Quarters · Left/Center/Right Third · Maximize · Center. Needs Accessibility.

### 3.5 System commands
Sleep Display · Toggle Dark Mode · Keep Mac Awake (toggle; uses the built-in `caffeinate`) · Quit any running app ("Quit Safari").

### 3.6 File conversion ring
1. Select one or more files in Finder (or on the Desktop).
2. Press **⌥ Space**.
3. The file appears in the centre with its available conversions around it. Click one, or use ↑ ↓ and Return.
4. The button shows a spinner, then a check mark. The footer shows the saved file name and a **Reveal** button.

Results are saved next to the original. Existing files are never overwritten (`Photo.png`, then `Photo 2.png`, …). Typing anything switches back to normal search.

| Input | Offered conversions |
|---|---|
| Images | PNG, JPG, HEIC, TIFF, GIF, PDF, compressed JPG |
| PDF | First page → PNG, extract text → TXT |
| Documents (txt, rtf, html, doc, docx, odt, md) | TXT, RTF, HTML, DOCX |
| Audio | M4A, WAV, AIFF, CAF |
| Video | MP4 1080p, MP4 720p, MOV, extract audio (M4A) |
| Anything | ZIP, Copy path |

Uses only tools built into macOS (sips, textutil, afconvert, zip, AVFoundation, PDFKit). Turn the ring off in Settings → Tools. Video export can take a while for long files; the button keeps spinning until it finishes.

### 3.7 Local AI

**Ask:** type `? your question`, or choose "Ask Aether". Answers stream in. Highlight text in any app first and it is included as context ("Selection attached" appears in the footer). Needs Accessibility.

**Web search and reading pages:** the AI can search the web (DuckDuckGo) and read pages it finds. Try `? what are the premier league results today` or `? find the latest news on …`. Only the search terms and the page requests leave your Mac, never your files. Opening a link from a search result happens automatically; if the model wants to open any other address you get an Allow/Deny prompt, and addresses on your own network are always refused. Switch it off in Settings → Tools. Pages that load their content with JavaScript (some live scoreboards) may return little text.

**What the AI can do with files today:**

| Tool | Action | Asks for approval |
|---|---|---|
| list_directory | List a folder | No |
| read_text_file | Read up to 20 KB of a text file | No |
| rename_item | Rename or move a file; refuses to overwrite | **Yes** — Allow/Deny bar |

Examples: `? list the files in ~/Documents` · `? read ~/Desktop/todo.txt and summarise it` · `? rename ~/Documents/a.txt to ~/Documents/b.txt`.

All file access is limited to your home folder (symlinks resolved). The AI cannot run shell commands or delete files.

**Tips:** the model must support tool calling (qwen2.5 does). Models of 7B and up pick tools much more reliably than 3B. If the AI says it can't reach the model server, open Ollama.app.

### 3.8 Voice input
Click the microphone button in the search bar, or press **⌘ D**. Speak, and your words appear in the box live. Pause for about a second and a half and, if "Voice: ask the AI automatically" is on (Settings → Tools), the question goes straight to the AI. Press ⌘ D again to stop without sending, then edit the text or press Return.

Transcription is forced on-device, so audio never leaves your Mac. If your language doesn't support on-device dictation, the mic shows a message instead of falling back to Apple's servers; enable Dictation in System Settings → Keyboard. The first use asks for Microphone and Speech Recognition permission (for your terminal app).

### 3.9 Themes and appearance
Themes are JSON files in `~/Library/Application Support/AetherOS/Themes` (✦ → Open Themes Folder). Edits apply instantly; new files appear in **Settings → Appearance → Theme**.

```json
{
  "name": "My Theme",
  "cornerRadius": 26,
  "dark": {
    "accent": "#FFFFFF", "tintColor": "#0A0A0C", "tintOpacity": 0.30,
    "glowColor": "#FFFFFF", "glowIntensity": 0.35, "grain": 0.05, "specular": 0.9
  },
  "light": {
    "accent": "#000000", "tintColor": "#FFFFFF", "tintOpacity": 0.42,
    "glowColor": "#FFFFFF", "glowIntensity": 0.5, "grain": 0.035, "specular": 0.7
  }
}
```

| Field | Effect |
|---|---|
| `tintColor` / `tintOpacity` | Colour and strength of the glass tint |
| `glowColor` / `glowIntensity` | Edge and top-reflection glow |
| `grain` | Film grain amount |
| `specular` | Strength of the cursor-following highlight |
| `cornerRadius` | Card roundness (Classic) |

Copy `aether-mono.json` as a starting point. A file with a typo is skipped silently. Use **Appearance → System / Light / Dark** to force a look for the Classic launcher.

---

### 3.10 Optimizer
Open it from ✦ → **Optimizer…**, or type "optimizer", "clean", "organize", "large files", "uninstall" or "battery" in the launcher. Nothing is changed until you review a list and confirm, and everything except cache cleaning goes to the Trash so you can undo it.

| Tab | What it does |
|---|---|
| **Organize** | Sorts a folder (Downloads by default) into Images, Documents, Video, Audio, Archives, Installers, Code and more. Shows the plan first. Skips folders, hidden files, partial downloads and files changed in the last two minutes. Never overwrites (a clash becomes `name 2.ext`). **Undo last** puts everything back. |
| **Clean** | Finds regenerable junk: per-app caches in `~/Library/Caches`, app logs, Xcode build files and the npm cache. Apple's own caches are never touched, and apps that are running are skipped. Shows sizes and lets you untick items. "Empty the Trash" is a separate, unticked item because it can't be undone (it needs Full Disk Access to be visible). |
| **Large Files** | Lists big files in Downloads, Desktop, Documents and Movies (slider from 25 MB up, optional "not opened in a year"). Select and **Move to Trash**, or reveal in Finder. |
| **Apps** | Lists third-party apps, least recently used first, with their size plus leftovers (preferences, caches, support files). **Move to Trash** removes the app and its leftovers together. Also lists background items that start at login (`~/Library/LaunchAgents`) with a Remove button. Apple's apps are never listed. Apps you don't own and can't delete without admin rights are marked, and you'd drag them to the Trash yourself. |
| **Battery** | Shows charge, time remaining, health and cycle count; the apps using the most CPU right now with **Quit** / **Force** buttons; an eco-mode switch for AetherOS; and shortcuts to Battery settings and "Sleep display". |

Limits: macOS doesn't let apps turn on Low Power Mode or change brightness without administrator rights, so the Battery tab sends you to System Settings for those. The Optimizer can only touch files inside your home folder (plus apps you own), and can't touch protected system files. The first time it looks inside Downloads, Desktop, Documents or Movies, macOS asks for permission.

## 4. Settings reference

Open from ✦ → Settings…, or type "settings" in the launcher.

- **AI:** model, custom model name, Ollama URL (default `http://localhost:11434`), temperature (lower = more focused).
- **Appearance:** theme, appearance override, which launcher ⌥ Space opens.
- **Tools:** eco mode, launch at login, clipboard history, conversion ring, AI web search, voice auto-send, an Optimizer shortcut, and permission shortcuts.

---

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| ⌥ Space does nothing | Another app owns the shortcut (Spotlight, Raycast, Alfred). Disable theirs. |
| "Can't reach the local model server" | Open Ollama.app; check Settings → AI shows "Connected". |
| Model list is empty | Run the `ollama pull` command in 1.2, then press refresh in Settings. |
| Window snapping / selected text not working | Grant Accessibility (1.3), then restart AetherOS. |
| Conversion ring doesn't appear | Finder must be the frontmost app with files selected; allow Automation → Finder when asked. If you clicked Don't Allow, re-enable it in System Settings → Privacy & Security → Automation. |
| Mic button says it isn't allowed | System Settings → Privacy & Security → Microphone / Speech Recognition → enable your terminal app, then retry. |
| AI says it can't browse | Update to the latest build, make sure "Let the AI search the web" is on, and use a tool-capable model (qwen2.5). |
| AI picks wrong files or tools | Use a larger model; give full paths like `~/Documents/report.txt`. |
| Notch launcher looks off on an external display | It uses a generic pill shape on screens without a notch. |

---

## 6. Limits to know about

- Apps can't restyle other apps' windows, or the system menu bar and Dock. AetherOS draws its own surfaces only.
- The glass blur comes from macOS; the shader adds tint, grain, highlights and glow on top.
- Not built yet: custom menu bar widgets, document search by meaning, a script runner, and AI file creation/editing tools. Optimizer actions aren't available to the AI yet.

Technical design is in [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).
