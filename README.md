# metafactory-factory-software

The software factory as an installable arc package — the first `type: factory`
composition. The tarball will carry no constituent code: an
`arc-manifest.yaml` whose references point at published members, plus the
tool checks and the `produces: software` capability declaration.

**Status:** the manifest is here. arc implements the `factory` type
([arc#400](https://github.com/the-metafactory/arc/issues/400) install,
[arc#402](https://github.com/the-metafactory/arc/issues/402) publish
validation), `arc validate .` is clean, and the composition installs — with
one caveat, below. Design (ratified 2026-09-02):
[arc `docs/design-factory-type.md`](https://github.com/the-metafactory/arc/blob/main/docs/design-factory-type.md)
· concept anchor: [arc#365](https://github.com/the-metafactory/arc/issues/365).

## Install

```bash
arc install https://github.com/the-metafactory/metafactory-factory-software
```

One command. arc checks the host tools (`git`, `gh`, `bun`), resolves all five
members, shows **one** combined capability review — the union of every
member's surface, each line attributed to the member that asked for it — and
asks once. Nothing lands until every member has resolved and you have said
yes; one bad member aborts all of it.

`arc install software-factory`, by name, needs the registry. That is HELD
([arc#366](https://github.com/the-metafactory/arc/issues/366) "stock the
shelf"), so members are addressed by git URL for now and the git URL above is
the install path. Flipping to registry names is one line per member.

**Two members cannot resolve yet.** `compass-core` 0.6.0 and `discord` 0.5.0
are the ratified versions, and their repos declare them on `main`, but neither
has cut a tag — so the composition refuses, loudly, having installed nothing.
Cutting `compass-core v0.6.0` and `metafactory-bundle-discord v0.5.0` is the
whole remaining gap; nothing in this repo changes when they land. The manifest
explains itself, including why pinning the older tags instead would be worse.

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

| Member | Pin | Role |
|---|---|---|
| cortex | 6.13.3 | runtime |
| metafactory-cortex-adapter-discord | 0.2.0 | surface |
| compass-core | 0.6.0 ⏳ | governance — SOPs (plan-breakdown, dev loop, code review) + skills |
| discord (skill) | 0.5.0 ⏳ | narration surface |
| code-review (skill) | 0.4.2 | the review lane |

⏳ = the version is declared on the member's `main` but not yet tagged, so it
cannot resolve. Pins are exact by design: a range would reintroduce the
integration project this package type exists to delete.

Optional tier: pilot-review-loop · art · agent-state · soma · luna-lite.

![Inside the software factory](assets/software-factory-exploded.jpg)
