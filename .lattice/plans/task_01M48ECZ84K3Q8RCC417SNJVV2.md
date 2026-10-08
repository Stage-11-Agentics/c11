# C11-339: Bonsplit: localize the 'Copy' prefix of the panel right-click menu's copy-ref item

Found in the C11-337 R7 review. The live simplified right-click menu reads command.copySurfaceRef.prefix (vendor/bonsplit Sources/Bonsplit/Internal/Views/TabItemView.swift ~1202), but no Localizable.strings file defines it, so all six non-English locales show 'Copy panel:N' in English. Fix: add the key to all 7 .lproj files. Bonsplit-touching: serialize with other Bonsplit work and follow the fork-branch + fast-forward-at-landing flow (#596/R7).
