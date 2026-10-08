# Swipe engine

How a swipe becomes a word, as the engine behaves today. This is the reference for
changes and for spotting where a gesture went wrong. The worked examples at the end are
locked by `SwipeTypingTests`.

Swipe is on only when `KeyboardSettings.typingMode` is `.swipe`, a language model is
loaded, and the field's traits allow it (`KeyboardEngine.applySettings`). It runs on the
letters layer. A finger on a non-letter never becomes a stroke.

## What a finger is

Every finger that lands on a letter starts as a tap (`CharacterTapSession`). It becomes
a stroke when any of these is true (`SwipeSession`):

| Condition | Threshold |
| --- | --- |
| Sideways travel | 16 pt |
| Finger leaves the key's hit frame | immediately |
| Travel in any direction, including straight down | 36 pt |

A short downward dip that stays on the key remains a flick, not a stroke. A slide along
the shortcut row is choosing an accent, not drawing. If the shortcut row is already
open, the other thumb's word still receives the letter that was held.

Two letter fingers can be down together. Neither types until one of them travels. The
finger that travels starts the gesture and enlists the other:

- A partner that has already moved joins as another stroke.
- A partner still on its key becomes a held letter. It is one character in this word,
  timestamped at touch-down, and it is not a point on the polyline.
- If that held finger later travels, the hold is dropped and it becomes a stroke of the
  same beat.
- If it lifts without traveling, the letter is kept as a tap in the beat.

A tap with no swipe in progress types as a normal letter. A tap that lands and lifts
while a beat is already open is recorded as a tap inside that beat, not as its own
character. The word is committed when the last finger lifts: no active stroke and no
held letter (`SwipeCoordinator.finishIfIdle`).

Cancelling a stroke resets the whole gesture and cancels its composer ticket.

## One beat, then the leash

A **beat** is everything collected under one composer ticket: the moving strokes, the
letters held down, and the taps that lifted while those fingers were down. Strokes are
ordered by when each finger lifted. Taps and stroke letters are then merged by time, so
a letter tapped in the middle of the other thumb's stroke lands in the middle of the
word, not at the end.

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

`GestureComposer` keeps every key the finger entered. It labels each one:

- **Anchor** — the start, the lift, a turn of at least about 25° (`aimTurn` 0.45 rad),
  or a dwell. Cold dwell is 180 ms inside a 24 pt radius, with no more than 12 pt of
  travel. `TypingRhythm` scales that dwell with the session and clamps it.
- **Crossing** — anything else. The beam may insert it. Skipping a key the path only
  grazed is cheap. Skipping one the path went through the middle of is not.
- **Tap** — a thumb that never drew. Timestamped at touch-down. Not a polyline point.

Aimed letters (anchors and taps) are what join rules and the literal fallback read.
Crossings stay on `SwipeEvidence` and are not typed on their own, so a straight run
across the top row still does not commit `qwertyuiop`. The decoder can still use a
crossing to spell a word, which is how a straight W→R plus a tap on E can be `were`.

A return trip is collapsed separately (`StrokeLetters`). A heading change of about
126° (`reversalTurn` 2.2 rad) marks a turnaround. Matching letters on the way out and
the way back are dropped. The first letter, the turnaround, and the last letter stay.
`tyghgyt` becomes `tht`. The apostrophe is stripped from the aimed letters. If the
stroke ends on the apostrophe, `prefersContraction` is set and a spelling with `'`
is moved ahead of the same letters without one.

Adjacent bounces are collapsed again (`BeatChooser.collapse`): `ghghgh` becomes `gh`.
A bounced pair is the same letter, the one before it, then that letter again.

## One alignment decoder

`KeyboardEngine.decode` calls `AlignmentDecoder` once, off the main thread. A join
that no longer has the polylines calls the same search synchronously
(`LanguageModel.sequenceDecode`). Every hand-set number lives on `AlignmentCosts`.

Search walks the lexicon prefix index (`indices(withPrefix:)`). A hypothesis dies
when the letters so far are not a prefix of a dictionary or personal word. There is
no first/last-letter bucket and no 180-word scan, so a frequent near-miss cannot
hide a rarer word the beam already reached.

Each word letter is a tap, an anchor, or a crossing:

- Beam width 28.
- Each event tries up to 6 keys within 1.5 key-widths, and always includes the letter
  the thumb actually hit or crossed.
- A letter may be inserted once or twice. The double costs 0.25, which is how one
  visit to L can spell `pill`.
