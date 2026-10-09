# Swipe decisions

Pivotal choices for the English swipe decoder. Each entry is the rule we ship, the
alternative we rejected, and the test that locks it. Public Nintype behavior is the
reference for feel. We do not have that keyboard's source, so none of these claims
to be its algorithm.

## A clean hit stays aimed

A spelling the keys actually hit stays first when it is a solid explanation of the
gesture. `ReadingPolicy.exactLead` is 1.0. A habit, at most 0.45, is subtracted
before that comparison, so it can lift a rival in the list and cannot spend the
margin. An exact path through `live` stays `live`.

Rejected: always taking the dictionary word that best explains the gesture. That
would let `love` replace an exact `live`.

Locked by `aRepeatedWordBeatsAnEqualShapeAndOneUseDoesNot`.

## A weak hit may be forgiven

When the first result is empty, tied (top two within 0.35), or scored below −6, the
same search runs again with `AlignmentCosts.recovery`: more neighbors, a wider
radius, one omitted letter, one within-chain transposition, and no hard shape drop.
Omission and transposition cost more than `exactLead`, so they cannot dethrone a
solid aimed spelling on the first pass. A curve that sits at least 0.35 key widths
closer than the beam leader still leads on the first pass. That lead is one moving
finger and no tap.

Rejected: running the wide search on every gesture, and turning `WordJoiner.aligns`
into a soft cost.

Locked by `aCommonCurveLeadsAGrazedRival` and `gestureClassesDecodeAboveTheFloor`.

## Thumb order is a chain, not a list of swaps

Each stroke is a chain. Order inside a chain is fixed. Two touches that are down
together are different chains. Reading a later chain before an earlier one pays a
cost that grows with the gap and saturates, so a strong spatial or language score
can override a delay of a few hundred milliseconds. The old enumerator, six adjacent
swaps and a hard stop at 18 events, is gone.

Rejected: keeping time order and only swapping events inside 40–120 ms.

Locked by `twoThumbsCanSplitLive`, `anInterleavedTwoThumbWordDecodes`, and
`aDelayedSecondThumbStillDecodes`.

## One search for a word made of several beats

Every beat keeps its events and its polyline. A later beat inside the leash is
decoded again with those paths, through `AlignmentSearch`, including shape. Aimed
letters alone are not a second decoder.

Rejected: joining on the letter sequence after the paths have been dropped.

Locked by `privateFromTapsAndTwoSwipes` and `estrangedKeepsNInsideTheSecondStroke`.

## Extend or start a new word

Inside the leash, the joined reading is compared with the new beat on its own. A
one-letter extension can still grow the open word (`the` + `n` becomes `then`). A
beat that is already its own confident word stays separate (`hello` then `correct`).
Explicit space still skips the choice. The other segmentation is offered on the
strip when it is a different dictionary word. An unsure word already on screen is
not deleted when the next gesture starts. Its other readings stay tappable.

Rejected: silently rewriting the previous word because the next gesture arrived.

Locked by `aFollowingWordStartsANewWord`, `twoConfidentSwipesStayTwoWords`, and
`explicitSpaceKeepsTheNextSwipeInTheSameWord`.

## The previous word is a score, not a prefix

A follower of the previous word, or of the previous two, receives a fixed bonus
inside the result. The bonus is below `exactLead`, so a decisive path still wins.
The old post-pass that promoted any follower already within 1.5 is gone. The
previous word is not required as a prefix of a two-thumb decode.

Between words, the strip offers that follower. Tapping it inserts the word. There
is no second suggestion row.

Rejected: seeding the beam with the previous word, and a full next-word strip
backed by a mapped trigram.

Locked by `aFollowerThePathFitsJoinsTheListAndAMissStaysOut`.

## Learning

A correction stores the curve immediately. An accepted word stores it after three
commits. Habits fade after 45 days. Without Full Access the files live in the
extension container. When the App Group is available they stay there, so the
companion can still see them. Settings the companion must read stay in the App
Group only.

Rejected: learning a curve from the first accept, and dropping learning when Full
Access is off.

## Frame slop, and a cancel is one finger

Leaving the hit frame is a stroke only after 8 pt past that frame. 16 pt sideways
and 36 pt of travel stay physical points, so tap jitter does not grow with the key.
Dwell and retreat scale with key width. Cancelling a stroke lifts that finger.
`SwipeSession.cancelled` no longer resets the other thumb. A third letter finger
joins as a tap, so a palm cannot open a third chain.

Rejected: treating a border roll as a second letter, and dropping the whole beat
because one finger was cancelled.

## The leash can unpick a short join

`the` + `n` may become `then`. If `ice` arrives before the leash ends, every cut
through the short chunks is scored again and the field becomes `the nice `. The
strip then shows `nice` and its other readings. One chip replaces one word, so
`then ice` is not a single tap. A second beat that is already a word is not pulled
in. Explicit space does not reopen the choice. The behavior, including the blocked
pairs, is written out in `docs/swipe-engine.md`.

Rejected: locking the join after two new events, which left `then ice` stuck.

Locked by `theNiceUndoesAShortJoin` and `functionWordsDoNotSwallowTheNextBeat`.

## What this pass does not do

Per-hand key offsets stay out until a perturbation set shows placement, rather than
timing or omission, is the miss. The seam bias stays until a touch profile replaces
it. Tap autocorrect already uses touch points. It keeps its own edit distance until
the beam's edits have settled, so two edit models are not maintained. There is no
online weight tuner and no neural reranker.

`FollowerPrior` stays a fixed 0.45. A memory-mapped bigram, a smaller `exactLead`,
and a sigma that grows from a precision estimate wait until the on-device touch
log says placement or pair strength is the miss. The log is local and the ranker
does not read it. Full gesture traces stay behind `recordsGestureTraces`, which
defaults off. Nothing is uploaded.
