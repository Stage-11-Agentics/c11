import Foundation

// MARK: - Chaos Wizard (C11H-199)
//
// The sidebar's Chaos button draws two commissions (premise, medium,
// constraint) and casts the default agent on each, side by side in a new
// workspace (`chaos cast --mode four` makes a 2x2), every agent confined by
// its prompt to its own studio folder under the Chaos root. This file is the pure part: the deck, seeded draws, the prompt
// each agent receives and the gallery pages. `ChaosCaster` does the I/O.

/// How a cast fills its workspace.
enum ChaosMode: String, Codable, CaseIterable, Sendable {
    /// Two pieces, the default agent on each, side by side. The button's cast.
    case two
    /// Four pieces, the default agent on each, in a 2x2 grid.
    case four
    /// Four pieces, each on a different saved agent config.
    case ensemble
    /// One piece, the default agent, the whole workspace.
    case one

    var pieceCount: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .four, .ensemble: return 4
        }
    }
}

/// One premise: a short title and what it is.
struct ChaosPremise: Codable, Equatable, Sendable {
    var title: String
    var text: String
}

/// One drawn commission.
struct ChaosPiece: Codable, Equatable, Sendable {
    var premise: ChaosPremise
    var medium: String
    var constraint: String

    /// The studio folder's name for this piece, `<n>-<slug>`.
    func studioName(index: Int) -> String {
        "\(index + 1)-\(ChaosDeck.slug(premise.title))"
    }

    /// One line for menus and the popover.
    var summary: String { "\(premise.title) · \(medium) · \(constraint)" }
}

/// SplitMix64: a tiny seeded generator, so `chaos draw --seed N` repeats.
struct ChaosRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ChaosDeck: Equatable, Sendable {
    var premises: [ChaosPremise]
    var media: [String]
    var constraints: [String]

    /// The file in the Chaos root that replaces the built-in deck, section by section.
    static let fileName = "DECK.md"

    // MARK: Drawing

    /// `count` pieces with distinct premises (and distinct media and
    /// constraints while the deck has enough), the same for the same seed.
    func draw(count: Int, seed: UInt64) -> [ChaosPiece] {
        var rng = ChaosRandom(seed: seed)
        let premiseOrder = premises.indices.shuffled(using: &rng)
        let mediumOrder = media.indices.shuffled(using: &rng)
        let constraintOrder = constraints.indices.shuffled(using: &rng)
        guard !premises.isEmpty, !media.isEmpty, !constraints.isEmpty, count > 0 else { return [] }
        return (0..<count).map { i in
            ChaosPiece(
                premise: premises[premiseOrder[i % premiseOrder.count]],
                medium: media[mediumOrder[i % mediumOrder.count]],
                constraint: constraints[constraintOrder[i % constraintOrder.count]]
            )
        }
    }

    // MARK: DECK.md

    /// Parse a DECK.md. Each `## Premises`, `## Media` or `## Constraints`
    /// section's bullets replace the built-in section; a missing or empty
    /// section keeps the built-in one. A premise is `Title: what it is`.
    static func parse(markdown: String, fallback: ChaosDeck = .builtIn) -> ChaosDeck {
        enum Section { case premises, media, constraints, other }
        var section = Section.other
        var premises: [ChaosPremise] = []
        var media: [String] = []
        var constraints: [String] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                switch heading {
                case "premises", "premise": section = .premises
                case "media", "medium", "mediums": section = .media
                case "constraints", "constraint": section = .constraints
                default: section = .other
                }
                continue
            }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            switch section {
            case .premises: premises.append(premise(from: item))
            case .media: media.append(item)
            case .constraints: constraints.append(item)
            case .other: break
            }
        }
        return ChaosDeck(
            premises: premises.isEmpty ? fallback.premises : premises,
            media: media.isEmpty ? fallback.media : media,
            constraints: constraints.isEmpty ? fallback.constraints : constraints
        )
    }

    /// The deck as a DECK.md an operator can edit.
    func markdown() -> String {
        var out = """
        # Chaos Wizard deck

        The Chaos button draws one line from each section for every piece. Edit, add or cut \
        lines freely; a section you delete falls back to the built-in one. A premise is \
        `Title: what it is`.

        ## Premises

        """
        for p in premises { out += "- \(p.title): \(p.text)\n" }
        out += "\n## Media\n\n"
        for m in media { out += "- \(m)\n" }
        out += "\n## Constraints\n\n"
        for c in constraints { out += "- \(c)\n" }
        return out
    }

    private static func premise(from item: String) -> ChaosPremise {
        if let colon = item.firstIndex(of: ":") {
            let title = item[..<colon].trimmingCharacters(in: .whitespaces)
            let text = item[item.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, !text.isEmpty { return ChaosPremise(title: title, text: text) }
        }
        let words = item.split(separator: " ").prefix(3).joined(separator: " ")
        return ChaosPremise(title: words, text: item)
    }

    /// A folder-safe slug: lowercase letters, digits and single hyphens, at most 32 characters.
    static func slug(_ title: String) -> String {
        var out = ""
        var lastWasHyphen = true
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
            if out.count >= 32 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "piece" : out
    }
}

