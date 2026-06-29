# C11-153: pi exact-session resume (PiScraper + PiStrategy)

Phase B pi. DEPENDS ON the scrape-capture pipeline ticket. PiScraper: walk ~/.pi/agent/sessions/ recursively for *.jsonl; id = substring after last underscore before .jsonl (UUIDv7, verified); validate isValidConversationUUID. PiStrategy (mirror CodexStrategy scrape-primary+ambiguity): resume pi --session '<id>'. Register in StrategyRegistry.v1; flip manifest hasConversationStrategy. Acceptance: unit tests; live pi resumes exact session.
