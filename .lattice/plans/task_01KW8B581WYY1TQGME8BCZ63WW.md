# C11-154: omp exact-session resume (OmpScraper + OmpStrategy)

Phase B omp (oh-my-pi). DEPENDS ON the scrape-capture pipeline ticket. OmpScraper: walk ~/.omp/agent/sessions/ recursively for *.jsonl (SKIP per-session subdir *.log); id after last underscore before .jsonl (UUIDv7); validate isValidConversationUUID. OmpStrategy (mirror CodexStrategy): resume omp --resume='<id>'. Register in StrategyRegistry.v1; flip manifest hasConversationStrategy. Acceptance: unit tests; live omp resumes exact session.
