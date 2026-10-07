/// English contractions, and how to recover them from tokenizers that split at apostrophes.
enum Contractions {
    /// "n't" contractions whose first half is not a word on its own ("didn" + "'t").
    static let negatives: [(fragment: String, contraction: String)] = [
        ("don", "don't"), ("didn", "didn't"), ("doesn", "doesn't"), ("isn", "isn't"), ("ain", "ain't"),
        ("wasn", "wasn't"), ("weren", "weren't"), ("haven", "haven't"), ("hasn", "hasn't"),
        ("hadn", "hadn't"), ("wouldn", "wouldn't"), ("couldn", "couldn't"), ("shouldn", "shouldn't"),
        ("aren", "aren't"), ("mustn", "mustn't"), ("needn", "needn't"), ("shan", "shan't"),
    ]

    /// "n't" contractions whose first half is a real word ("can", "won"). They share whatever
    /// "'t" count the unambiguous negatives don't explain.
    static let ambiguousNegatives: [(base: String, contraction: String, share: Double)] = [
        ("can", "can't", 0.72),
        ("won", "won't", 0.28),
    ]

    /// Suffix tokens and the estimated share of each contraction that produced them. Shares
    /// don't sum to 1: the rest are possessives and rarer forms.
    static let suffixShares: [(suffix: String, shares: [(String, Double)])] = [
        ("'m", [("i'm", 1)]),
        ("'s", [
            ("it's", 0.30), ("that's", 0.14), ("what's", 0.07), ("he's", 0.06), ("there's", 0.04),
            ("she's", 0.035), ("let's", 0.035), ("here's", 0.02), ("who's", 0.012), ("where's", 0.012),
            ("how's", 0.004),
        ]),
        ("'re", [("you're", 0.45), ("we're", 0.25), ("they're", 0.20)]),
        ("'ll", [
            ("i'll", 0.45), ("you'll", 0.15), ("we'll", 0.13), ("it'll", 0.06), ("he'll", 0.06),
            ("they'll", 0.06), ("she'll", 0.03), ("that'll", 0.03),
        ]),
        ("'ve", [
            ("i've", 0.45), ("you've", 0.18), ("we've", 0.15), ("they've", 0.08), ("could've", 0.03),
            ("would've", 0.03), ("should've", 0.03),
        ]),
        ("'d", [
            ("i'd", 0.45), ("you'd", 0.15), ("he'd", 0.08), ("we'd", 0.07), ("they'd", 0.06),
            ("she'd", 0.04), ("it'd", 0.02),
        ]),
    ]

    /// Fragments that are really whole words with a leading apostrophe.
    static let wholeWords: [(fragment: String, word: String)] = [
        ("'clock", "o'clock"), ("'all", "y'all"), ("'am", "ma'am"),
    ]

    /// Tokens that only exist as contraction halves, or as apostrophe-less misspellings that
    /// the contraction now answers ("dont" finds "don't" through its key).
    static let fragments: Set<String> = Set(negatives.map(\.fragment)).union([
        "s", "t", "m", "re", "ll", "ve", "d", "o", "y",
        "dont", "im", "cant", "wont", "didnt", "doesnt", "isnt", "wasnt", "couldnt", "wouldnt",
        "shouldnt", "havent", "hasnt", "hadnt", "arent", "werent", "aint", "ive", "youre",
        "theyre", "thats", "whats", "shes", "theres", "heres", "wheres", "whos", "youve", "youll",
        "theyll", "theyve", "itll", "youd", "theyd", "yall", "maam", "oclock",
    ])

    static let all: Set<String> = Set(
        negatives.map(\.contraction)
            + ambiguousNegatives.map(\.contraction)
            + suffixShares.flatMap { $0.shares.map(\.0) }
            + wholeWords.map(\.word)
    )

    /// Contractions whose display needs a capital.
    static let displayForms: [String: String] = [
        "i'm": "I'm", "i'll": "I'll", "i've": "I've", "i'd": "I'd",
    ]
}
