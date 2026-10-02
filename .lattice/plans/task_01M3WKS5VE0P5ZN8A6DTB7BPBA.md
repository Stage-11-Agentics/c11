# C11-255: Codex resume drops its exact ref on every c11-driven resume

c11 resumes Codex with `codex resume --yolo <id>` (since #384), but Resources/bin/codex read the expected resume id only from $2. Every c11-driven resume was claimed as a plain launch; the store replaced the exact ref with a placeholder and the next restart skipped the tab. Codex resumed only on alternate restarts. Found 2026-10-01 after the 0.67.0 update restart: `c11 state verify --mode clean` showed the resumed Codex tab as [skip] wrapper-claim placeholder.
