# Project Instructions
## Purpose and Scope

This document defines the agent contract for a macOS recording app that:

1. Records the screen using official macOS APIs. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)
2. Records the user’s webcam. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)
3. Composites the webcam feed as a picture‑in‑picture overlay at the bottom‑left of the captured screen. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)
4. Records the user’s microphone. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)
5. Records system audio using official Core Audio APIs on recent macOS versions. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

The app must be implemented in Swift, use SwiftUI for UI, and be buildable and runnable from the command line (no Xcode GUI), using the Swift toolchain and `swift build` / `swift run`. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

***

## Architecture Overview

### High‑Level Components

- `RecordingCoordinator`  
  - Orchestrates screen, camera, microphone, and system audio capture.  
  - Owns lifecycle: prepare, start, pause/resume, stop, teardown.  

- `ScreenCaptureService`  
  - Uses the official screen capture APIs to capture screen frames.  
  - Exposes a pixel buffer stream to the compositor.  

- `CameraCaptureService`  
  - Uses the camera capture APIs to acquire webcam frames.  
  - Supports device selection when multiple cameras are available.  

- `AudioCaptureService`  
  - Microphone: captures from the default or user‑selected audio input device.  
  - System audio: captures system output using supported Core Audio mechanisms on modern macOS.  

- `VideoCompositor`  
  - Composites screen frames and webcam overlay into a single video frame buffer.  
  - Enforces layout rules (bottom‑left picture‑in‑picture, margin, size, shape).  

- `Muxer`  
  - Uses an asset writer to mux video and audio into a single container (such as `.mp4` or `.mov`).  

- `SwiftUI Shell`  
  - SwiftUI `App` entry, main window, controls, and live preview.  

***

## Repository and Build Layout

### Directory Structure

- `Package.swift`  
  - Swift Package Manager manifest defining an executable target `Glimpse`.  

- `Sources/Glimpse/`  
  - `MainApp.swift` – SwiftUI app entry point (`@main` using `App`).  
  - `ContentView.swift` – primary UI layout and bindings.  
  - `RecordingCoordinator.swift` – high‑level orchestration and state machine.  
  - `ScreenCaptureService.swift` – screen capture implementation.  
  - `CameraCaptureService.swift` – webcam capture implementation.  
  - `AudioCaptureService.swift` – microphone and system audio capture.  
  - `VideoCompositor.swift` – overlay and compositing logic.  
  - `Muxer.swift` – asset writer and file output logic.  

- `Resources/`  
  - App icon, static assets.  

- `Info.plist`  
  - Contains required privacy keys and configuration.  

### Build and Run (Command Line)

- Build:

  - `swift build` – builds the executable with Swift Package Manager.  

- Run:

  - `swift run Glimpse` – launches the SwiftUI macOS app.  

- Requirements:

  - Xcode (or the standalone Swift toolchain) installed to link against system frameworks.  
  - Minimum macOS version set high enough to support modern screen capture and system audio APIs (for example, macOS 13 or later, and a higher minimum if needed for system audio).  

***

## Permissions and Entitlements

The app must fully comply with macOS privacy and security requirements. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

### Info.plist Privacy Keys

At minimum, include:

- `NSCameraUsageDescription`  
  - Explanation for why webcam access is needed (recording the user’s camera).  

- `NSMicrophoneUsageDescription`  
  - Explanation for why microphone access is needed (capturing narration or voice).  

- `NSScreenCaptureDescription` or equivalent screen recording usage description  
  - Explanation for screen recording.  

- `NSAudioCaptureUsageDescription` (for system audio, on supported macOS versions)  
  - Explanation for capturing system audio output.  

### User Permissions

The app must not attempt to bypass any system permission. Instead, it should:

- On first use of each capability (screen, camera, mic, system audio), trigger the standard permission prompt and then react appropriately to the user’s choice.  
- Detect when permissions are missing and present clear, actionable instructions inside the UI (for example, “Screen recording permission is required. Enable it for this app in System Settings → Privacy & Security → Screen Recording.”).  
- Respect the user’s permission decisions and not repeatedly prompt or nag once access has been denied, aside from explicit user‑initiated retry actions.  

***

## UI Layout (SwiftUI)

### Main Window Structure

1. **Preview Area (Top / Center)**  
   - Shows a live preview of the composite: screen capture with webcam overlay in the bottom‑left corner.  
   - Implemented as a SwiftUI view that bridges to a platform view if needed for efficient video rendering.  

2. **Control Bar (Bottom)**  
   - Core controls:
     - Start Recording  
     - Stop Recording  
     - Optional: Pause / Resume  
   - Status indicators:
     - Current state: `Ready`, `Recording`, `Paused`, `Error`  
     - Elapsed time timer during recording  

3. **Settings Panel (Sidebar or Modal Sheet)**  
   - Output:
     - Output directory / file name pattern  
     - File format (container and codec choices, if configurable)  
   - Video sources:
     - Screen target selection (entire screen, specific display, or specific window if supported)  
     - Camera device selection  
   - Audio sources:
     - Microphone device selection  
     - System audio capture toggle (enabled / disabled)  
     - Gain sliders for microphone and system audio separately  
   - Overlay:
     - Overlay enabled toggle  
     - Overlay size preset (small / medium / large)  

4. **Notifications / Alerts**  
   - Lightweight, non‑modal banners or alerts for events such as:
     - “Recording started”  
     - “Recording stopped – file saved to …”  
     - “System audio capture unavailable – continuing with microphone only.”  

***

## Overlay and Compositing Rules

The overlay behavior is central to the app and must be predictable and stable. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

### Positioning

