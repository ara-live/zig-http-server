# eyes-zig State

## Current Status: INVESTIGATING

### Key Findings (2026-03-29)

**1. DLL version handles rapid captures fine**
- Tested: 20 captures in succession via `bench_python.py`
- Result: 20/20 success, avg 9.23ms, 108 FPS
- Exit code 0xC0000409 on cleanup (ctypes DLL unload issue, not capture)

**2. Zig binary version handles rapid captures fine**
- Tested: 10 captures in succession via HTTP endpoint
- Result: 10/10 success, avg 29.2ms
- Hot path achieved **4ms** on capture #4
- Variance (4-60ms) likely due to WGC frame availability timing

**3. Service deployment has intermittent failures**
- Error seen: `cuD3D11GetDevice failed: 100` (CUDA_ERROR_NO_DEVICE)
- Nuclear pipeline sometimes initializes, sometimes doesn't
- Suspected: race condition during ara-gate lifecycle restart

### Comprehensive Diff Report (2026-03-29)

**Files compared:** ScreenMaster/zig/src/*.zig vs eyes-zig/src/nuclear/*.zig

#### IDENTICAL FILES (6/9)
| File | Hash Match |
|------|------------|
| kernel.zig | ✅ MD5 identical |
| nvjpeg.zig | ✅ MD5 identical |
| cache.zig | ✅ MD5 identical |
| search.zig | ✅ MD5 identical |
| windows.zig | ✅ MD5 identical |
| root.zig | ✅ MD5 identical |
| kernels/bgra_to_rgb_resize.ptx | ✅ MD5 identical |

#### DIFFERENT FILES (3/9)

**1. cuda.zig (+291 bytes)**
- **Location:** Lines 260-272
- **Change:** Blackwell/sm_120 fallback
- **ScreenMaster:** If `cuD3D11GetDevice` fails → error
- **eyes-zig:** If `cuD3D11GetDevice` fails → try `cuDeviceGet(0)` directly
```zig
// Blackwell/sm_120 may have D3D11 interop issues - fall back to device 0
result = api.cuDeviceGet(&device, 0);
```

**2. d3d11.zig (+4849 bytes)**
- **Location:** Lines 402-553
- **Change:** NVIDIA adapter enumeration for CUDA interop
- **ScreenMaster:** Uses `null` (default adapter) with `D3D_DRIVER_TYPE.HARDWARE`
- **eyes-zig:** 
  - Creates DXGIFactory1
  - Enumerates all adapters
  - Finds NVIDIA by VendorId (0x10DE)
  - Uses explicit NVIDIA adapter with `D3D_DRIVER_TYPE.UNKNOWN`
  - Logs adapter info (name, VRAM)

**3. wgc.zig (+803 bytes)**
- **Location:** Lines 38-50, 167-192
- **Change:** Thread-local COM initialization
- **ScreenMaster:** 
  - Global `g_initialized` flag
  - Only calls `RoInitialize()`
- **eyes-zig:**
  - Thread-local `tls_initialized` flag
  - Calls `CoInitializeEx(null, 0)` BEFORE `RoInitialize()`
  - Handles `RPC_E_CHANGED_MODE` (0x80010106) gracefully
  - More detailed logging

---

### Analysis

**Why these changes exist:**
1. **cuda.zig fallback** — RTX 5060 Ti (Blackwell/sm_120) has D3D11-CUDA interop issues where `cuD3D11GetDevice` returns error 100. Fallback to device 0 works.

2. **d3d11.zig adapter enum** — Multi-GPU systems (or systems with iGPU+dGPU) need explicit adapter selection to ensure D3D11 uses the NVIDIA GPU for CUDA interop.

3. **wgc.zig COM init** — Dedicated capture thread requires proper COM initialization before WinRT. Thread-local flag allows multiple threads to initialize independently.

**Potential issues:**
- ❓ If NVIDIA adapter enumeration fails silently, falls back to default (might pick wrong GPU)
- ❓ COM init order matters — must be before any WGC calls
- ❓ Thread-local vs global init could cause issues if called from wrong thread

### Test Results (2026-03-29)

**Hypothesis confirmed:** The extra "workaround" code was unnecessary.

| Step | Change | Result |
|------|--------|--------|
| 1 | Revert cuda.zig (remove Blackwell fallback) | ✅ 10/10 |
| 2 | Revert d3d11.zig (remove NVIDIA adapter enum) | ✅ 10/10 |
| 3 | Revert wgc.zig (remove thread-local COM init) | ✅ 10/10 |

**All nuclear/*.zig files now identical to ScreenMaster/zig/src/*.zig**

### Lessons Learned

1. **Blackwell fallback was unnecessary** — `cuD3D11GetDevice` works fine on RTX 5060 Ti. The error 100 we saw was likely environment/timing, not hardware.

2. **NVIDIA adapter enumeration was unnecessary** — Default adapter selection works fine. D3D11 picks the right GPU without explicit enumeration.

3. **Thread-local COM init was unnecessary** — Global flag + `RoInitialize()` is sufficient. The capture queue thread handles COM correctly.

4. **Pipe redirection kills processes** — `Start-Process -RedirectStandardError` can cause issues. Test without redirection.

### Current State

eyes-zig/nuclear is now a clean copy of ScreenMaster/zig. All captures work.

---

## Architecture

```
HTTP Request → api.zig → capture_queue.zig → nuclear_capture.zig
                                                    ↓
                                            WGC → D3D11 → CUDA → nvJPEG
```

## Files

| File | Purpose |
|------|---------|
| api.zig | HTTP server (warm-one pattern) |
| capture_queue.zig | COM thread routing |
| nuclear_capture.zig | GPU pipeline orchestration |
| nuclear/*.zig | Low-level D3D11/CUDA/WGC bindings |
