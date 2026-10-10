# Mixed input

Two thumbs share one beat. A letter is a tap, a pin, a rest, a slip, an anchor, or a crossing. The decoder is one alignment search. Join versus a new word is one `WordJoiner`.

## Stamps

Touch-down stamps the stroke, the dwell, and the hold. `SwipeSession.beginStroke` and `SwipeCoordinator.add` use `track.start`, so a partner tap during a hold sorts after that stamp. A lift does not move the letter later in time.

| Role | When | Skip |
| --- | --- | --- |
| Tap | Lifted without becoming a stroke | 3.2, spends the two-anchor budget, only after a letter is placed |
| Pin | Held at least `GestureComposer.dwellDuration` (0.18 s) and not a rest | Unskippable on the first pass. Neighbors only within 0.3 key widths. Recovery may skip it at 3.2 |
| Rest | Held at least `SwipeSession.restDuration` (0.5 s) while another finger has a stroke, and the hold is not an accent | 0.8. Does not spend the skip budget. Cannot be the skip that empties the word |
| Slip | Same letter, other thumb, within `TapThumbs.differentThumbGap` (60 ms) | 0.05. Both observations stay. `pill` can use the second; a slip can drop it |
| Anchor | The stroke's closest approach to a key | 3.2, same budget as a tap |
| Crossing | A key the stroke passed through | Channel 0.05, or `0.05 + 1.15 × closeness` |

The global neighbor radius stays 1.5 key widths. A pin uses 0.3 for that step only. A dwell still forbids a doubled letter. Accent holds stay letters.

The hold ring and the key haptic fire when the finger crosses the pin threshold (0.18 s), not at touch-down. A lone hold still opens the accent row at 0.42 s. The row stays closed while another letter finger is down, while a beat is open, or while typed composing is waiting to flush.

## The beat, then the leash

These are two different waits.

**Before decode.** The last letter finger lifting does not decode. The beat stays open for the leash (`TypingRhythm`, 340 ms cold, then 160–550 ms). A new tap in that window joins the beat, so `the` plus `n` can still become `then`. A new stroke, once every letter finger is up, decodes the beat first. `WordJoiner.choose` then decides whether the new stroke continues the word. Pieces that are not their own words stay one word (`f-r`, `i`, `e`, `n`, `d` → `friend`). A second word that already aligns (`hello` then `world`, `correct`, `to`) stays its own word at 120, 180, and 250 ms.

**After commit.** The same joiner runs again. A finger still down holds `openDeadline` open. It does not extend the "is this still the same word" window by itself. Explicit space skips the choice. Blocked extensions stay blocked: into, now, ago, some, anyone, cannot, within, upon, become.

A partner that lifts while another letter finger is down does not call `tap.ended`. The letter is parked, stamped at touch-down, and types only when the last letter finger lifts and nobody traveled. Cancel of a finger that never traveled types nothing and does not drop the other thumb. Cancel of a finger that drew is a lift. Space, return, and `. , ! ?` finish the beat before the key. Leaving the keyboard cancels every touch.

`scheduleComposingFlush` does not fire while any letter finger is down. It rearms when the last one lifts.

## Search

Time order is the first pass: beam width 4, then 12, then 28, on the same 12 ms clock. Each non-empty stage replaces the previous reading. A stage that returns nothing keeps the last reading that consumed every anchor. It does not return a prefix such as `fr`. Recovery at width 48 runs only when that result is weak and the deadline is still ahead. Clock expiry is written locally as a gesture class. Nothing is uploaded. The maximum width stays 28, and recovery stays 48.

`ReadingPolicy.exactLead` stays 1.0. `DecodeResult.confidenceMargin` stays 0.35. `FollowerPrior` stays 0.45.

When the thumbs overlap, the chain beam walks one cursor per chain. Order inside a chain stays fixed. The inversion cost is `min(1.6, 2.4 × seconds)`. While the other thumb was down across the event, that cost is multiplied by `heldOrderDiscount` (0.5). There is no cap that keeps a chain word behind time order. A time-order word that already matches the aimed letters still wins when the inversion does not pay for itself. The right thumb 120 ms early still keeps `friend` in the top three.

A lift that does not change the observations commits the last preview. A lift that adds an end anchor may decode again.

## Correction

`RetryMemory` keeps the last three decisions for the session. A new gesture within 4 s whose aimed letters are within one edit, or whose path midpoint is within 0.6 key widths, is a retry. The rejected word loses 1.2 on that candidate only, which is more than `exactLead`. The word the user picked is boosted the same amount. A second retry is written to `SwipeRefusalMemory`.

After a whole-word backspace of a swipe, the strip keeps that swipe's other readings for 3 s. Accepting one records the correction.

`AimMemory` stores aimed keys to the chosen word, about 300 entries. It applies on an exact repeat or one neighbor substitution, from `LanguageModel.finish`.

The first autocorrect revert only sets the session kept word. The second revert of that pair persists the rejection.

Strip alternatives are labeled neighbor, cross-thumb order, omitted letter, split or join, or completion. Per-user counters nudge strip order by a multiplier clamped to 0.7–1.4. Beam weights do not move. There is one row.

`TrustMeter` watches about the last 10 decisions. Two or more overrides within 3 s widen the unsure band from 0.35 to 0.6 and raise the lead required to replace typed letters from 1.0 to 1.5. A clean streak relaxes both. Neither constant changes.

Double-tap on the settled chip toggles the last join or split when one is stored. Single tap still accepts. History-chip double-tap merge stays.

`peelOpenWord` re-decodes the remaining events and turns completion-ahead off for that word. Backspace while a beat is collecting removes the latest tap by time and refreshes the preview. It does not delete committed text under the finger.

A real geometry change while a beat or composing is active flushes the same way as leaving the keyboard. An ordinary layout pass does not.

`ThumbTerritory` counts left and right from moments when two fingers overlap. After four samples, a share at or below 0.25 or at or above 0.75 replaces the geometric side for a tap-only word and for which chain a re-land joins. A seam key does not lock the chain. The 60 ms gap rule stays.

Each committed tap records its travel. The sideways stroke threshold is the 90th percentile of the last 80 taps, clamped to 12–24 pt, and 16 until there are 12 samples. Offsets are not parsed on the touch path and are not a ranking feature.

## Worked examples

**Friend, taps then a hold.** Tap `f`, `r`, `i`. Left thumb holds `e` past 700 ms. Right thumb taps `n` and lifts before `e` moves. Left thumb slides to `d`. `n` stays in the beat because `e` is down. The accent row stays closed because `fri` is still composing. The field is `friend `.

**Friend, interleaved.** Left thumb `f r e d`, right thumb `i n`, with the right thumb 120 ms early. Time order may read `finred`. The chain beam still has `friend` in the top three.

**Hello, world.** Two strokes, 120, 180, or 250 ms apart, after the first finger is up. Each stroke is already its own word, so the field is `hello world `.

**The, n.** A tap joins the open beat, and the after-commit leash can still fold it. `the` plus `n` can become `then`. Later letters can undo that to `the nice`.

**Rest.** Hold `x` while the other thumb draws `the`, past 500 ms. `x` is a rest. Skipping it costs 0.8. The field can still be `the `.

**Pin.** A hold that is not a rest is unskippable on the first pass, and its neighbors stay inside 0.3 key widths.

**Cancel.** Two fingers down, neither has traveled, cancel one. The field stays empty. The other finger still types its letter.
