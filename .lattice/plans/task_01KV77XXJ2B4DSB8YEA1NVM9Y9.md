# C11-146: Mailbox: spec the <agent-msg> framed block as a provider-neutral wire protocol

Wildest-mutation bet both models independently raised in the Trident review (notes/trident-review-mailbox-feature-pack-20260615-2208/synthesis-evolutionary.md §6) and the operator liked. The framed <c11-msg> block is LLM-native, transport-agnostic, and injection-defended — nothing about it is c11-specific.

Deliverable: a doc specifying '<agent-msg>' as a documented, provider-neutral agent-to-agent wire format (fields, escaping rules, framing, dedupe-by-id contract) the way MCP is specced — so c11 becomes the reference implementation of a format rather than the owner of a feature; it could ride Slack, tmux, SSH, any text channel.

Scope guard: this is a DOC + a name, not an implementation. 'Largest surface, smallest code.' Low priority; don't let it block the reliability workstreams (stable addressing, delivery safety, liveness).
