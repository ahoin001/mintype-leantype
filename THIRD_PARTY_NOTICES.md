# Third-party notices

## English word list (`lexicon.bin`)

`Packages/LeanTypeKit/Sources/LeanTypeCore/Resources/lexicon.bin` is adapted from
[FrequencyWords](https://github.com/hermitdave/FrequencyWords) by Hermit Dave, specifically
`content/2018/en/en_full.txt` (the 100,000 most frequent words kept), which is derived from the
[OpenSubtitles 2018](http://opus.nlpl.eu/OpenSubtitles2018.php) corpus.

- Licence: [Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
- Changes: the list is filtered (a blocklist of words never to suggest, tokenizer fragments),
  contraction halves are folded back into whole words, capitalisation is restored from a
  reference dictionary, frequencies are quantised to one byte, and the result is packed into
  LeanType's binary lexicon format by `Tools/LexiconBuilder` (see `scripts/build-lexicon.sh`).

As an adaptation, `lexicon.bin` is itself licensed under CC BY-SA 4.0. This does not extend to
LeanType's source code, which only reads the file.

The app credits the word list in Settings → About.
