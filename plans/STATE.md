# STATE.md - Nuclear Eyes v2

## Status: WGC Fixed, CUDA Texture Blocked

### What's Working ✅
- Queue thread pattern (dedicated COM/D3D11 thread)
- WGC CreateForWindow succeeds (even via ara-gate!)
- Nuclear pipeline init (CUDA context, nvJPEG, PTX kernel)
- Frame drain to get latest frame
- DLL fallback (deployed, ~16ms captures)

### Current Blocker ❌
**cuTexObjectCreate returns error 1** (CUDA_ERROR_INVALID_VALUE)

The mapped CUDA array from D3D11 interop isn't compatible with texture objects.
Possible causes:
- Array format mismatch (BGRA vs expected format)
- Array flags incompatible with texture binding
- Need to use cuGraphicsSubResourceGetMappedArray differently

### Investigation Needed
1. Check ScreenMaster's working Zig test - how does it create textures?
2. Verify CUDA array descriptor format
3. Try using linear memory instead of texture (if needed)

### Session Summary
This session solved:
- Thread affinity for WGC (queue pattern)
- WGC permissions (works via ara-gate now!)
- Frame availability (drain and use last)
- Resource mapping (pointer vs copy)

The final hurdle is CUDA texture format compatibility.

### Files Changed
- `capture_queue.zig` - Queue thread pattern
- `nuclear_capture.zig` - Pipeline init on queue thread, frame drain
- `wgc.zig` - Per-thread COM/WinRT init
