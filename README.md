# metafactory-factory-software

The software factory as an installable arc package — the first `type: factory`
composition. The tarball will carry no constituent code: an
`arc-manifest.yaml` whose references point at published members, plus the
tool checks and the `produces: software` capability declaration.

**Status:** repo scaffolded; the manifest lands via the epic once arc
implements the `factory` type. Design (ratified 2026-09-02):
[arc `docs/design-factory-type.md`](https://github.com/the-metafactory/arc/blob/main/docs/design-factory-type.md)
· concept anchor: [arc#365](https://github.com/the-metafactory/arc/issues/365).

## The idea

![The factory becomes a package](assets/factory-becomes-package.jpg)

Declare the factory as a manifest, publish it to the registry,
`arc install software-factory` on a fresh machine — one command, one
combined capability review, reversible with `arc purge`. The Nth factory
costs a declaration, not an integration project.

## What's inside (ratified MVP)

Runtime + governance + skills — **no agent bundle**: the agent is the
operator's first choice on top ("fresh machine → factory ready, agent one
install away").

| Member | Role |
|---|---|
| cortex | runtime |
| metafactory-cortex-adapter-discord | surface |
| compass-core | governance — SOPs (plan-breakdown, dev loop, code review) + skills |
| discord (skill) | narration surface |
| code-review (skill) | the review lane |

Optional tier: pilot-review-loop · art · agent-state · soma · luna-lite.

![Inside the software factory](assets/software-factory-exploded.jpg)
