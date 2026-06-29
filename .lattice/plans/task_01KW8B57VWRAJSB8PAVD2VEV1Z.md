# C11-152: Live scrape-capture pipeline (wire scrapers into restore)

Phase B foundation. The scrape rail has 0 live call sites — nothing invokes scrapers at restore. Build the seam: at surface restore, per-kind scraper -> [ScrapeCandidate] -> strategy.capture -> store.applyScrape, so captured refs drive strategy.resume next restore. Injectable filesystem for tests. Benefits codex too. Acceptance: test proves a scraped candidate becomes a resumable ref; claude/codex unaffected; c11-logic green. BLOCKS the pi and omp tickets.