// MARK: - The built-in deck

extension ChaosDeck {
    static let builtIn = ChaosDeck(
        premises: [
            ChaosPremise(title: "Houseplant Diplomacy", text: "the protocol houseplants use to negotiate who gets the window"),
            ChaosPremise(title: "Museum of Extinct Errors", text: "error messages from operating systems that never existed, each with a placard and provenance"),
            ChaosPremise(title: "Inner Weather", text: "a weather service that forecasts the climate inside a laptop"),
            ChaosPremise(title: "Packet Romance", text: "two TCP packets falling in love across a lossy link"),
            ChaosPremise(title: "Tarot of the Merge", text: "a tarot deck for software engineers: The Flaky Test, The Force Push, The Green Build"),
            ChaosPremise(title: "Sock Census", text: "a national census of lost socks, with demographics and migration patterns"),
            ChaosPremise(title: "Pigeon Mesh", text: "a mesh network where carrier pigeons route packets and gossip about each other"),
            ChaosPremise(title: "Benchmark of Thought", text: "a rigorous benchmark of how fast five imaginary animals can think"),
            ChaosPremise(title: "Cathedral of Tabs", text: "a cathedral built from one person's four thousand open browser tabs"),
            ChaosPremise(title: "The Moon's Tax Return", text: "the moon files its taxes, fully itemized, and is audited"),
            ChaosPremise(title: "The Last Semicolon", text: "an epic about the last semicolon left in a dying codebase"),
            ChaosPremise(title: "Cloud Taxonomy", text: "a field guide that classifies clouds by which data center each one secretly is"),
            ChaosPremise(title: "Elevator Opera", text: "an opera sung by elevators about the floors they never visit"),
            ChaosPremise(title: "Font Fossils", text: "the archaeology of typefaces excavated from an ancient printer"),
            ChaosPremise(title: "Ant Stock Exchange", text: "a stock market run by ants, trading crumbs, with a crash"),
            ChaosPremise(title: "Dream Compiler", text: "a compiler that turns dreams into binaries, with a bug tracker for nightmares"),
            ChaosPremise(title: "Bureau of Missing Hours", text: "a government office that processes claims for hours lost to daylight saving"),
            ChaosPremise(title: "Lighthouse Gossip", text: "lighthouses blinking scandalous gossip to each other along a coast"),
            ChaosPremise(title: "Committee of Clocks", text: "every clock in a house holds a meeting to agree on what time it is"),
            ChaosPremise(title: "Volcano Support Desk", text: "the customer support queue of a volcano that is about to erupt"),
            ChaosPremise(title: "Haunted Spreadsheet", text: "a spreadsheet haunted by a ghost who speaks only in formulas"),
            ChaosPremise(title: "Interstellar Recipe Swap", text: "recipes traded between civilizations whose physics disagree"),
            ChaosPremise(title: "Slime Mold Transit", text: "a slime mold redesigns a city's transit map, and is right"),
            ChaosPremise(title: "Satellite Retirement Party", text: "speeches, cake and an orbital decay schedule for a retiring satellite"),
            ChaosPremise(title: "Waggle Dance Grammar", text: "a formal grammar and parser for the honeybee waggle dance"),
            ChaosPremise(title: "Opinionated Parking Garage", text: "a parking garage with strong opinions about how you park"),
            ChaosPremise(title: "The Etiquette of Rain", text: "a book of manners for raindrops"),
            ChaosPremise(title: "Midnight Fridge Magnets", text: "fridge magnets that arrange themselves into poems while the house sleeps"),
            ChaosPremise(title: "Octopus Postal Service", text: "an underwater mail service run by octopuses, eight parcels at a time"),
            ChaosPremise(title: "Glacier Commit Log", text: "the commit history of a glacier over ten thousand years"),
            ChaosPremise(title: "Lost and Found of Ideas", text: "where abandoned startup ideas wait to be claimed"),
            ChaosPremise(title: "Cartography of Boredom", text: "heroic maps of the most boring places on earth"),
            ChaosPremise(title: "Server Lullabies", text: "the lullabies robots sing to servers at three in the morning"),
            ChaosPremise(title: "Microwave Chorus", text: "every microwave in a city beeping together into one symphony"),
            ChaosPremise(title: "Escape Velocity Bakery", text: "a bakery whose bread must reach orbit before it can rise"),
            ChaosPremise(title: "The Queue Itself", text: "the inner life of a message queue that has never been empty"),
        ],
        media: [
            "a single-file HTML toy you can play with",
            "a generative WebAudio piece with a live score",
            "a series of five SVG posters on one HTML page",
            "an ASCII animation that plays in this terminal",
            "a fake scientific paper with real charts, as one HTML page",
            "a tiny original browser game",
            "an interactive museum exhibit in HTML and CSS",
            "a printable zine as one HTML page",
            "a generative typeface with a specimen page",
            "a terminal program with its own REPL",
            "a hand-drawn SVG data visualization of invented data",
            "a choose-your-own-adventure in HTML",
            "a working simulation with sliders",
            "an RFC with a reference implementation and a test suite",
            "a 3D scene in pure CSS",
            "an animated infomercial as a web page",
        ],
        constraints: [
            "only three colors",
            "fully deterministic from a single seed",
            "every function is named after a cheese",
            "a test suite that proves the nonsense is true",
            "it must look and read as if it shipped in 1987",
            "the whole piece in under 8 KB of code",
            "no images: everything is drawn with code",
            "a changelog of at least five versions",
            "it benchmarks itself and publishes the results",
            "one button, and it changes everything",
            "the README is written by the piece itself",
            "every number on screen is tabular and right-aligned",
            "it works with the sound off and gets better with it on",
            "it reveals a secret after sixty seconds",
            "keyboard-only, with a label for every control",
            "everything in one monospace font",
        ]
    )
}

