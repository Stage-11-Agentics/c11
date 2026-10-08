# C11-348: Events log: private files (0600) and retention for panel.input_sent content

1.0 writes the text of every send, send-key, paste, mailbox send and feed answer (up to 256 KiB each) into ~/Library/Application Support/c11/events/. Files are 0644 (inside 0700 ~/Library), one per launch, and never pruned (574 files on Hyperion at release). Target 1.0.1: create files 0600, add time-based retention (see C11-232), and consider a size cap. Atin shipped 1.0 as is; the CHANGELOG and threat model document the current behavior.
