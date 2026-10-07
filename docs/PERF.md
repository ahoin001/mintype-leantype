# Performance checklist

Keyboard extensions are killed at roughly 48 MB of dirty memory and share the main thread with
every keystroke. LeanType's budgets are enforced, not aspirational: run this checklist before
each milestone ships, on the oldest supported device (iPhone XS class), with a **Release** build.

## Budgets

| Area | Budget | Where it's enforced |
| --- | --- | --- |
| Dirty memory, whole extension | ≤ 30 MB | Allocations, below |
| Effects layers | ≤ 49 (24 shape, 24 text, 1 emitter), < 300 KB | `LayerPool` returns `nil` when spent |
| Trail buffers | 64 points per finger, reused | `TrailRenderer` (`TrailPoints`, spare histories, scratch edges) |
| Lexicon | ~1.6 MB (100k words), memory-mapped (clean, evictable) | `MappedFile` (`PROT_READ`) |
| Decoder scratch | < 256 KB (actually ~3 KB) | `PathDecoder` preallocated buffers |
| Personal words | ≤ 1,000 learned, < 64 KB on disk | `PersonalLexicon.capacity` |
| Touch → commit | < 8 ms | `Commit` / `Touch batch` signposts |
| Swipe decode | < 15 ms | `Decode` signpost, `PathDecoderTests.decodesFastEnough` |
| Effect start | same frame as the commit | `Effect` signpost |
| Idle | 0% CPU, no display link | `TrailRenderer` stops its link when no finger is drawing |

## Signposts

All intervals are on subsystem `com.leantype.keyboard`:

- **Points of Interest**: `Touch batch` (one `touchesX` delivery through the engine) and
  `Commit` (one intent applied to the document).
- **Layout**: `Rebuild geometry`.
- **Swipe**: `Decode` (runs on the `PathDecoder` actor, off the main thread).
- **Effects**: `Effect` (one event routed to every effect) and `Trail frame` (one display-link tick).

## Checklist

1. **Allocations** (Instruments → Allocations, extension process attached via the host app).
   - Type a paragraph, swipe twenty words, delete and restore a few. Persistent bytes should
     plateau; anything that grows per keystroke is a leak.
   - Mark a generation, type for a minute, mark again: the delta should be near zero.
   - Trigger *Simulate Memory Warning*: effects stop and the layer pool drains.
2. **Time Profiler** with the signposts track.
   - `Commit` p99 < 8 ms; `Effect` intervals well under 1 ms.
   - `Decode` p99 < 15 ms, and never on the main thread.
   - While idle, no samples in LeanType code and no `CADisplayLink` callbacks.
3. **Core Animation FPS** (or the Animation Hitches instrument).
   - Swipe continuously with Party intensity and Prism trails: no hitches above 1 frame.
   - Turn on Low Power Mode: effects drop to the reduced set immediately.
4. **Thermals**: with the device in the *Serious* thermal state (Xcode → Devices → Condition),
   effects drop to the reduced set; at *Critical* they're off.

## Last measured

| Date | Device | Build | Swipe decode (avg / worst) | Notes |
| --- | --- | --- | --- | --- |
| 2026-10-07 | iPhone 17 simulator (Intel Mac host) | Release, `-enable-testing` | 0.7 ms / 1.3 ms | 40 synthetic swipes, 100k lexicon; debug builds are much slower |

Decoder accuracy (asserted in `PathDecoderTests`): on the 500 most common words with seeded
noise, ≥ 90% top-1 and ≥ 98% top-4.

Device runs (Allocations, FPS) still need recording on physical hardware; add a row here each
time.