// MARK: - The prompt

enum ChaosPrompt {
    /// Minutes each agent is asked to finish within.
    static let minutes = 20

    /// The first line each agent's panel shows: the piece itself, so the wild
    /// premise is on screen from the start. The brief and the hard rules
    /// follow in the staged prompt file.
    static func headline(piece: ChaosPiece, index: Int, artistCount: Int) -> String {
        let which = artistCount > 1 ? "Chaos Wizard commission \(index + 1) of \(artistCount)" : "Chaos Wizard commission"
        func clause(_ s: String) -> String {
            s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".!?;:,")))
        }
        return "\(which): \"\(piece.premise.title)\", \(clause(piece.premise.text)). "
            + "Medium: \(clause(piece.medium)). Constraint: \(clause(piece.constraint))."
    }

    /// What one agent is told. `studio` is the absolute path of its folder;
    /// `cli` is this build's CLI name, so the agent drives the right app.
    static func compose(piece: ChaosPiece, studio: String, artistCount: Int, cli: String = "c11") -> String {
        let company = artistCount > 1
            ? "You are one of \(artistCount) artists in a Chaos Wizard cast; the others work in the studios next to yours."
            : "You are the artist in a Chaos Wizard cast."
        let pieceURL = URL(fileURLWithPath: studio, isDirectory: true).appendingPathComponent("index.html").absoluteString
        return """
        \(company) Make one original piece of art, alone, in about \(minutes) minutes.

        The commission:
        - Premise: \(piece.premise.title): \(piece.premise.text)
        - Medium: \(piece.medium)
        - Constraint: \(piece.constraint)

        Be wild, strange, funny and surprising. Treat the absurd premise with total engineering \
        rigor: a short spec, real working code, a test or benchmark that proves something \
        ridiculous, a changelog. Make it original: no recreations of existing games, characters, \
        brands or artworks.

        The hard rules:
        - Your studio is "\(studio)". Create, change and delete files only inside it, plus scratch \
        files in $TMPDIR. Write nothing anywhere else: no other folders, no dotfiles or settings, \
        no installs of any kind (no npm, brew or pip), no git outside your studio. Reading elsewhere \
        is fine. Leave the other studios alone.
        - Use no network: no CDNs or downloads; everything is self-contained.
        - Start no server, daemon or background process that outlives you.
        - Use \(cli) only for the commands below. Never send to, read, close or launch other panels, \
        workspaces or agents, and never cast Chaos yourself.

        Show it off:
        1. Name your panel after the piece: \(cli) rename-panel --panel "$C11_PANEL_ID" "<title>"
        2. Keep your panel subtitle as its gallery label, one line: \(cli) set-description --panel "$C11_PANEL_ID" "<label>"
        3. Put the entry point at index.html in your studio (for a terminal piece, a script plus an \
        index.html that says how to run it), and write WALL.md: title, medium, and a one-paragraph \
        artist statement.
        4. When it is done, open it: \(cli) browser open "\(pieceURL)" (or run \
        a terminal piece right here).

        Then stop. Raise no flags and send no mail.
        """
    }
}

