# Swipe engine

Review reference for the current English swipe decoder. It describes the behavior in
the tree, the numbers that are hand-set, and the cases the tests lock. It is not a
roadmap. The choices that set that behavior are in `docs/swipe-decisions.md`.

Swipe runs only when `KeyboardSettings.typingMode` is `.swipe`, a language model is
loaded, and the field's traits allow it (`KeyboardEngine.applySettings`). It runs on
the letters layer. A finger on a non-letter never becomes a stroke.

Decode budget and memory limits are in `docs/PERF.md`. The release target is 15 ms
off the main thread. The mapped lexicon does not count toward the extension's dirty
memory.

## What this engine does, and what it does not

One beat can mix taps and strokes. While either thumb is down, those inputs are one
word. The leading word is shown in the field during the stroke and committed in place
on lift. A single clean curve can search the lexicon by shape. A repeated word, a
remembered curve, and a familiar follower can break a close call. They cannot replace
a spelling the keys actually aimed at.

Intentionally absent:

- The lexicon is unigram. Letter bigrams are used only inside a word, as a spelling
  prior. Between words, one follower sits beside the word that just finished. It is
  not highlighted, and there is no second suggestion row.
- The previous word is not fed into the two-thumb beam as a prefix.
- There is no clipboard history, no iCloud sync of learned words, and no jump into
  the system emoji keyboard. The public input-mode API only advances to the next
  keyboard.
- A permanent number row is not part of this layout.

## Pipeline

```
touches
  → ThumbChains               one chain per stroke, order inside a chain fixed
  → SwipeCoordinator          one beat: strokes, held letters, taps
  → GestureComposer           anchors, crossings, taps, aimed letters
  → AlignmentDecoder (actor)  off the main thread
       1. beam over the chains
       2. rescore with the polyline
       3. expected followers, if the stroke fits them
       4. shape nominations for one clean curve
       5. follower bonus, then ReadingPolicy
       6. the same search again, with recovery costs, only when that result is weak
  → LanguageModel.finish      blocklist, rejections, familiar words, stroke memory
  → field                     preview composing while down, commit on lift
```

`KeyboardEngine` stores each beat as an `OpenBeat`: the keys and a point-capped copy
of each polyline. A later beat that joins the open word calls
`LanguageModel.sequenceDecode` with those paths, which runs this same search.
`sequenceDecode` is not a second decoder. Every hand-set search number lives on
`AlignmentCosts`. `AlignmentCosts.recovery` is the wider second pass.

## What a finger is

Every finger that lands on a letter starts as a tap (`CharacterTapSession`). It
becomes a stroke when any of these is true (`SwipeSession`):

| Condition | Threshold |
| --- | --- |
| Sideways travel | 16 pt |
| Finger leaves the key's hit frame | immediately |
| Travel in any direction, including straight down | 36 pt |

A short downward dip that stays on the key remains a flick, not a stroke. A slide
along the shortcut row is choosing an accent, not drawing. If the shortcut row is
already open, the other thumb's word still receives the letter that was held.

Two letter fingers can be down together. Neither types until one of them travels.
The finger that travels starts the gesture and enlists the other:

- A partner that has already moved joins as another stroke.
- A partner still on its key becomes a held letter. It is one character in this
  word, timestamped at touch-down, and it is not a point on the polyline.
- If that held finger later travels, the hold is dropped and it becomes a stroke of
  the same beat.
- If it lifts without traveling, the letter is kept as a tap in the beat.

