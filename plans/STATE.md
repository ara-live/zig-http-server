# STATE.md - Nuclear Eyes Integration

## Current Task: Main-Thread Capture Queue

### Problem
WGC `CreateForWindow` fails with 0x80070424 from HTTP worker threads, even with CoInitializeEx+RoInitialize. Works fine in single-threaded tests.

### Solution
Route all WGC calls through main thread:
1. HTTP workers enqueue capture requests
2. Main thread polls queue, executes WGC
3. Workers wait on completion signal

### Implementation Plan
- [ ] Add `CaptureRequest` struct (hwnd, result slot, completion event)
- [ ] Add `RequestQueue` with mutex-protected ring buffer
- [ ] Main thread poll loop between accept() calls
- [ ] Worker blocks on event after enqueue
- [ ] Wire into api.zig capture handler

### Done ✅
- [x] DXGI adapter enumeration (NVIDIA selection)
- [x] CUDA device 0 fallback
- [x] Per-thread WinRT init (threadlocal)
- [x] CoInitializeEx + RoInitialize
- [x] Nuclear pipeline init works

### Key Insight
ScreenMaster test works because it's single-threaded. The HTTP server spawns worker threads that have fundamentally different COM characteristics, regardless of initialization calls.
