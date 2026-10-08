# C11-340: CLI: browser type/fill joins flag tokens into the text (fill e11 "" --snapshot-after types ' --snapshot-after')

Found in the C11-337 R6 docs review. CLI/c11.swift (~8677-8684): the type|fill text is positional.joined(" ") without filtering flags, so 'c11 browser <panel> fill e11 "" --snapshot-after --json' fills the field with ' --snapshot-after' instead of clearing it and taking a post-action snapshot. Fix: parse known flags (--snapshot-after, --json, --text) before joining, and add a test for an empty fill with a trailing flag.
