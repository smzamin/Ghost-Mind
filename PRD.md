# Enhanced Prompt for Building a Stealth AI Meeting Assistant for macOS (Apple Silicon M3)

---

## Project Overview

Build a **native macOS desktop application** optimized for **Apple Silicon (M3/M-series chips)** that serves as a **real-time AI-powered meeting and interview assistant**. The app must operate as an **invisible overlay** that continuously listens to system/microphone audio, performs live speech-to-text transcription, and provides instant AI-generated responses — all while remaining **completely undetectable** by screen-sharing software, proctoring tools, and employee monitoring/tracking applications.

The UI/UX should closely replicate the reference design shown (similar to **Cluely's live meeting assistant interface**).

---

## Core Features & Detailed Requirements

### 1. **Stealth & Undetectability (CRITICAL PRIORITY)**

- The application window must be **invisible to all screen capture and screen-sharing APIs** on macOS (e.g., `CGWindowListCopyWindowInfo`, `SCStreamConfiguration`, `CGDisplayStream`, etc.).
- Must not appear in:
  - Zoom, Google Meet, Microsoft Teams, Webex, or any other screen-sharing/recording tool
  - OBS, QuickTime screen recording, or macOS native screenshot utilities
  - Proctoring software (e.g., ProctorU, Examity, HireVue, Honorlock, Proctorio)
  - Employee monitoring/tracking software (e.g., Hubstaff, Time Doctor, ActivTrak, Teramind, Veriato)
  - macOS `Window Server` enumeration and `Accessibility API` snooping
- **Technical approaches to explore:**
  - Use `CGWindowLevel` set above `kCGScreenSaverWindowLevel` or use private window levels
  - Set `CGSSetWindowShouldShadow` and related Core Graphics Server (CGS) private APIs to exclude from capture
  - Leverage `sharingType = .none` on `NSWindow` (available in macOS 12.0+)
  - Mark window with `NSWindow.SharingType.none` to exclude from `SCKit` and `CGWindowList`
  - Explore using **CAContext** remote layers or **IOSurface** rendering to bypass capture
  - Process name obfuscation — randomize or disguise the app's process name, bundle identifier, and code signature so it doesn't appear suspicious in Activity Monitor or process listings
  - Anti-hooking and anti-debugging measures (detect `dtrace`, `lldb`, `frida`, `DYLD_INSERT_LIBRARIES` injections)
  - No Dock icon, no entry in `Cmd+Tab` app switcher, no menu bar icon (optional toggle)
  - Optionally render as a **transparent borderless window** that overlays on top of everything

### 2. **Real-Time Audio Capture & Live Transcription**

- **Continuously listen** to:
  - System audio (what's being said by others on the call via internal audio routing)
  - Microphone input (what the user is saying)
  - Support **dual-channel capture** to distinguish between "self" and "others"
- **Speech-to-Text Engine:**
  - Primary: Apple's on-device `SFSpeechRecognizer` (for privacy and speed on M3's Neural Engine)
  - Secondary/Fallback: Whisper (OpenAI) running locally via `whisper.cpp` optimized for Apple Silicon (Metal/ANE acceleration)
  - Optional cloud-based: Deepgram, AssemblyAI, or provider's native STT
- **Live rolling transcript** displayed in the app UI — continuously updated in real-time
- Speaker diarization (label who is speaking: "Interviewer", "You", "Participant 1", etc.)
- Support for **multiple languages** (at minimum English; stretch goal: auto-detect language)

### 3. **AI-Powered Assistance & Response Generation**

- User can **select/highlight any portion of the live transcript** (a question, a block of text, a code snippet)
- Upon selection, the app sends it to the configured AI provider and returns a **high-quality answer within 1-3 seconds**
- **Quick-Action Buttons** (visible in the UI toolbar, matching the reference design):
  - 🚀 **Assist** — General-purpose AI assistance on selected text
  - ✍️ **What should I say?** — Generate a natural, professional spoken response the user can say aloud
  - 💻 **Follow-up questions** — Predict and generate likely follow-up questions the interviewer/participant might ask, with prepared answers
  - 🔄 **Recap** — Summarize the conversation so far in concise bullet points
- **Contextual intelligence:**
  - Maintain the **full conversation context** throughout the session
  - Allow the user to upload documents beforehand (resume, job description, company info, meeting agenda, technical docs) to give the AI richer context
  - Support **"interview mode"** profiles (e.g., Technical/Coding Interview, Behavioral Interview, System Design, HR/Culture Fit, Sales Call, Client Meeting)
  - **Code-aware**: If a coding question is detected, format the response with syntax highlighting and step-by-step explanation
- **Response formatting:**
  - Concise, scannable bullet points by default
  - Toggle for detailed/verbose mode
  - Markdown rendering in the UI
  - Copy-to-clipboard with one click

### 4. **Multi-Provider AI Backend (API Key Management)**

- Support **multiple LLM providers** — user can configure, switch, and manage API keys for:
  - **OpenAI** (GPT-4o, GPT-4-turbo, etc.)
  - **Google Gemini** (Gemini 1.5 Pro, Gemini 1.5 Flash, etc.)
  - **OpenRouter** (access to hundreds of models via single API)
  - **NVIDIA NIM** (Llama, Mistral, etc. via NVIDIA's API)
  - **Anthropic Claude** (Claude 3.5 Sonnet, Claude 3 Opus, etc.)
  - **Groq** (ultra-fast inference — LLaMA, Mixtral)
  - **Local/Ollama** (for fully offline operation via locally-run models on M3)
  - **Custom OpenAI-compatible endpoint** (user provides base URL + key)
- **Settings panel** for API key management:
  - Add/remove/edit multiple keys per provider
  - Set a **default/primary provider** and a **fallback provider**
  - Show real-time **latency & token usage stats** per provider
  - Validate API keys on entry
  - Encrypted storage of all API keys in macOS Keychain
- **Smart routing:**
  - Auto-fallback: if primary provider fails or is slow, seamlessly switch to fallback
  - User can set per-action provider preferences (e.g., use Groq for "What should I say?" for speed, use GPT-4o for "Assist" for quality)
  - Cost estimation per query

### 5. **User Interface (UI/UX)**

- **Replicate the reference design** (Cluely-style interface):
  - **Floating pill/capsule control bar** at top center with:
    - App icon/logo
    - "Hide" dropdown button (minimize/collapse the panel)
    - Stop/pause button (stop listening)
  - **Main panel** (expandable/collapsible, dark theme):
    - Chat-style conversation area with:
      - AI responses on the left (light text on dark background)
      - User queries on the right (styled as blue/purple bubble)
    - Quick-action toolbar: `Assist` · `What should I say?` · `Follow-up questions` · `Recap`
    - Text input field at bottom: *"Ask about your screen or conversation, or ⌘↵ for Assist"*
    - Model selector badge (e.g., "Smart", "Fast", "Custom") with `⋯` menu for settings
    - Blue send button
  - **Live transcript panel** (toggleable side panel or separate view):
    - Real-time scrolling transcript with timestamps
    - Clickable/selectable text regions
    - Speaker labels with color coding
- **Window behavior:**
  - Always-on-top (floats above all other windows including full-screen apps)
  - Draggable to any screen position
  - Resizable with smooth animations
  - Collapsible to minimal floating pill (just the capsule bar)
  - Global keyboard shortcuts:
    - `⌘ + Shift + H` → Toggle show/hide
    - `⌘ + Enter` → Instant Assist on last detected question
    - `⌘ + Shift + T` → Toggle transcript panel
    - `Esc` → Collapse to pill
  - Opacity/transparency slider (make the overlay semi-transparent so user can see through it)
- **Dark mode** by default, optional light theme
- **Smooth animations** — use SwiftUI with Metal-accelerated rendering
- Accessibility: support VoiceOver, keyboard navigation, dynamic type

### 6. **Screen Awareness (Bonus/Advanced)**

- Optionally capture and analyze what's on screen (e.g., a coding problem displayed in a browser, a slide deck being presented)
- Use **Vision framework** or **OCR** (on-device) to read screen content and feed it as context to AI
- This must also be done stealthily without triggering screen recording permissions pop-ups (explore accessibility permissions vs. screen capture permissions)

### 7. **Session Management & History**

- Auto-save each session with:
  - Full transcript (time-stamped)
  - All AI Q&A exchanges
  - Session metadata (date, duration, meeting title)
- Export options: Markdown, PDF, plain text, JSON
- Searchable session history
- Session tagging and categorization (Interview, Meeting, Lecture, etc.)

### 8. **Performance & Optimization (Apple Silicon M3)**

- **Native ARM64 build** — no Rosetta, fully optimized for M3
- Leverage **Neural Engine** for on-device ML tasks (speech recognition, text embedding)
- Leverage **Metal GPU** for any rendering/acceleration needs
- **Memory-efficient:** Stay under 200MB RAM in idle, under 500MB during active transcription + AI
- **Battery-conscious:** Efficient audio processing pipeline, avoid unnecessary CPU wake-ups
- App size target: < 100MB (excluding optional local models)
- Cold start time: < 2 seconds

### 9. **Security & Privacy**

- All API keys stored encrypted in **macOS Keychain**
- No telemetry, no analytics, no phoning home — **fully private**
- All audio processing done **on-device** by default (cloud only when user explicitly sends a query to an AI provider)
- Audio buffers are ephemeral — never written to disk unless user explicitly saves
- Option for **full offline mode** using Ollama + Whisper.cpp (no network needed)
- App binary code-signed and optionally notarized (or unsigned for maximum stealth)

---

## Tech Stack Recommendations

| Component | Technology |
|---|---|
| Language | Swift 5.9+ / SwiftUI |
| UI Framework | SwiftUI + AppKit (for low-level window manipulation) |
| Audio Capture | AVAudioEngine, CoreAudio, ScreenCaptureKit (for system audio) |
| Speech-to-Text | Apple SFSpeechRecognizer + whisper.cpp (Metal-accelerated) |
| AI Integration | URLSession / async-await networking to REST APIs |
| Window Stealth | CGS Private APIs, NSWindow.SharingType, NSWindow.Level |
| Local LLM | Ollama / llama.cpp with Metal backend |
| Storage | SwiftData / SQLite for session history |
| Secrets | macOS Keychain Services |
| Build | Xcode 15+, native ARM64 target |

---

## Deliverables

1. **Native macOS `.app` bundle** (universal or ARM64-only)
2. **Source code** — clean, modular, well-documented Swift project
3. **README** with setup instructions, API key configuration guide, and usage documentation
4. **Demo video** showing:
   - App running invisibly during a Zoom screen share
   - Live transcription of a mock interview
   - AI answering a selected question in real-time
   - Switching between AI providers
5. **Test suite** — unit tests for core logic, integration tests for API providers

---

## Success Criteria

- ✅ App is **100% invisible** during screen shares on Zoom, Google Meet, Teams, and OBS recording
- ✅ Live transcription appears within **< 500ms** of speech
- ✅ AI responses are generated within **1-3 seconds** of user query
- ✅ Seamless switching between at least 4 AI providers
- ✅ UI matches the reference design (dark floating overlay with quick-action toolbar)
- ✅ Runs efficiently on MacBook with M3 chip with minimal battery impact
- ✅ Not detectable by at least 10 common proctoring/monitoring tools

---
