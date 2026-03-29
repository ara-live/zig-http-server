# STATE.md - Nuclear Eyes v2

## Current Issue: NoFrameAvailable on second capture

### Root Cause Analysis 🧠
The DLL uses a **background processing thread** that:
1. Continuously calls `TryGetNextFrame()` in a loop
2. Copies each frame to a persistent buffer
3. `GetLatestFrame()` just returns the already-processed buffer

Our Zig code only calls `tryGetNextFrame()` when capture is requested.
After the first frame is consumed, the pool is empty until WGC delivers more.

### The Fix
Instead of waiting for one frame, **drain all available frames** and use the last one:
```zig
// Drain pool, keep last frame
var last_frame: ?*Frame = null;
while (pool.tryGetNextFrame()) |frame| {
    if (last_frame) |prev| prev.release();
    last_frame = frame;
}
if (last_frame) |frame| return processFrame(frame);
```

This mirrors the DLL behavior without needing a persistent background thread.

### Progress
- ✅ Nuclear pipeline works (verified 89ms, 88KB)
- ✅ Queue thread pattern working
- ✅ D3D11/CUDA/nvJPEG all on same thread
- ❌ Second capture fails (NoFrameAvailable)

### Launch Context Issue (SOLVED)
- ara-gate spawn: WGC CreateForWindow fails with 0x80070424
- Start-Process spawn: Works perfectly
- Solution: Run eyes via scheduled task or remove from ara-gate management