// MARK: - Gallery pages

enum ChaosGallery {
    struct Entry: Equatable {
        var studio: String
        var piece: ChaosPiece
        var agent: String
    }

    static let favicon = """
    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'%3E%3Crect width='512' height='512' rx='96' fill='%23000000'/%3E%3Cg fill='%23e8e8e8' transform='translate(34.96 387.08) scale(0.35913 -0.35913)'%3E%3Cpath transform='translate(0)' d='M89 0V90H284V641L88 495V607L254 730H383V90H543V0Z'/%3E%3Cpath transform='translate(600)' d='M89 0V90H284V641L88 495V607L254 730H383V90H543V0Z'/%3E%3C/g%3E%3C/svg%3E">
    """

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Percent-encode one path segment for a relative link.
    static func href(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? segment
    }

    private static let style = """
    <style>
    :root { color-scheme: light dark; --ink: #111; --paper: #fafaf7; --rule: #d8d6cf; --dim: #6b6a65; --accent: #b8327a; }
    @media (prefers-color-scheme: dark) { :root { --ink: #ecebe6; --paper: #0d0d0c; --rule: #2c2b28; --dim: #8f8d86; --accent: #e06aa8; } }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 48px 40px; background: var(--paper); color: var(--ink);
           font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; font-variant-numeric: tabular-nums; }
    h1 { font-size: 28px; margin: 0 0 4px; letter-spacing: 0.02em; }
    .sub { color: var(--dim); margin: 0 0 32px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
    a.card { display: block; border: 1px solid var(--rule); padding: 18px 20px; color: inherit; text-decoration: none; min-height: 168px; }
    a.card:hover { border-color: var(--accent); }
    .n { color: var(--accent); font-weight: 700; }
    .t { font-size: 18px; font-weight: 700; margin: 6px 0; }
    .m { color: var(--dim); }
    </style>
    """

    /// The run's contact sheet, `<run>/index.html`.
    static func runPage(title: String, entries: [Entry]) -> String {
        let cards = entries.enumerated().map { i, e in
            """
              <a class="card" href="./\(href(e.studio))/index.html">
                <div class="n">\(i + 1)</div>
                <div class="t">\(escape(e.piece.premise.title))</div>
                <div>\(escape(e.piece.premise.text))</div>
                <div class="m">\(escape(e.piece.medium)) · \(escape(e.piece.constraint))</div>
                <div class="m">\(escape(e.agent))</div>
              </a>
            """
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        \(favicon)
        \(style)
        </head><body>
        <h1>\(escape(title))</h1>
        <p class="sub">A Chaos Wizard cast. Each card opens its piece once the artist has finished. <a href="../gallery.html">All casts</a></p>
        <div class="grid">
        \(cards)
        </div>
        </body></html>

        """
    }

    struct RunSummary: Equatable {
        var folder: String
        var title: String
        var pieces: [String]
    }

    /// The Chaos root's gallery of every cast, newest first.
    static func rootPage(runs: [RunSummary]) -> String {
        let cards = runs.map { r in
            """
              <a class="card" href="./\(href(r.folder))/index.html">
                <div class="t">\(escape(r.title))</div>
                <div class="m">\(r.pieces.map(escape).joined(separator: "<br>"))</div>
              </a>
            """
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Chaos Wizard gallery</title>
        \(favicon)
        \(style)
        </head><body>
        <h1>Chaos Wizard gallery</h1>
        <p class="sub">\(runs.count) cast\(runs.count == 1 ? "" : "s"), newest first.</p>
        <div class="grid">
        \(cards)
        </div>
        </body></html>

        """
    }
}