- Spatial cost uses separate horizontal and vertical sigmas (0.55 and 0.40 key
  units). On the T/Y, G/H, and B/N seams, a touch on the wrong side of the G/H
  midline pays a small extra penalty.
- Skipping an anchor or a tap costs 3.2, and at most two such skips are allowed,
  only after a letter has already been placed. Skipping a crossing is cheap when
  the path only grazed the key.
- Inserting a crossing is what lets a straight W→R plus a tap on E spell `were`.
- A letter bigram learned from the dictionary (weight 0.30) and the direction of
  travel versus the step from the previous key (weight 0.45, same stroke only)
  adjust the score.
- Adjacent events from different fingers inside about 70 ms may be read in either
  order. The penalty shrinks as the gap shrinks. `TypingRhythm` scales that window
  and clamps it between 40 ms and 120 ms. This is a local swap, not a shuffle of
  whole strokes.
- Frequency prior is `0.22 × log count`.

After the beam, survivors are rescored with `PathScore`: location (σ 0.42), shape
(σ 0.30), and endpoints (σ 0.55), the same channels the older path decoder used.
Shape is matched to the letters that stroke explains, including a mid-word fragment.
With two moving thumbs, a word that cannot be laid onto every thumb's polyline pays
for that. Length outside the old 0.45×–2.2× band is a cost on the sum of the
strokes, including multi-stroke words. It is no longer a hard reject, and it is no
longer skipped just because more than one finger moved.

`ReadingPolicy` then applies the product rules that stay outside the beam. Scores
are not inflated to fake a margin.

| Situation | What is committed |
| --- | --- |
| A dictionary word uses the aimed letters in order (one double allowed) | That word leads. Other readings stay on the bar. |
| One stroke plus taps that are a suffix, and the word matches the stroke letters alone | The word is this beat. The taps belong to the next word. |
| No dictionary word, and the cleaned trace is 2 letters or fewer | The letters themselves (`qw`). |
| No exact spelling, and the trace is longer than 2 | The nearest word. The cleaned letters are appended on the bar so a name can be tapped back. |

If the top two scores are within 0.35, the result is **unsure**. That is spelling
confidence only. `boundaryConfidence` is separate: it decides whether this beat joins
the open word. A finished word scores high, so `hello` then `correct` stay two words.
A one-letter extension scores low, so `the` + `n` can become `then` without the
spelling looking like a coin-flip.

Blocklist, rejection memory, and word context are applied on the way out. Context can
promote a follower of the previous word, or of the previous two words, when it was
already close. After a sentence, only sentence-starting words can break that tie.

`PathDecoder` remains for the continuous-swipe accuracy tests. Live typing does not
call it. The path-versus-sequence table and the after-the-fact thumb reorder are gone.

`WordJoiner.aligns` is the spelling rule used everywhere a later beat tries to join.
The word must use the aimed letters in order. Any aimed letter may also cover one
extra copy of itself (`pill` from `pil`, `hello` from `helo`). An apostrophe does not
have to be visited (`that's` lines up with `thats`). Skipping a new letter to keep the
old word does not join. Rewriting an earlier letter into a neighbor (`hello` + `x`
→ `helix`) does not join.

A fragment joins even before a full dictionary word exists, when the keys actually hit
are still the start of a longer, more common word. `wa` continues toward `wait`. `the`
does not continue toward `theater`, because `the` is already the more common word.
The raw trace is never shown as that longer word: if no dictionary word covers the
keys, the letters themselves are kept so the rest can arrive (`priva` stays on screen
as `priva` until `private` is covered).

If the decoder returns nothing, the aimed letters are committed anyway, marked unsure.
One letter is inserted as a character. Two or more go through the swipe commit. A
return trip has already been removed, so it cannot be typed back.

## Preview, commit, and the bar

While fingers are down, the coordinator asks for a preview at most every 50 ms, one
in flight. Points that arrive during the wait are batched. A preview that returns
after the fingers have lifted is dropped. An empty result on the first few samples
leaves the previous preview up, so the bar does not flash. Once the path has grown
past a preview that already had something to say, an empty decode or a top score
below `AlignmentCosts.previewFloor` takes that preview down. The trail keeps drawing.

The preview fills the suggestion strip and is tentative. If the top two readings are
within 0.35, no pill is drawn, so a close call does not look like the word a space
will lock. Tapping another preview reading moves it to the front, and the callout and
the lit keys follow it. The lift commits that choice when the word is still in the
result.

