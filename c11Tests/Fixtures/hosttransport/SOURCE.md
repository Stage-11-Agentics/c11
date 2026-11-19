# hosttransport-examples-large.ndjson

Vendored unchanged from `Stage-11-Agentics/constellation-bus` `main`, `schema/hosttransport-examples-large.ndjson`, at commit `06c052271a1ac1559c543a1f8f22bc8f323fdcf6` (CBUS-23, #10, which carries A6 Amendment 2's final rules). The earlier copy came from `944fc14` (sha256 `f12f7e1f…`).

sha256 `32aad1a49598932457e0e76c57561f16e441ae57fcdd1f9433f8fde6035aca2d`

`HostEnvelopeAdmissionTests.testTheBusFixturesMeasureAsTheBusExpects` (C11H-118, A6 Amendment 2) checks every envelope in it against the bus's stated expectations, offline. To refresh it, fetch the file from bus `main` (never a branch) at the new commit, update this note, and rerun that test. The file is over 1 MB, so the contents API needs the raw media type: `gh api -H "Accept: application/vnd.github.raw" "repos/Stage-11-Agentics/constellation-bus/contents/schema/hosttransport-examples-large.ndjson?ref=<commit>"`.
