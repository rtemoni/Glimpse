# Preview performance audit

## Summary

The capture APIs were configured for 60 fps, but the setup UI could not present that cadence. Every screen frame crossed to the main actor, performed a full-resolution composite, created a full-resolution `CGImage`, and published through the root `RecordingCoordinator`. Camera frames and audio packets also created main-actor tasks. This produced contention and stale work instead of a low-latency preview.

The new media pipeline performs capture processing, composition, preview downsampling, and writer appends on bounded serial queues. SwiftUI receives only ready-to-display frames at up to 30 fps through leaf-scoped stores. When rendering falls behind, video submissions coalesce to the latest frame instead of growing a backlog.

## Findings and fixes

1. **Full-resolution work ran on the main actor**
   - Before: screen composition and `CIContext.createCGImage` ran on the main actor for every frame, up to 60 times per second.
   - The resulting screen preview image was not displayed by the setup or recording UI, so the most expensive preview work was wasted.
   - After: `CaptureMediaPipeline` owns compositing, preview rendering, and muxer traffic off the main actor. Recording no longer produces unused preview images.

2. **Preview work could accumulate behind capture**
   - Before: each screen, camera, audio, and meter callback created a new main-actor task.
   - After: screen and camera submissions use latest-frame coalescing. Audio samples remain ordered on the media queue, while meter updates use a separate lightweight queue.

3. **Visible update rates were intentionally low or static**
   - Camera preview was capped at 10 fps (`0.1 s` interval).
   - Audio meters were capped at 20 updates/s (`0.05 s` interval).
   - Display/window cards captured a single screenshot and never refreshed.
   - After: camera, selected-target composite, and audio meters are bounded at 30 updates/s. Live UI badges report the delivered rate.

4. **SwiftUI observation fanned each media update across the setup screen**
   - Before: preview images and meter values were `@Published` on the root `RecordingCoordinator` environment object.
   - After: screen preview, camera preview, microphone meter, and system-audio meter each have a small leaf-scoped observable store.

5. **Preview images retained capture-sized pixel data**
   - Before: thumbnail `NSImage` display size was reduced, but its backing `CGImage` remained capture-sized. Thumbnail capture also ran in a SwiftUI task on the main actor.
   - After: static thumbnails are rasterized to their actual maximum pixel dimensions on a utility task. Live 6K frames are downsampled to at most 960 × 540 before publication.

6. **Capture and compositor buffering were undersized or repeatedly allocated**
   - ScreenCaptureKit used its default queue depth of 3.
   - The compositor created a fresh full-resolution output pixel buffer for every camera-overlay frame.
   - After: queue depth is 5, matching Apple's ScreenCaptureKit sample guidance, and the compositor reuses a four-buffer `CVPixelBufferPool`.

7. **Incomplete ScreenCaptureKit frames could enter the pipeline**
   - Before: any valid sample with an image buffer was accepted.
   - After: frames with an explicit non-complete `SCFrameStatus` are ignored.

## Metrics

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Camera preview cap | 10 fps | 30 fps | 3× cadence |
| Selected display/window preview | Static (0 fps) | 30 fps target | Live composite |
| Audio meter cap | 20 Hz | 30 Hz | 50% more updates |
| Main-actor screen-frame processing | Up to 60 jobs/s | 0 jobs/s | Removed |
| 6K preview pixels published per frame | 20,358,144 | 518,400 | 97.5% fewer |
| End-to-end 6K-to-960×540 preview render | 37.971 ms/frame | 5.717 ms/frame | 6.64× faster |
| 6K output-buffer acquisition | 0.104 ms/frame | 0.006 ms/frame | 16.9× faster |
| ScreenCaptureKit queue depth | 3 | 5 | More stall tolerance |

The rendering microbenchmark ran 24 optimized iterations on an Apple M4 Mac mini with macOS 26.5.1. It uses a filled 6016 × 3384 BGRA `CVPixelBuffer` and includes both `CGImage` creation and drawing to a 960 × 540 display surface. Pixel-buffer acquisition compares `CVPixelBufferCreate` with `CVPixelBufferPoolCreatePixelBuffer` at the same 6K size.

## Validation

- `swift test`: 44 tests passed, including four cadence/rate-tracker regression tests.
- Release app bundle build and startup smoke test.
- The setup screen exposes live `fps` badges on camera and selected-target previews and `Hz` readouts on active audio meters for runtime verification.
