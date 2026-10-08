# C11-346: Restore a deterministic test for socket password mode (deleted as flaky in C11-345)

C11-345 (#609) deleted the flaky socket password-mode host test along with the other flaky tests. Its reviewer recommended quarantine instead, so password mode now has no test. Add a deterministic test of the password-mode accept/reject paths, through the socket control path in a logic-test seam, or a host test that doesn't depend on timing. Also consider restoring the mailbox byte-parity check that went with the deleted tests_v2 scripts.
