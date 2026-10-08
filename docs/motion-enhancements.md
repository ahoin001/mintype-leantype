# Motion enhancements

The morphs are in the keyboard. `Morph` decides the shape (stretch, settle, expand,
contract) and `MorphDriver` plays those samples on the render server. Reduce Motion
moves every edge together and skips the squeeze and the overshoot.

Letter presses stay instant. A gear change, a layer change, and return each get one shot.
The current motion rules stay in force: a key press applies on the same frame, and only
the release eases (`Motion.keyRelease`, 100 ms). Effects run on the render server, from
the pooled stage, and drop to a fade under Reduce Motion, serious heat, or Low Power Mode.

Letter-down is the wrong place for new motion. It happens hundreds of times a session.
The ideas below attach to a gesture that finishes, a mode that changes, or a chrome
element that is already moving.

## Borrowed from Wee's pill motion

Wee's "gooey" feel is not a blur filter. Space Rail and Hub Controls share one pattern:
the shape leads, the contents follow, and the two edges of a moving indicator run on
different springs. Three pieces of LeanType already move and can take that language.

### Suggestion pill stretches instead of sliding as a block

In the keyboard. When the highlight changes slots, the edge in the direction of travel
arrives first and the trailing edge catches up, inside `Motion.pillTravel` (120 ms).
A committed swipe or accepted suggestion, and a correction, squeeze through the middle
(`Morph.settle`) instead. A new move starts from the pill's presented frame, so a fast
typist interrupts the stretch. Reduce Motion moves both edges together.

### Dock status pill morphs

In the keyboard, as `StatusCapsule`. Trackpad, caps, and the other dock messages grow
out of a circle at the wordmark's center (`Morph.expand`), wait `Motion.contentDelay`
(120 ms), then show the icon and label. Collapse uses `Morph.contract`, which starts
slower and does not overshoot. The capsule's shadow fades in with the shape. Keys do
not morph their width or height, except the space bar below.

### Long-press selection stretches between letters

In the keyboard. The balloon still grows out of the key. The selection inside an
alternates row uses the same stretch as the suggestion pill. Its first appearance sits
in place; only a move between cells travels.

## Reward the gesture that just finished

### A swipe or accepted suggestion lands

In the keyboard. `wordCommitted(.swipe)` and `wordCommitted(.suggestion)` squeeze the
highlight pill and let it settle (`Morph.settle`, `Motion.pillSettle`). The swipe trail
still collapses on its own. A tap-space commit stays a faint tick on the space bar.

### Backspace changes gears

In the keyboard, as `GearMarkEffect`. `deleteEscalated` carries the gear just entered,
and one mark pops on the backspace key: "word", then "sentence". The key does not move.
`deleteStep` stays haptic-only.

### A correction takes hold

In the keyboard. `correctionApplied` and `correctionReverted` play the same settle
through the highlight pill. Gust still reverses a deleted word; a correction is the
quieter version of that.

### The wait before alternates

In the keyboard, as `HoldWindupEffect`. While a hold row is arming, a thin ring draws
around the key. It stays invisible for the first 80 ms, so a tap never flashes it.
When the row opens, the ring fades and the balloon grows out of the key. The letter
preview itself stays instant. Reduce Motion, heat, and Low Power skip the ring.

### Trackpad, only at the edges

In the keyboard. On engage, the space bar widens to `Motion.trackpadSpan` and eases
back when the finger lifts. Reduce Motion leaves the bar at its resting width. The
comet still carries the steps in between, with a longer stride for a word jump.

### Changing layers

In the keyboard. Switching layers brings the new labels in by row, `Motion.rowStagger`
(20 ms) apart, from `Motion.rowArrivalScale` (0.96). The key bodies stay put. Shift and
caps stay instant, because they only change a label in place. Caps lock already has its halo.

### Return

In the keyboard, as `ReturnLiftEffect`. A copy of the return glyph lifts off the key
and fades in `Motion.returnLift` (180 ms). The key itself does not move.

## Leave alone

- Per-key squash, tilt, or spring-in. The press scale is 0.95 and it applies with no
  animation.
- Neighbor keys denting when one is pressed.
- An SVG or backdrop-filter goo.
- Idle motion on keys that are always visible. A peek is for chrome that is hidden.