- The webcam overlay is anchored to the **bottom‑left** corner of the recorded frame.  
- A fixed margin is enforced (for example: 24 px from the left and bottom edges of the output frame).  
- The overlay must remain inside visible bounds even if resolution changes (for instance, if a display configuration changes mid‑recording, the compositor should clamp position).  

### Sizing

- Default overlay width is a fixed fraction of the captured screen width (for example, 20%).  
- Maintain the camera’s native aspect ratio (do not stretch).  
- Enforce minimum and maximum overlay width bounds (example: between 200 px and 400 px).  

### Visual Style

- The overlay should support:
  - Rounded corners  
  - Optional drop shadow  
  - Optional border (subtle, so it does not distract)  
- The overlay must not dim or obscure the entire screen; it is strictly a small picture‑in‑picture.  

### Frame Synchronization

- For each screen frame, choose the most recent webcam frame at or before that timestamp to composite.  
- If the webcam stops delivering frames, the compositor should reuse the last available webcam frame rather than dropping screen frames.  
- If screen capture lags, the compositor should not advance the audio timeline out of sync; all components must align to a shared timebase.  

***

## Audio Capture and Mixing Rules

Audio is captured from both the microphone and the system output, then mixed into the final recording. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

### Microphone Capture

- Capture from the default or user‑selected input device.  
- The UI should surface a basic level meter to indicate that microphone audio is present.  
- Input levels may be adjustable via a simple gain slider in settings.  

### System Audio Capture

- System audio capture uses official APIs that allow capturing the system output stream on supported macOS versions.  
- The app must:
  - Provide a clear toggle to enable or disable system audio capture.  
  - Handle systems or OS versions where system audio capture is not available by disabling the toggle and showing an explanation.  
  - React gracefully when system audio permission is denied, continuing to record mic‑only if possible.  

### Mixing and Output

- Mix microphone and system audio into a single stereo track for the recording.  
- Provide independent gain controls for:
  - Microphone audio  
  - System audio  
- Ensure consistent sample rate and channel layout across all audio sources before writing to the file (for example, upsample or downsample as needed, and convert mono to stereo when mixing).  

***

## Recording Lifecycle and State Machine

The `RecordingCoordinator` is responsible for maintaining a clear state machine. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

### States

- `idle` – no active capture; default state on launch.  
- `preparing` – verifying permissions, configuring sessions, and initializing writers.  
- `ready` – ready to start recording (all components configured).  
- `recording` – actively capturing and writing media.  
- `paused` – optionally, capturing halted while preserving session state.  
- `stopping` – finalizing writers and stopping sessions.  
- `error` – unrecoverable error that prevents recording until reset.  

### Transitions

- `idle` → `preparing` – when the user presses Start.  
- `preparing` → `ready` – once all initializations succeed.  
- `ready` → `recording` – immediately or when output file is fully prepared.  
- `recording` → `paused` – if pause is supported and requested.  
- `paused` → `recording` – on resume.  
- `recording` → `stopping` → `idle` – when the user presses Stop or an unrecoverable error occurs.  
- Any state → `error` – on configuration or runtime failure; the UI must surface error reasons and allow retry.  

### Lifecycle Rules

- Never start recording without explicit user action (no auto‑start on launch).  
- On Stop:
  - Stop all capture sessions and audio engines.  
  - Finalize the asset writer and ensure the file is properly closed.  
  - Notify the user of completion and location of the output file.  
- On error:
  - Stop recording safely as needed.  
  - Do not leave partial capture sessions running in the background.  

***

## Agent Behavioral Guidelines

These rules describe how an LLM‑style agent or automation layer should interact with this project and reason about changes. [reddit](https://www.reddit.com/r/macapps/comments/1cw6qh3/i_created_an_opensource_screen_recorder_for_macos/)

### General Principles

- **Safety and Consent**  
  - Never initiate recording flows without a corresponding explicit user action in the UI or in a clearly authorized automation flow.  
  - Treat screen, camera, mic, and system audio as sensitive; any automation must preserve explicit user intent.  

- **Predictability**  
  - Avoid “magic” behavior; changes to sources (e.g., enabling system audio or camera) should only occur in response to direct user configuration.  
  - If the user disables a source (e.g., camera or system audio), the agent must not re‑enable it without the user’s explicit action.  

- **Small, Reversible Changes**  
  - When editing code, the agent should prefer small, focused commits (for example, “Add system audio gain slider” rather than reorganizing the entire UI in one step).  
  - Preserve public protocols and data models unless a change is clearly required.  

### Code and Project Rules

- Do:
  - Keep cross‑cutting concerns within `RecordingCoordinator` and service classes; avoid pushing recording logic into SwiftUI views.  
  - Use SwiftUI as a thin declarative UI layer bound to observable view models.  
  - Keep platform‑specific glue (bridging to lower‑level APIs) isolated under clearly named services (e.g., `ScreenCaptureService`).  

- Avoid:
  - Blocking the main thread with heavy work (encoding, file I/O, large allocations).  
  - Mixing low‑level API calls directly into the SwiftUI views.  
  - Introducing dependencies that break the ability to build and run from the command line.  

### UI Behavior Rules

- The UI must:
  - Always show whether recording is active, paused, or stopped.  
  - Provide an obvious indication when camera and/or system audio are active (for example, icons or text labels).  
  - Use concise, clear messages for permission issues, errors, and completion notifications.  

***

## Non‑Goals and Out of Scope

The app does **not** aim to:

- Implement advanced video editing (trimming, transitions, timelines, filters).  
- Use private or unsupported APIs in production builds.  
- Depend on kernel extensions or third‑party audio loopback drivers; only official, user‑consented methods for system audio should be used.  
- Provide a full‑featured multi‑project IDE integration; this project is centered around SwiftPM and command‑line builds.  