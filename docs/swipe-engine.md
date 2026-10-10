# Swipe engine

This is the behavior of the English swipe decoder in the tree. Numbers below are the
ones the code uses. Each worked example names the test that locks it. The choices
behind those numbers are in `docs/swipe-decisions.md`. This is not a roadmap.

Swipe runs only when `KeyboardSettings.typingMode` is `.swipe`, a language model is
loaded, and the field allows it (`KeyboardEngine.applySettings`). It runs on the
letters layer. A finger on a non-letter never becomes a stroke.

Decode budget and memory limits are in `docs/PERF.md`. A release decode also stops
itself at 12 ms. See [Stay inside a frame](#stay-inside-a-frame).

## What this engine does

One word is one session. The first contact span latches the phase, and that phase
decides when the word commits. The key under the finger lights on touch-down, before
any decode. A single clean curve can search the lexicon by shape. A repeated word, a
remembered curve, and a familiar follower can break a close call. They cannot replace
a spelling the keys actually aimed at unless the alternative leads by more than
`exactLead` (1.0).

Intentionally absent:

- The lexicon is unigram. Letter bigrams are a spelling prior inside one word.
  Between words, one follower sits beside the word that just finished. It is not
  highlighted, and there is no second suggestion row.
- The previous word is not fed into the two-thumb beam as a prefix.
- `FollowerPrior` stays a fixed 0.45. `exactLead` stays 1.0. Sigma does not grow
  from a precision estimate or from how far the thumb reached. Those wait until the
  on-device touch log says placement or pair strength is the miss.
- There is no clipboard history, no iCloud sync of learned words, and no jump into
  the system emoji keyboard. The public input-mode API only advances to the next
  keyboard.
- A permanent number row is not part of this layout.
- Nothing in this engine is uploaded.

## Pipeline

```
touches
  → SwipeSession              tap, hold, or stroke
  → SwipeCoordinator          one beat: at most two strokes, plus holds and taps
  → GestureComposer           anchors, crossings, taps, aimed letters
  → AlignmentSearch
       1. time order, widths 4 then 12 then 28, keeping the last reading that used every anchor
       2. chain beam when the thumbs overlap and the clock still has time; it may outrank time order
       3. rescore with the polyline
       4. expected followers, if a preceding word exists and the stroke fits them
       5. shape nominations for one clean curve
       6. follower bonus, then ReadingPolicy
       7. the same search again, with recovery costs, only when that result is weak
          and the 12 ms budget is still open
  → LanguageModel.finish      blocklist, rejections, familiar words, stroke memory
  → WordSession               tap-open stays up; swipe-open commits on the last lift
  → field                     preview while the word is open, commit from the session
```

`KeyboardEngine` applies the session's effects: preview the composing word, or commit
it in place. It does not decide the boundary. `AlignmentPathMatcher` is the only
caller of the alignment search. Every hand-set search number lives on
`AlignmentCosts`. `AlignmentCosts.recovery` is the wider second pass.

## What a finger is

Every finger that lands on a letter starts as a tap (`CharacterTapSession`). The key
is pressed immediately. The finger becomes a stroke only when `SwipeSession` says it
has traveled. A roll that merely crosses the key border is still that one letter.

| Condition | Threshold | Scales with key width? |
| --- | --- | --- |
| Sideways travel | 16 pt | No |
| Past the key's hit frame | 8 pt (`frameSlop`) | No |
| Travel in any direction, including straight down | 36 pt | No |
| Dwell radius | 24 pt at a 36 pt key | Yes |
| Dwell travel | 12 pt at a 36 pt key | Yes |
| Retreat step | 34 pt at a 36 pt key | Yes |
| Retreat lookback | 120 pt at a 36 pt key | Yes |
| Dwell time | 180 ms, then the session rhythm | No. Time stays time |
| Rest while another finger draws | 500 ms | No |

`StrokeBuffer.referenceKeyWidth` is 36. A live key of width `w` multiplies dwell
radius, dwell travel, retreat step, and retreat lookback by `w / 36`. The 16 pt,
36 pt, and 8 pt tests stay in points, so a bigger key does not turn tap jitter into
a stroke.

A short downward dip that stays on the key remains a flick, not a stroke. A slide
along the shortcut row is choosing an accent, not drawing. If the shortcut row is
already open, the other thumb's word still receives the letter that was held.

### Two thumbs

Two letter fingers can be down together. Neither types until one of them travels.
The finger that travels starts the gesture and enlists the other:

- A partner that has already moved joins as another stroke.
- A partner still on its key becomes a held letter. It is one character in this
  word, timestamped at touch-down, and it is not a point on the polyline.
- If that held finger later travels, the hold is dropped and it becomes a stroke of
  the same beat.
- If it lifts without traveling, the letter is kept as a tap in the beat.
- A thumb that lifts and lands again extends its own chain. The side of the key,
  split halfway from Q to P, says which thumb it is. The letters of both visits
  stay on that chain, in time.

Decode uses at most two chains, one per thumb. A second finger that lands while one
thumb is already drawing takes the other chain, even when it starts on the same side
of the keyboard. A finger that lands while both thumbs are already drawing is a tap
of the letter it started on. A palm cannot open a third chain.

### Cancel, and a long rest

Cancelling a finger that is already a stroke calls the same path as a lift of that
finger (`coordinator.ended`). The other thumb's beat stays. Cancelling a finger that
never traveled types nothing and does not reset the gesture.

A letter held with no travel for 500 ms, while another finger is drawing and the
accent row is closed, is left out of the beat. The same hold with the accent row
open is kept. A slow tap with no other finger down is still that letter.

### Examples

- A thumb lands on N and rolls 6 pt past the hit frame, then lifts. The field gets
  `n`. The roll never became a stroke. At 8 pt past the frame it would.
- Left thumb is drawing `live`. The right thumb is cancelled after it has started
  its own stroke. The left stroke is kept and decoded. If the right thumb is
  cancelled before it travels, it contributes no letter.
- Left thumb holds K for half a second while the right thumb draws a word, and the
  accent row is closed. K stays in the beat as a rest. The decoder may skip it.
  Holding K alone, however slowly, types `k`.
- Three fingers travel at once. The two thumbs are chains. The third is a tap of the
  letter it started on.
- Left thumb draws `f` then `r` and lifts. That first span was a stroke, so the word
  is swipe-open and the lift commits it. Later taps are the next word. A word that
  started with taps stays open across those later taps until space.

Locked by `aRollJustPastTheKeyStaysATapUntilItClearsTheSlop`,
`aThirdStrokeIsATapAndDwellFollowsTheKey`, and `anAlternatingPairSpellsFriend`.

## When a word commits

A contact span runs from the first finger down until no letter finger is left down.
`WordSession` latches the phase from that span. `GestureSegmenter` decides tap versus
stroke with the thresholds above. Squared distance is used for the long check. No new
objects are allocated inside `touchesMoved`.

| Phase | How it starts | What a lift does | What closes it |
| --- | --- | --- | --- |
| Contact | The first finger of a new word lands | No stroke in the span latches tap-open. A stroke latches swipe-open as soon as travel crosses the threshold | The span ending |
| Tap-open | The first span ended with no stroke. Hey: tap `h`, lift, pause, then swipe `ey` | A later swipe joins the same draft. Lifting does not commit | Space, return, or punctuation, which then types itself |
| Swipe-open | The first span stroked. Howdy: a stroke, including a handoff while one finger stays down | The instant the last finger lifts, the draft commits with a trailing space. A mid-word all-fingers-up commits early | That lift |

Stay is still swipe-open. Holding `s` is not a tap until that finger lifts. A tap of `t` while `s` is held does not latch the phase. Travel to `a` latches swipe-open, a tap of `y` joins, and the last lift commits `stay`.

Thumb identity is fixed at touch-down from the placement split: halfway across the key area, or the gap on a split keyboard. A finger that crosses the middle keeps the thumb it started with. A third finger does not open a third chain. It is a tap of the key it landed on.

`KeyboardSettings.extendFinishedWords` and `swipeCommitMode` are not consulted. A committed swipe does not absorb the next letter. `the` then `n` stays `the n`. `hello` then `correct` stays two words.

A beat is still the strokes, holds, and taps collected for one decode. Strokes are ordered by when each finger lifted. Taps and stroke letters are merged by time, so a letter tapped in the middle of the other thumb's stroke lands in the middle of the word. The composer ticket is taken from the first stroke. A delimiter commits that ticket before its own key is applied, so the word is not stuck behind the space.

Previews are debounced to about 40 ms, and they run immediately when a letter is tapped or a finger lifts. Decode stays off the main actor.

## The word stays open

Tapped letters and the swipe preview are composing text, not a commit followed by an
erase.

| Layer | When it shows | Counts as the open word? |
| --- | --- | --- |
| `typedComposing` | Letters held while no swipe preview is up | Yes. Shift, the current word, and backspace see it. |
| `previewComposing` | The swipe leader, and only while typed composing is empty | No. It is the ghost in the field. |

The host sees one marked range. `setMarkedText` runs only when that string changes,
so a repeated preview of the same word does not touch the field again. On flush, the
mark is cleared and the text is inserted. `unmarkText` is not used, because that
would commit the mark twice. Context passed back from the proxy strips a suffix that
matches the mark, so the marked text is not counted twice.

A tapped letter appears immediately. A tap-open word is not flushed on a timer. Space,
return, punctuation, emoji, or a cursor move closes it. A swipe that joins those taps
clears typed composing so the preview can show. The first backspace after that swipe
restores the draft from before the swipe. A second backspace is an ordinary delete.
Deleting a character counts the composing text, and a field that holds only composing
still counts as non-empty, so the return key can enable.

## What the thumbs aimed at

The polyline is the finger's real path. It is not "every key the finger crossed."

`StrokeBuffer` keeps up to 256 points, dropping samples closer than 1.5 pt. Pulling
back along the path shortens it. A reversal of about one key (34 pt at the reference
width) that lands on the path already drawn, and within the lookback of that path,
drops the tail. Both distances scale with key width. Letters already entered are not
erased by that shorten. A later key that merely sits near an older part of a zigzag
is a new letter. That is why T–R–A–G–E–D stays `traged` and is not read as a retreat
through R. Past 256 points the buffer keeps every other sample.

A letter is recorded when the finger becomes closer to that key's center than to the
key it was previously aiming at. The sample used is the closest approach along the
segment, not a smoothed point. Riding a boundary does not alternate. Repeating the
current letter does nothing.

The corner is judged where the finger came nearest the key, not at the boundary where
the key was first entered. The entry sample is still on the way in. A path through the
center of V in `live` is therefore an aimed V. A graze whose closest point stays off
the center is not promoted just because a neighbor turned.

`GestureComposer` keeps every key the finger entered. It labels each one:

- **Anchor** — the start, the lift, a real corner, or a dwell. A row change is a
  corner at about 29° (`aimTurn` 0.50 rad). A wobble that stays on one QWERTY row
  needs about 69° (`sameRowTurn` 1.20 rad), so a straight run does not aim every key
  it brushes. Cold dwell is 180 ms inside a 24 pt radius, with no more than 12 pt of
  travel, both radii scaled to the key. A pause is that letter once: the beam does
  not offer a doubled letter from a dwell. `TypingRhythm` scales the dwell duration
  with the session and clamps it.
- **Crossing** — anything else. The beam may insert it. Skipping a key the path only
  grazed is cheap. Skipping one the path went through the middle of is not.
- **Tap** — a thumb that never drew. Timestamped at touch-down. Not a polyline point.

Aimed letters (anchors and taps) are what join rules and the literal fallback read.
Crossings stay on `SwipeEvidence`. A straight run across the top row does not commit
`qwertyuiop`. The decoder can still use a crossing to spell a word, which is how a
straight W→R plus a tap on E can be `were`.

`StrokeChannel` then folds on-line grazes. A crossing within 0.5 key widths of the
segment between two corners is one optional channel, not its own step. The beam skips
the channel or inserts one letter from it. A crossing that leaves that corridor stays
an event.

Return trips are collapsed before any of that labeling (`StrokeLetters`):

- A heading change of about 126° (`reversalTurn` 2.2 rad) marks a turnaround.
  Matching letters on the way out and the way back are dropped. The first letter, the
  turnaround, and the last letter stay. `tyghgyt` becomes `tht`.
- A run that goes out along one row and comes back keeps its start, its far key, and
  its end. `with` drawn out and back along the top row collapses toward W, I, T, then
  the H that leaves the row. `were` does not collapse: the retrace is the endpoint.
  `traged` does not collapse: D is a new letter, not a walk home.

The apostrophe is stripped from the aimed letters. If the stroke ends on the
apostrophe, `prefersContraction` is set and a spelling with `'` is moved ahead of the
same letters without one.

Adjacent bounces are collapsed again (`BeatChooser.collapse`): `ghghgh` becomes `gh`.

## The alignment beam

`AlignmentSearch.decode` walks a prefix index (`indices(withPrefix:)`). A hypothesis
dies when the letters so far are not a prefix of a dictionary or personal word.

The first pass walks the aimed anchors in time order. That is the spelling of an
alternating pair: `f`, `r`, `i`, `e`, `n`, `d`. A hypothesis is a word only after
every anchor has been taken or skipped. If the 12 ms clock expires first, the result
is those aimed letters, not a shorter dictionary word such as `fr`.

When the two thumbs overlap in time and the clock still has time, a chain beam walks
one cursor per thumb. Order inside a thumb stays fixed. An interleaved reading can
outrank time order when the inversion cost pays for itself. While the other thumb was
down across that event, the inversion cost is halved. Recovery, when it runs, is the
same beam with one omission and one within-chain transposition.

Each word letter is a tap, an anchor, or a letter taken from a channel. The costs
below are `AlignmentCosts.standard` unless a row says otherwise.

| Decision | Value |
| --- | --- |
| Beam width | 28, ranked by path score plus a frequency fraction and a habit-prefix fraction |
| Neighbors per event | up to 6, within 1.5 key widths, always including the letter actually hit |
| Doubled letter | allowed when the finger did not dwell; costs 0.25 (`pill` from one L) |
| Spatial model | Gaussian, σx 0.55, σy 0.40 key units. Round unless the finger is fast |
| Fast flick | speed ≥ 750 pt/s stretches σ along the direction of travel, up to 1.8×, and keeps σy tight across the stroke |
| Seam bias | 0.35 on the T/Y, G/H, and B/N midlines |
| Skip an anchor or a tap | 3.2, and at most 2, only after a letter has been placed |
| Skip budget | per thumb, not shared. One thumb's skips do not spend the other's |
| Skip a crossing | A channel costs 0.05. One key costs `0.05 + 1.15 × closeness`, where closeness is 1 at the center and 0 a key-width out. A slow trace scales that by 1.25, a fast one by 0.75 |
| Insert a crossing | Extra `0.35 ×` distance from the center, capped at 1.5 key widths. The middle of a key is cheap to take; a distant graze is not |
| Letter bigram | weight 0.30, from the lexicon, inside the word only |
| Motion | weight 0.45, travel direction versus the step from the previous key, same stroke only |
| Cross-thumb order | Time order is the first pass. When the thumbs overlap, the chain beam interleaves the thumbs and charges `min(1.6, 2.4 × seconds)`, halved while the other thumb was down. A better interleaved word may outrank time order |
| One omission | recovery pass only. Costs 1.15. One per hypothesis |
| Within-chain transpose | recovery pass only. Costs 1.15. The skipped step is still matched |
| Frequency | `0.22 ×` the word's place in the lexicon's log-count range, not the raw log count |
| Results kept | 4 on the bar, plus any reading within 1.15 of that last slot |
| Weak score | −6. At or below this, recovery may run |
| Recovery | empty, score ≤ −6, or unsure and the leader does not line up with the aimed letters. Wider neighbors (10 within 2.5 key widths), beam 48, edits on, weak shape kept as a penalty. Skipped when the 12 ms budget is already gone |

The frequency fraction is deliberate. A raw log count outweighed the path, so a common
stem such as `ve` could crowd out the letters the finger drew.

After the beam, `rescore` adds `StrokeFit` and a length cost (`lengthWeight` 1.4).
Length outside the old 0.45×–2.2× band is a cost on the sum of the strokes. It is not
a hard reject, and it is not skipped because more than one finger moved. A stroke that
already scored as a miss (−8) does not also pay the length cost. That is what keeps
an exact `cat` inside the result window.

`StrokeFit` lays the word on the strokes:

- One moving finger is scored against that polyline. Tapped letters are lifted out
  first, so the curve is judged on what the finger drew.
- Two thumbs are sequential slices when each thumb owns a run, and an interleave only
  when the two spans overlap. A non-overlapping interleave is not tried. That is what
  keeps `live` ahead of `veli`.
- A word the strokes do not explain scores as a miss (−8) and is dropped on the first
  pass. The recovery pass keeps that score as a penalty.

`PathScore` resamples both the gesture and the ideal key path to 32 points. Location
σ is 0.42, shape σ is 0.30, endpoints σ is 0.55. The score used for ranking is
pointwise. A short warp (radius 2 samples) is used only when asking whether one word's
curve sits closer than another's. Putting that warp into the ranking score made shape
words tie and dropped real readings out of the top 4.

### Example

Two thumbs spell `cat`, and one thumb skips a neighbor. Each thumb has its own skip
budget of 2. `cat` stays in the result even when several neighbor-words score a
little higher, because anything within 1.15 of the fourth slot is kept, and a miss
does not also pay length. Locked by `eachThumbKeepsItsOwnSkipBudget`.

## Shape search

The beam is a spelling search. It can miss a word whose curve is right and whose
letters were never aimed. For one moving finger and no tap, `PathDecoder.nominate`
scans first-and-last-letter buckets around the stroke's endpoints:

| Limit | Value |
| --- | --- |
| Endpoint radius | 1.25 key widths |
| Endpoint letters | 3 at each end |
| Bucket scan | 180 most frequent, then the rest only if nothing sits within 1.6 key widths |
| Nominations kept | 4 |

There is no fixed list of common curves. Any nominated word can lead.

A nomination that is merely in the neighborhood stays under the leader by the tie
margin. A word already in the beam keeps the beam's score. Either kind leads only
when its path is at least 0.35 key widths closer than the beam leader (or closer
than 0.55 when the leader has no location). That lead is capped under the leader
minus the tie margin, so a shape extra cannot spend `exactLead`. `the` drawn as a
curve beats a grazed `tre` for this reason.

A tap, or a second thumb, keeps the beam. The shape pass does not override a letter
the other thumb placed. Two-thumb words can still be nominated by joining the two
polylines, as pieces rather than as a replacement for the beam.

## Exact spelling

`ReadingPolicy` runs after the beam and the shape pass. Scores are not rewritten.
`exactLead` is 1.0.

An aimed spelling may sit up to 1.0 behind the best score and still move first.
`pill` from the keys P–I–L beats a slightly better `pull`. A doubled letter that is
much worse stays where its score put it. The comparison uses the path and the
frequency, with the habit bonus subtracted. A habit can lift a rival inside the list.
It cannot spend the margin that protects the keys the finger hit. The largest habit
is 0.45, which is inside that window.

The bar keeps four readings. Any further reading within 1.15 of that fourth score
stays in the result, so a word that spent a legal per-thumb skip is not thrown out
because several neighbor-words sat a little closer.

`WordJoiner.aligns` is the spelling rule. The word must use the aimed letters in
order. Any aimed letter may also cover one extra copy of itself (`pill` from `pil`,
`hello` from `helo`). An extra word letter that was never traced does not align, so
`love` does not align with traced `live`, and `the` does not align with `teh`.
An apostrophe does not have to be visited (`that's` lines up with `thats`).

| Situation | What is committed |
| --- | --- |
| A dictionary word aligns with the aimed letters and is within 1.0 | That word leads. Other readings stay on the bar. |
| One stroke plus taps that are a suffix, and the word matches the stroke letters alone | The word is this beat. The taps belong to the next word. |
| No dictionary word, and the cleaned trace is 2 letters or fewer | The letters themselves (`qw`). |
| No exact spelling, and the trace is longer than 2 | The nearest word. The cleaned letters are appended on the bar so a name can be tapped back. |

If the top two scores are within 0.35, the result is **unsure**. That is spelling
confidence only. `boundaryConfidence` is separate: it decides whether this beat joins
the open word. A finished word scores high, so `hello` then `correct` stay two words.
A one-letter extension scores low, so `the` + `n` can become `then` without the
spelling looking like a coin-flip.

A fragment joins even before a full dictionary word exists, when the keys actually hit
are still the start of a longer, more common word. `wa` continues toward `wait`. `the`
does not continue toward `theater`, because `the` is already the more common word.
The raw trace is never shown as that longer word: if no dictionary word covers the
keys, the letters themselves are kept so the rest can arrive (`priva` stays on screen
as `priva` until `private` is covered).

If the decoder returns nothing, the aimed letters are committed anyway, marked unsure.
One letter is inserted as a character. Two or more go through the swipe commit.

## Words typed with taps

On space, a word made only of taps becomes tap events with no polyline and runs
through `AlignmentSearch`. `TapCorrector` still runs. The typed letters change only
when one of these is true:

- The beam has a real score for the typed spelling, and the winner leads it by more
  than `exactLead`.
- The winner is the same letters in another order, and it leads the next reading by
  more than `exactLead`.

Otherwise the typed word stays, and `TapCorrector` may still apply its own single
edit. An exact name or code stays. `teh` can still become `the`, because those are
not the same letters and the corrector already knows that slip.

### Which thumb

Thumb identity is timing and side, not a learned map (`TapThumbs`). The midline is
halfway from Q to P.

- Two touches under 60 ms apart are different thumbs. One thumb cannot land twice
  that fast. The second touch takes the other thumb, even if both keys are on the
  left.
- A slower pair uses the side of the key. Left of the midline is thumb 0. Right is
  thumb 1.

Same-thumb taps stay in order. Cross-thumb taps may swap, which is how a two-thumb
tap word can still be read when the fingers overlap.

Example: taps at 0 ms, 40 ms, and 200 ms, on keys at x = 10, 12, and 200, with the
midline at 100. The thumbs are 0, 1, 1. The first two are different because 40 ms is
inside the gap. The third is thumb 1 because it is on the right and 160 ms later.
Locked by `tapsUnderSixtyMillisecondsAreDifferentThumbs`.

### Contractions

`dont`, `cant`, `wont`, and `im` are not words of their own. Space maps them to the
contraction the dictionary stores for those letters: `don't`, `can't`, `won't`,
`I'm`. Capitalization follows the typed word, so `Im` becomes `I'm`.

`its` and `it's` are both real. The typed form stays. The other form is a completion
on the strip, not a rewrite after the next word.

| Typed | On space | On the strip |
| --- | --- | --- |
| `dont` | `don't ` | the correction is highlighted, as with any unknown spelling |
| `cant` | `can't ` | same |
| `wont` | `won't ` | same |
| `im` | `I'm ` | same |
| `its` | `its ` | `it's` is offered, not applied |
| `teh` | `the ` | `TapCorrector` still owns this slip |

Locked by `correctsCommonSlips`, `mapsMissingContractions`, and
`itsStaysTypedAndOffersTheContraction`.

### A new spelling

`PersonalLexicon.learn` records a spelling on the first commit, but `contains` is
false until three uses (`usesBeforeKnown`). Until then autocorrect may still fix it.
Suggestions start at two uses (`usesBeforeSuggesting`), so a spelling can be offered
once before it is treated as known.

Tapping the literal on the bar calls `remember`, which promotes that spelling
immediately. Holding a suggestion to remember does the same.

| What the user did | Known? | Suggested? |
| --- | --- | --- |
| Typed `zorbly` once | No | No |
| Typed `zorbly` twice | No | Yes |
| Typed `zorbly` three times | Yes | Yes |
| Tapped the literal `zorbly` on the bar | Yes, at once | Yes |

Locked by `learnsAndSuggestsAfterRepeatedUse`, `unknownWordsAreLearned`, and
`rememberSuggestsOnTheFirstPinAndForgetDropsOnlyThatWord`.

## What the user has already written

Habits, rejections, and stroke memory run after the search, on the way out of
`LanguageModel`. The follower bonus is inside the search. None of them is a second
decoder.

| Memory | File | Effect |
| --- | --- | --- |
| Habits | `WordHabits.json`, cap 400 | `min(0.08 × log2(uses), 0.45)`, zero on the first use, full for 7 days, gone after 45. Added on top of corpus frequency. A prefix of a habitual word is more likely to stay in the beam. The full bonus is added once, on the finished word. |
| Word pairs | `WordPairs.json`, cap 400 | `FollowerPrior` adds 0.45 inside the decode score when the word is a follower of the previous word or the previous two. It is not a prefix and not a second ranker. Before the user has a pair, `WordContext.commonFollowers` is that same list. Between words the strip offers that follower beside the settled word. It is not highlighted, so a space does not type it. Tapping it types the word and a space. It does not replace the settled word or the history list. |
| Stroke prototypes | `StrokePrototypes.json`, cap 160 | When the user picks a different swipe candidate, 16 key-normalized samples of that polyline are stored. A later stroke within 0.42 key widths promotes that word past `exactLead`. |
| Rejections | cap 200 | If the user has insisted on `teh` over `the`, `teh` is ranked first the next time both appear. |
| Swipe refusals | cap 12 | Deleting a swipe demotes that word the next time a similar trace would have led with it. |
| Blocklist | cap 300 | Removed before the readings are shown. |
| Personal lexicon | cap 1,000 | Same prefix checks as the main lexicon once the spelling is known. Pending uses sit in the same file and are not known yet. |
| Touch offsets | `touch-offsets.jsonl` | After a committed word, one line of how far each accepted touch sat from its key center, in key widths, tagged `left` or `right`. The ranker does not read it. |
| Gesture traces | `gesture-traces.jsonl` | Written only when `recordsGestureTraces` is on. Default off. |

A period, question mark, exclamation, or newline clears recent context. Learned pairs
stay. Autocorrect runs when a word is finished by space or return, not when a swipe
commits. Accepting a swipe candidate swaps it in place and does not touch the previous
word. That swap is also what records the stroke prototype.

`LearningDirectory` writes those files to the App Group when Full Access makes it
available, and to the extension container otherwise. Settings the companion reads stay
in the App Group only.

## Stay inside a frame

`SearchClock.responseBudget` is 12 ms. The search reads the clock every fourth
expansion step and returns the best complete reading it already has. Recovery does
not start if that budget is already gone. The beam width stays 28. The budget is a
stall guard, not a reason to search more.

Release builds install that clock on `sequenceDecode` and on the async aligner.
Debug builds, including the test suite, leave the clock open, because coverage can
spend 12 ms before a short word is scored. The deadline itself is locked by
`anExhaustedClockSkipsRecovery`, which injects a clock that is already past its
deadline and checks that recovery did not run. Device milliseconds are not invented.

`TextDocumentProxyAdapter` calls `setMarkedText` only when the marked string
changes.

## Preview, commit, and the bar

While fingers are down, the coordinator asks for a preview about every 16 ms, one
decode in flight. Points that arrive during that decode wait for the next one. A
preview that returns after the fingers have lifted is dropped. An empty result on the
first few samples leaves the previous preview up, so the bar does not flash. Once the
path has grown past a preview that already had something to say, an empty decode or a
top score below `AlignmentCosts.previewFloor` (−15) takes that preview down. The trail
keeps drawing.

The preview is also the marked text in the field (`previewComposing`). On lift it is
cleared and the word is inserted once, so the ghost is not committed twice.

The strip is sticky for about 80 ms. The current leader stays unless the challenger
is ahead by at least 0.35 for that whole hold (`WordAssistant.holding`). A one-frame
lead does not swap the word under the finger. If the top two readings are within
0.35, no pill is drawn, so a close call does not look like the word a space will lock.

Tapping another preview reading moves it to the front. The callout and the lit keys
follow it. The lift commits that choice when the word is still in the result, and
`StrokeMemory` records the polyline.

On commit the editor inserts the word as one unit: a leading space when the cursor is
mid-text, then the word, then a trailing space. The word is replaced in place if a
later beat joins. Shift is applied to the committed word: first letter, or the whole
word when caps is locked. Shift is not stored per letter, so `iPhone` and
`McDonald's` are not guessed.

Unsure commits and provisional fragments (score −20) stay tentative on the bar. The
cleaned aimed letters ride at the end of the readings when they are not the chosen
word, so an unknown name can be tapped back.

The settled word stays the highlighted center. Its follower, when there is a real
preceding word, is an extra chip that is not highlighted. History on an empty field
stays the recent words. The follower does not replace them.

## A miss stays cheap

These already exist and are not part of the decoder:

- Dragging the space bar moves the cursor (`SpaceSession`).
- Sliding on backspace scrubs characters and can restore them (`BackspaceSession`,
  `DeletionScrub`). One backspace on a committed swipe removes that word. The first
  backspace after a swipe that joined a tap-open draft restores the draft (`r` after
  `rough`). The next backspace deletes as usual.
- After commit, the suggestion strip stays bound to that word
  (`WordAssistant.swipeCommitted`), so another candidate can be swapped in place.

## Closing a word

| Action | Effect |
| --- | --- |
| Last finger lifts, swipe-open | Decode and commit, with a trailing space. |
| Last finger lifts, tap-open | Stay open. A pause does not close the word. |
| Space | Commits a tap-open word. The commit's trailing space is that delimiter. |
| Return | Commits a tap-open word, then inserts a newline. |
| Punctuation | Commits a tap-open word, then types the mark. |
| Double-space period | Sentence boundary. Sparkle plays at the space bar. |
| Next stroke after a committed word | A new word. It does not rewrite the one just committed. |
| External document edit | The next letter is inserted into whatever is there now. |

A swipe-open commit inserts its trailing space, so the next word can follow.
Two swipes that are not inside one tap-open word are two words.

## Worked examples

Thumb names are the intended choreography. The engine does not know left from right
except when assigning thumbs to a tap-only word, where side is the midline between
Q and P. It otherwise knows which finger moved, which finger tapped, and the time of
each aimed letter. QWERTY, top to bottom: `Q W E R T Y U I O P`, `A S D F G H J K L`,
`Z X C V B N M`.

These must stay true. Each one is a test in `SwipeTypingTests` unless noted.

### private — RT P, LT R, RT I, LT V→A, LT T→E

Trace, in time: `p r i v a t e`.

P, R, and I are taps. V→A is a left-thumb stroke (bottom row to home row). T→E is
another left-thumb stroke along the top row, moving left. The taps latch tap-open,
so both strokes join that same word. Space commits it. The document ends as `private `.

Locked by `privateFromTapsAndTwoSwipes`.

### estranged — LT E→S, then LT T→R→A→G→E→D with RT N while the left thumb is on R/A/G/E

First beat: E→S. That span is a stroke, so the lift commits it.

Second beat: one stroke through T, R, A, G, E, D. R is a real corner between T and A
(the row-change aim threshold is there to keep that corner). G is not a retreat back
through the path already drawn. N is a tap, not a point on the polyline. It is
timestamped while the stroke is between A and G, so the reading order is
`t r a n g e d`, not `traged` with N stuck on the end. The aimed letter is always one
of the candidates, alongside up to six neighbors.

The second stroke is the next word. N still sits inside that stroke, between A and G.

Locked by `estrangedKeepsNInsideTheSecondStroke` and `aZigzagWordIsNotARetreat`.

### quit — LT Q, RT U→I, LT T

Trace: `q`, then the stroke `u i`, then `t`.

Q latches tap-open. U→I joins it, and so does T, including after a pause. Space
commits `quit `. The same rule is `r` + `ough` → `rough` in
`aPauseDoesNotCloseATapOpenedWord`.

Locked by `quitFromATapASwipeAndATap`.

### wait — LT W→A, RT I, LT T

Trace: `w a`, then `i`, then `t`.

W→A is a stroke, so the lift commits that word. I and T are the next word. A tap
during the stroke is still inside it.

If I is tapped during the stroke, it is inside that beat, at that timestamp, the same
way N sits inside `tranged`.

Locked by `waitFromASwipeAndTwoTaps`.

### pill — RT P→I→L, and a second L only if the first reading missed

P→I→L is one stroke. The ideal path of `pill` visits L once, so the shape match can
return `pill` directly. The sequence rule also allows one extra copy of an aimed
letter, so `pil` aligns with `pill`.

If the bar already shows `pill`, tapping L again starts the next word. The field is
`pill l`. The extra L is not folded back into the committed swipe.

Locked by `pillThenLStaysPill`.

### pile — RT P→I→L, LT E

Same P→I→L stroke. E is a left-thumb tap.

E can land while the stroke is still down. It is then a tap inside the beat, and the
aimed letters are `p i l e`, which align with `pile`. The path's `pill` does not win,
because a tap is part of the word when the dictionary reading uses it.

E after the lift is the next word. The field is `pill e`. E during the stroke is
still inside the beat, and the aimed letters are `p i l e`.

Locked by `pileFromASwipeAndATapDuringTheStroke` and `pilThenEBecomesPile`.

### the — one curve, not the keys T–R–E

A stroke through T and E that only grazes R is aimed `tre`. The beam can spell that
graze. The shape search finds `the` because the polyline sits on T–H–E, and that
location lead is large enough that the aligned graze cannot take the place back.

Locked by `aCommonCurveLeadsAGrazedRival`.

### live — the aimed spelling holds

An exact path through L–I–V–E aims those letters, including V, because the corner is
measured at the closest approach. `love` can be close as a shape. A habit of 0.45 on
`love` raises its score and does not replace `live`. Two thumbs spelling the same
word stay `live` rather than `veli`, because a non-overlapping interleave is not
scored.

Locked by `aRepeatedWordBeatsAnEqualShapeAndOneUseDoesNot` and
`liveBeatsVeliBecauseTheWordShapeDiffers`.

### the nice — a committed swipe does not absorb the next taps

1. Swipe `the`. The lift commits `the `.
2. Tap `n`, `i`, `c`, and `e`. They are a new tap-open word, not a rewrite of `the`.
3. The field shows `the nice` until space commits the taps.

A swipe of `correct` after `hello` is its own word. `no` + `w`, `in` + `to`, and the
other pairs that used to be blocked concatenations are two words for the same reason:
the first stroke already committed.

Locked by `theNiceUndoesAShortJoin` and `functionWordsDoNotSwallowTheNextBeat`.

## Where this is brittle

- One aimed letter may cover only one extra copy of itself. A third L will not spell
  `pill` from `pi`.
- The retreat window is one key of lookback at the reference width, scaled with the
  key. A zigzag that really does walk back through the same keys inside that window
  loses those letters.
- Each thumb has one chain, including after a lift. A third finger down at the same
  time is a tap. Order inside one thumb stays fixed. Alternating thumbs spell in
  time order (`friend`). Overlapping thumbs are also interleaved. That reading can
  pass a worse time-order word when the inversion cost pays for itself.
- A tap-open word stays open across any pause. A swipe-open word commits on the last
  lift, including a handoff that lets every finger up in the middle. A committed word
  does not grow. `the` + `n` stays `the n`.
- A preview withdraws only after the path has already produced one and then grown
  into a miss. The first samples still keep the previous pill.
- Joining still requires the aimed letters in order. A crossing can fill a hole.
  Two thumbs that overlap are interleaved by the chain beam. A time-order word that
  already matches the aimed letters still wins when the inversion does not pay for itself.
- The shape lead stays under the tie margin on purpose. Loosening `exactLead` would
  let a habit or a graze replace an aimed spelling.
- Stroke memory promotes past `exactLead` as well, and only after the user has
  already rejected the keyboard's choice for that curve. A prototype match of 0.42
  key widths is tight; a sloppy repeat of a different word should not hit it.
- The fast-flick stretch starts at 750 pt/s. Below that the Gaussian stays round.
  Stretching ordinary traces reshuffles close spellings such as `live` / `love`.
- The 12 ms cutoff is a release stall guard. A debug or coverage run does not apply
  it. An injected clock is how the cutoff is tested. A search that stops before every
  anchor is taken returns the aimed letters, not a shorter dictionary word.

## Where to look

| Concern | Type |
| --- | --- |
| Tap-open versus swipe-open | `WordSession`, `Timeline`, `GestureSegmenter` |
| When a touch becomes a stroke, cancel, rest | `SwipeSession` |
| Two chains, holds, preview cadence, commit | `SwipeCoordinator`, `AlignmentPathMatcher` |
| Anchors, crossings, closest approach, dwell, third finger as a tap | `GestureComposer` in `StrokeAnalyzer.swift` |
| Return trips and same-row collapses | `StrokeLetters` |
| Channels between corners | `StrokeChannel` |
| Retreat distances | `StrokeBuffer` in `SwipeGesture.swift` |
| Beam, chains, recovery, exact-lead policy, 12 ms clock | `AlignmentSearch`, `SearchClock`, `ThumbChains`, `ReadingPolicy` in `AlignmentDecoder.swift` |
| Optional decode trace | `DecodeTrace`. Off unless `recordsGestureTraces` is on, or a test passes a `DecodeTraceSink` |
| Polyline score | `PathScore`, `StrokeFit` |
| Endpoint-bucket nominations | `PathDecoder.nominate` |
| Tap thumbs | `TapThumbs` |
| Tap autocorrect, contractions | `TapCorrector` |
| Habits, pairs, remembered curves | `HabitMemory`, `WordContext`, `StrokeMemory` |
| Pending spellings | `PersonalLexicon` |
| Touch offsets and gesture traces | `TouchOffsetLog`, `GestureTraceLog` in `LocalLearningLog.swift` |
| Composing text, applying session effects, undoing a swipe chunk | `KeyboardEngine`, `ChunkHistory`, `TextEditor`, `TextDocument` |
| Docked, floating, and split frames | `KeyboardPlacement`, `KeyboardGeometry` |
| Marked text | `TextDocumentProxyAdapter` |
| Suggestion strip | `WordAssistant` |
| Space-bar cursor, backspace scrub | `SpaceSession`, `BackspaceSession` |

Accuracy floor: `PathDecoderTests.gestureClassesDecodeAboveTheFloor` and
`decodesTheMostCommonWords` (≥ 90% top-1 and ≥ 98% top-4 on the 500 most common
words with seeded noise). The perturbation set
(`perturbationSetKeepsCleanWordsAndClassifiesTheRest`) reports recall, rank,
boundary, and classification on top of that floor. A delayed second thumb is
`aDelayedSecondThumbStillDecodes`. Timing: `PathDecoderTests.decodesFastEnough`.
The stall guard is `anExhaustedClockSkipsRecovery`.