A tap with no swipe in progress is held as composing text, not inserted as a finished
character. See [The word stays open](#the-word-stays-open). A tap that lands and lifts
while a beat is already open is recorded inside that beat. The beat commits when the
last finger lifts: no active stroke and no held letter
(`SwipeCoordinator.finishIfIdle`).

Cancelling a stroke resets the whole gesture and cancels its composer ticket.

## One beat, then the leash

A **beat** is everything collected under one composer ticket: the moving strokes, the
letters held down, and the taps that lifted while those fingers were down. Strokes are
ordered by when each finger lifted. Taps and stroke letters are then merged by time,
so a letter tapped in the middle of the other thumb's stroke lands in the middle of
the word, not at the end.

The ticket is taken from the first stroke's tap session. A letter tapped before the
swipe can land before the swiped word. A letter tapped after waits until the decoder
returns, because the composer will not apply a later intent in front of an open ticket.

After a beat commits, the word stays **open** for a leash. Cold start is
`KeyboardEngine.wordLeash` (340 ms). After four inter-key gaps, `TypingRhythm` scales
that leash from the session's pace and clamps it between 160 ms and 550 ms. A finger
still down holds the leash open (`openDeadline = .infinity`) and the leash restarts
when that finger lifts. While the word is open, another tap or swipe can rewrite it
instead of starting the next word. Space, return, an external edit, or the leash
expiring closes it.

`KeyboardSettings.swipeCommitMode` defaults to `.lift`, which is this behavior. The
other mode, `.explicitSpace`, keeps one word open until space, return, or an external
edit. Lift still inserts the trailing space. A later beat replaces that word in place.

`extendFinishedWords` (default on) is the other gate. A word the fingers have actually
spelled can still grow from a quick tap that is not itself a word (`the` + `n` →
`then`). It will not be rewritten by a beat that already has its own reading (`hello`
then `correct` stay two words; `in` then `to` do not become `into`). A fragment that
is only a prefix (`es`, `wa`, `priva`) stays open for the leash even when the bar is
already showing a longer dictionary word. Turning `extendFinishedWords` off makes the
next tap a new word immediately.

A completion that runs ahead of the keys is not finished. `priva` shown as `private`
stays open so `te` can still arrive. A shape match that is a different word is
finished: `pull` for a P–I–L path will not silently keep absorbing letters as if it
were still `pil`.

## The word stays open

Tapped letters and the swipe preview are composing text, not a commit followed by an
erase.

| Layer | When it shows | Counts as the open word? |
| --- | --- | --- |
| `typedComposing` | Letters held while no swipe preview is up | Yes. Shift, the current word, and backspace see it. |
| `previewComposing` | The swipe leader, and only while typed composing is empty | No. It is the ghost in the field. |

The host sees one marked range (`setMarkedText`). On flush, the mark is cleared and
the text is inserted. `unmarkText` is not used, because that would commit the mark
twice. Context passed back from the proxy strips a suffix that matches the mark, so
the marked text is not counted twice.

A tapped letter appears immediately and is flushed after `wordLeash`, or sooner on
space, punctuation, emoji, or a cursor move. A swipe preview cancels that flush. The
taps stay peelable until the swipe commit replaces them. Backspace peels typed
composing before it touches the document.

## What the thumbs aimed at

The polyline is the finger's real path. It is not "every key the finger crossed."

`StrokeBuffer` keeps up to 256 points, dropping samples closer than 1.5 pt. Pulling
back along the path shortens it. A reversal of about one key (34 pt) that lands on the
path already drawn, and within the last 120 pt of that path, drops the tail. Letters
already entered are not erased by that shorten. A later key that merely sits near an
older part of a zigzag is a new letter. That is why T–R–A–G–E–D stays `traged` and is
not read as a retreat through R. Past 256 points the buffer keeps every other sample.

A letter is recorded when the finger becomes closer to that key's center than to the
key it was previously aiming at. Riding a boundary does not alternate. Repeating the
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
  travel. A pause is that letter once: the beam does not offer a doubled letter from
  a dwell. `TypingRhythm` scales the dwell with the session and clamps it.
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
| Cross-thumb order | order inside one chain is fixed. Up to six chain-legal adjacent swaps are each walked on their own, so a skip is not crowded out. A gap the swap window cannot reach falls through to the chain beam, which charges `min(1.6, 2.4 × seconds)`. There is no 18-event cliff |
| One omission | recovery pass only. A vowel costs 1.15, any other letter 1.40. One per hypothesis |
| Within-chain transpose | recovery pass only. Costs 1.15. The skipped step is still matched |
| Frequency | `0.22 ×` the word's place in the lexicon's log-count range, not the raw log count |
| Results kept | 4 on the bar, plus any reading within 1.15 of that last slot |
| Recovery | empty, score ≤ −6, or a tie whose leader is not the aimed spelling. Wider neighbors (10 within 2.5 key widths), beam 48, edits on, weak shape kept as a penalty |

The frequency fraction is deliberate. A raw log count outweighed the path, so a common
stem such as `ve` could crowd out the letters the finger drew.

After the beam, `rescore` adds `StrokeFit` and a length cost (`lengthWeight` 1.4).
Length outside the old 0.45×–2.2× band is a cost on the sum of the strokes. It is not
a hard reject, and it is not skipped because more than one finger moved. A stroke that
already scored as a miss does not also pay the length cost.

`StrokeFit` lays the word on the strokes:

- One moving finger is scored against that polyline. Tapped letters are lifted out
  first, so the curve is judged on what the finger drew.
- Two thumbs are sequential slices when each thumb owns a run, and an interleave only
  when the two spans overlap. A non-overlapping interleave is not tried. That is what
  keeps `live` ahead of `veli`.
- A word the strokes do not explain scores as a miss (−8) and is dropped on the first pass. The recovery pass keeps that score as a penalty.

`PathScore` resamples both the gesture and the ideal key path to 32 points. Location
σ is 0.42, shape σ is 0.30, endpoints σ is 0.55. The score used for ranking is
pointwise. A short warp (radius 2 samples) is used only when asking whether one word's
curve sits closer than another's. Putting that warp into the ranking score made shape
words tie and dropped real readings out of the top 4.

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

A nomination that is merely in the neighborhood stays just outside the tie margin
(leader score − 0.35 − 0.01). A word already in the beam keeps the beam's score.
Either kind leads only when its path is at least 0.35 key widths closer than the beam
leader (or closer than 0.55 when the leader has no location). That lead is raised to
`leader + exactLead + 0.01`, so a graze that merely lines up with the aimed letters
cannot take the place back. `the` drawn as a curve beats a grazed `tre` for this
reason.

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
`love` does not align with traced `live`. An apostrophe does not have to be visited
(`that's` lines up with `thats`).

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
| Personal lexicon | cap 1,000 | Same prefix checks as the main lexicon, with their own log count. A new word is learned when a typed word ends and it is not a known correction. |

A period, question mark, exclamation, or newline clears recent context. Learned pairs
stay. Autocorrect runs when a word is finished by space or return, not when a swipe
commits. Accepting a swipe candidate swaps it in place and does not touch the previous
word. That swap is also what records the stroke prototype.

`LearningDirectory` writes those files to the App Group when Full Access makes it
available, and to the extension container otherwise. Settings the companion reads stay
in the App Group only.

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
word when caps is locked.

Unsure commits and provisional fragments (score −20) stay tentative on the bar. The
cleaned aimed letters ride at the end of the readings when they are not the chosen
word, so an unknown name can be tapped back.

## A miss stays cheap

These already exist and are not part of the decoder:

- Dragging the space bar moves the cursor (`SpaceSession`).
- Sliding on backspace scrubs characters and can restore them (`BackspaceSession`,
  `DeletionScrub`). One backspace on a single swipe removes the whole word. When the
  open word has more than one chunk, backspace peels the last thumb action (a joined
  `rough` steps back to `r`, then to empty).
- After commit, the suggestion strip stays bound to that word
  (`WordAssistant.swipeCommitted`), so another candidate can be swapped in place.

## Closing a word

| Action | Effect |
| --- | --- |
| Last finger lifts | Decode and commit this beat. The word stays open for the leash, unless explicit space is on, in which case it stays open. |
| Space | Flushes composing, closes the open word, finishes it (autocorrect may apply), inserts a space. |
| Return | Closes the open word, finishes it with no extra trailing space, inserts a newline, ends the sentence context. |
| Double-space period | Sentence boundary. Sparkle plays at the space bar. |
| Next beat has its own reading, or the leash expired | The open word locks. The new beat is the next word, with its own leading space. |
| External document edit | The open word locks. The next letter is inserted into whatever is there now. |
| Our own echo of the commit | The word stays open. A host echoing `pil ` back does not break a following `e` into a new word. |

A confident swipe always inserts its trailing space, so the next word can follow.
Two swipes of real words are two words. A one-letter swipe is not pulled into the
next swipe.

## Worked examples

Thumb names are the intended choreography. The engine does not know left from right.
It knows which finger moved, which finger tapped, and the time of each aimed letter.
QWERTY, top to bottom: `Q W E R T Y U I O P`, `A S D F G H J K L`, `Z X C V B N M`.

These must stay true. Each one is a test in `SwipeTypingTests` unless noted.

### private — RT P, LT R, RT I, LT V→A, LT T→E

Trace, in time: `p r i v a t e`.

P, R, and I are taps. V→A is a left-thumb stroke (bottom row to home row). T→E is
another left-thumb stroke along the top row, moving left. They may be one beat, if
the taps happen while a stroke is down, or several beats inside the 340 ms leash.
Either way they join, because each prefix is the start of a longer common word.
`priva` may already display as `private` before T→E arrives. That display is a
completion running ahead of the keys, so the word is still open and T→E is absorbed.
The document ends as `private `.

Locked by `privateFromTapsAndTwoSwipes`.

### estranged — LT E→S, then LT T→R→A→G→E→D with RT N while the left thumb is on R/A/G/E

First beat: E→S. `es` is a fragment, so it stays open.

Second beat: one stroke through T, R, A, G, E, D. R is a real corner between T and A
(the row-change aim threshold is there to keep that corner). G is not a retreat back
through the path already drawn. N is a tap, not a point on the polyline. It is
timestamped while the stroke is between A and G, so the reading order is
`t r a n g e d`, not `traged` with N stuck on the end. The aimed letter is always one
of the candidates, alongside up to six neighbors.

The two beats join inside the leash: `es` + `tranged` → `estranged `.

Locked by `estrangedKeepsNInsideTheSecondStroke` and `aZigzagWordIsNotARetreat`.

### quit — LT Q, RT U→I, LT T

Trace: `q`, then the stroke `u i`, then `t`.

Q and T are taps. U→I is one right-thumb stroke. In one beat they are three
observations in time order. As separate beats they still join: `qui` is a prefix of
a longer word, and `t` completes `quit`. The document ends as `quit `.

A slow Q, past the leash, does not join. `aSlowTapDoesNotJoinTheFollowingSwipe`
locks the same rule for `r` + `ough`.

Locked by `quitFromATapASwipeAndATap`.

### wait — LT W→A, RT I, LT T

Trace: `w a`, then `i`, then `t`.

W→A is one stroke. I and T are taps. I may land during the stroke or just after it.
`wa` is not a finished word that should lock: a longer dictionary word with that
prefix is more common, so the fragment continues. I and T rewrite it to `wait `.

If I is tapped during the stroke, it is inside that beat, at that timestamp, the same
way N sits inside `tranged`.

Locked by `waitFromASwipeAndTwoTaps`.

### pill — RT P→I→L, and a second L only if the first reading missed

P→I→L is one stroke. The ideal path of `pill` visits L once, so the shape match can
return `pill` directly. The sequence rule also allows one extra copy of an aimed
letter, so `pil` aligns with `pill`.

If the bar already shows `pill`, tapping L again stays `pill `. The extra L is the
allowed double, not a new word and not `pilll`.

Locked by `pillThenLStaysPill`.

### pile — RT P→I→L, LT E

Same P→I→L stroke. E is a left-thumb tap.

E can land while the stroke is still down. It is then a tap inside the beat, and the
aimed letters are `p i l e`, which align with `pile`. The path's `pill` does not win,
because a tap is part of the word when the dictionary reading uses it.

E can also land after the lift, inside the leash. `pill` from `pil` counts as spelled,
but `extendFinishedWords` still allows a tap that is not its own word to lengthen it.
`pile` aligns with `pil` + `e`. The document ends as `pile `.

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

## Where this is brittle

- One aimed letter may cover only one extra copy of itself. A third L will not spell
  `pill` from `pi`.
- The retreat window is 120 pt. A zigzag that really does walk back through the same
  keys inside that window loses those letters.
- Cross-hand order is a chain-legal swap inside the rhythm's window, walked as its own
  beam, or the chain beam when that window cannot reach. Order inside one thumb stays fixed.
- The leash starts at 340 ms and then follows the typist. A finished word can still
  grow. `the` + a quick `n` becomes `then`. That is intended, and it is also how a
  deliberate second word gets eaten if it is typed immediately and is not itself a
  confident swipe. Explicit space turns that choice off.
- A preview withdraws only after the path has already produced one and then grown
  into a miss. The first samples still keep the previous pill.
- Joining still requires the aimed letters in order. A crossing can fill a hole.
  A tap and a stroke that land inside the swap window can be read either way.
- The shape lead clears `exactLead` on purpose. It fires only when the curve is
  clearly closer and there is a single moving finger. Loosening `exactLead` would
  let a habit or a graze replace an aimed spelling. Tightening it would let the graze
  take `the` back.
- Stroke memory promotes past `exactLead` as well, and only after the user has
  already rejected the keyboard's choice for that curve. A prototype match of 0.42
  key widths is tight; a sloppy repeat of a different word should not hit it.
- The fast-flick stretch starts at 750 pt/s. Below that the Gaussian stays round.
  Stretching ordinary traces reshuffles close spellings such as `live` / `love`.

## Where to look

| Concern | Type |
| --- | --- |
| When a touch becomes a stroke, preview cadence, commit | `SwipeCoordinator`, `SwipeSession` |
| Anchors, crossings, closest approach, dwell | `GestureComposer` in `StrokeAnalyzer.swift` |
| Return trips and same-row collapses | `StrokeLetters` |
| Channels between corners | `StrokeChannel` |
| Beam, chains, recovery, exact-lead policy | `AlignmentSearch`, `ThumbChains`, `ReadingPolicy` in `AlignmentDecoder.swift` |
| Optional decode trace | `DecodeTrace`. Off unless a test passes a `DecodeTraceSink` |
| Polyline score | `PathScore`, `StrokeFit` |
| Endpoint-bucket nominations | `PathDecoder.nominate` |
| Habits, pairs, remembered curves | `HabitMemory`, `WordContext`, `StrokeMemory` |
| Composing text and the leash | `KeyboardEngine`, `TextEditor`, `TextDocument` |
| Suggestion strip | `WordAssistant` |
| Space-bar cursor, backspace scrub | `SpaceSession`, `BackspaceSession` |

Accuracy floor: `PathDecoderTests.gestureClassesDecodeAboveTheFloor` and
`decodesTheMostCommonWords` (≥ 90% top-1 and ≥ 98% top-4 on the 500 most common
words with seeded noise). The perturbation set
(`perturbationSetKeepsCleanWordsAndClassifiesTheRest`) reports recall, rank,
boundary, and classification on top of that floor. A delayed second thumb is
`aDelayedSecondThumbStillDecodes`. Timing: `PathDecoderTests.decodesFastEnough`.