On commit the editor inserts the word as one unit: a leading space when the cursor is
mid-text, then the word, then a trailing space. The word is replaced in place if a
later beat joins. Backspace peels the last thumb action when the open word has more
than one chunk (a joined `rough` steps back to `r`, then to empty). One backspace on
a single swipe removes the whole word. A rightward scrub on backspace can restore it.
The gust effect plays the deleted word only when a whole word was removed.

Unsure commits and provisional fragments (score −20) stay tentative on the bar. The
cleaned aimed letters ride at the end of the readings when they are not the chosen
word, so an unknown name can be tapped back.

Shift is applied to the committed word: first letter, or the whole word when caps is
locked.

## Dictionary behavior around a swipe

- **Lexicon.** Memory-mapped, about 100k words. The alignment beam searches by
  prefix, so a hypothesis must be a real prefix.
- **Frequency.** The beam adds `0.22 × log count`. Common words win ties.
- **Personal words.** Up to 1,000 learned spellings. They are scored in the same
  buckets or prefix checks, with their own log count. A new word is learned when a
  typed word ends and it is not a known correction. A swipe the user then replaces
  is remembered: one swap pins the preferred spelling and rejects the one the
  keyboard chose, so the next similar aim can find a word the dictionary does not
  have.
- **Blocklist.** A blocked word is removed from readings before they are shown.
- **Rejections.** If the user has insisted on `teh` over `the`, `teh` is ranked
  first the next time both appear.
- **Context.** The word just committed, and the pair before it, can promote a
  follower that was already a close score. A period, question mark, exclamation, or
  new line clears that recent context. Learned pairs stay.
- **Autocorrect** runs when a word is finished by space or return, not when a swipe
  commits. A swipe's own readings are the candidates. Accepting one swaps it in
  place and does not touch the previous word.

## Closing a word

| Action | Effect |
| --- | --- |
| Last finger lifts | Decode and commit this beat. The word stays open for the leash, unless explicit space is on, in which case it stays open. |
| Space | Closes the open word, finishes it (autocorrect may apply), inserts a space. |
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

These must stay true. Each one is a test in `SwipeTypingTests`.

### private — RT P, LT R, RT I, LT V→A, LT T→E

Trace, in time: `p r i v a t e`.

P, R, and I are taps. V→A is a left-thumb stroke (bottom row to home row). T→E is
another left-thumb stroke along the top row, moving left. They may be one beat, if
the taps happen while a stroke is down, or several beats inside the 340 ms leash.
Either way they join, because each prefix is the start of a longer common word.
`priva` may already display as `private` before T→E arrives. That display is a
completion running ahead of the keys, so the word is still open and T→E is absorbed.
The document ends as `private `.

Locked by `privateFromTapsAndTwoSwipes` (the taps and the two swipes are sequential).

### estranged — LT E→S, then LT T→R→A→G→E→D with RT N while the left thumb is on R/A/G/E

First beat: E→S. `es` is a fragment, so it stays open.

Second beat: one stroke through T, R, A, G, E, D. R is a real corner between T and A
(the 25° aim threshold is there to keep that corner). G is not a retreat back through
the path already drawn. N is a tap, not a point on the polyline. It is timestamped
while the stroke is between A and G, so the reading order is `t r a n g e d`, not
`traged` with N stuck on the end. "Vaguely close" means N only has to be the letter
aimed at in that window. The alignment beam also considers the six nearest keys, but
the aimed letter is always one of the candidates.

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

Locked by `waitFromASwipeAndTwoTaps` (I and T after the stroke has lifted).

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

## Where this is brittle

- One aimed letter may cover only one extra copy of itself. A third L will not spell
  `pill` from `pi`.
- The retreat window is 120 pt. A zigzag that really does walk back through the same
  keys inside that window loses those letters.
- Cross-hand order is only an adjacent swap inside the rhythm's window. Two fingers
  that land further apart stay in time order. A gesture with more than 18 events is
  read in time order only.
- The leash starts at 340 ms and then follows the typist. A finished word can still
  grow. `the` + a quick `n` becomes `then`. That is intended, and it is also how a
  deliberate second word gets eaten if it is typed immediately and is not itself a
  confident swipe. Explicit space turns that choice off.
- A preview withdraws only after the path has already produced one and then grown
  into a miss. The first samples still keep the previous pill.
- Joining still requires the aimed letters in order. A crossing can fill a hole.
  A tap and a stroke that land inside the swap window can be read either way.
