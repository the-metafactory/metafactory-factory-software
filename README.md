# metafactory-factory-software

The software factory as an installable arc package — the first `type: factory`
composition. The tarball will carry no constituent code: an
`arc-manifest.yaml` whose references point at published members, plus the
tool checks and the `produces: software` capability declaration.

**Status:** installs cleanly, does not yet fully reverse. arc implements the
`factory` type ([arc#400](https://github.com/the-metafactory/arc/issues/400)
install, [arc#402](https://github.com/the-metafactory/arc/issues/402) publish
validation, [arc#401](https://github.com/the-metafactory/arc/issues/401)
lifecycle), `arc validate .` is clean, and all five members install from one
command — verified 2026-09-02 into an isolated `$HOME`, with the real one
byte-identical before and after. The purge half is measured by this repo's own
end-to-end gate and is not there yet; see **Removal** and **Verifying it**.
Design (ratified 2026-09-02):
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

**What the review shows.** 47 capability lines and `Risk: HIGH (combined)` —
which is a property of the *union*, not of any member: one member reaches the
network, another writes to disk. It also flags that cortex's unrestricted bash
makes the whole composition unrestricted, however careful the other members'
allowlists are. Reading five separate installs would not tell you either
thing. That is what the single review is for.

It covers the five declared members. It does **not** cover what those members
pull in through their own `depends_on` — see the note under the member table.

**Removal cascades — and does not yet finish the job.** The composition-wide
`files` / `upgrade` / `purge` lifecycle ([arc#401](https://github.com/the-metafactory/arc/issues/401))
has landed on arc `main`, so `arc purge software-factory` takes the whole
composition down in one command and prints a D6 untangle verdict saying what,
if anything, it left behind.

Measured end to end by this repo's own gate (see **Verifying it** below), on
stock arc `main` at `7e3c17a`:

* **The cascade completes and reports `untangle: CLEAN`.** All ten packages go
  — the five declared members, cortex's four cascade dependencies, and the
  composition record. `arc list` is empty afterwards.
* **Clean is not the same as complete.** 37 paths survive, every one itemised
  in [`scripts/known-residue.txt`](scripts/known-residue.txt). The substantive
  half is cortex's postinstall creating runtime directories and a relay policy
  file that cortex's manifest does not declare under `owns:` — and arc only
  purges what a package declares, so `untangle: CLEAN` is printed truthfully
  while all of it is still on disk. arc names this failure mode itself, as
  arc#401 residual risk (c). That gap is the one thing standing between this
  factory and the epic's Definition of Done.

Until [arc#412](https://github.com/the-metafactory/arc/issues/412) merged, the
purge crashed part-way through this composition and left seven of the ten
packages installed — a scoped member name (compass-core's
`@the-metafactory/compass-core`) threw inside a secret-backend constructor that
sat outside the `try`/`catch`. This gate is what found it. It is fixed on arc
`main`; no patch is needed to run any of the below.

## The idea

![The factory becomes a package](assets/factory-becomes-package.jpg)

Declare the factory as a manifest, publish it to the registry,
`arc install software-factory` on a fresh machine — one command, one
combined capability review, reversible with `arc purge`. The Nth factory
costs a declaration, not an integration project.

That is the design. Today the install half is real and the reverse half is
close but not finished: the cascade exists and works, and what it leaves behind
is now measured rather than assumed — see **Removal** above and **Verifying
it** below.

## Verifying it

```bash
scripts/e2e-install-purge.sh            # the gate: nothing got worse
scripts/e2e-install-purge.sh --strict   # the epic's DoD: an EMPTY post-purge diff
```

The epic's acceptance test, executable: install → inventory → purge → diff,
driving the real `arc` verbs against this manifest inside a hermetic `$HOME`.
Members are really cloned at their real pins and really installed; nothing is
simulated. The script clones arc itself, so it depends on nothing outside this
repo. See its header for how containment works and what it cannot contain.

Three files, and the split between them is the point:

| File | What it holds |
|---|---|
| [`scripts/e2e-install-purge.sh`](scripts/e2e-install-purge.sh) | the assertions |
| [`scripts/known-residue.txt`](scripts/known-residue.txt) | every path that survives a purge today, classified, with an owner |
| [`scripts/known-failures.txt`](scripts/known-failures.txt) | every assertion known to fail, with what is broken and who owns it |

The default run gates on **regression** — anything surviving that is not
already in those files turns the light red. The Definition of Done is stricter
and is reported on every run whether or not it passes. Both files should only
ever shrink; when they are empty, `--strict` goes green and that run is the
epic's acceptance test passing. Until then, a green run means *nothing got
worse*, not *the epic is done*, and the script says so.

**Where that stands today**, on stock arc `main` at `7e3c17a`: the default gate
is **green** — 26 assertions pass, 3 are known-waived. `--strict` is **red** on
those same 3, and that is the honest reading, not a formality:

| Assertion | Gap | Owner |
|---|---|---|
| `A5.8` | the DoD itself — 37 paths survive, per `known-residue.txt` | [cortex#2520](https://github.com/the-metafactory/cortex/issues/2520) |
| `A6.3` | purge calls `launchctl` against the real login session | [cortex#2520](https://github.com/the-metafactory/cortex/issues/2520) |
| `A1.5` | a declared member is recorded `preexisting` on a fresh machine | [arc#417](https://github.com/the-metafactory/arc/issues/417) |

Closing `A5.8` is the epic's remaining work. Nothing here is blocked on arc any
more.

**Every detector has been watched failing.** `--inject-residue` plants leftover
state after the purge and requires the detectors to catch it; `--check-stub`
proves the `launchctl` interceptor bites; `--check-tripwire` drives the
containment predicate over synthetic logs with known answers, including a
prefix-sibling case that a previous version of it was blind to. All three run in
CI on every pass, because a gate whose last observed failure was on somebody's
laptop is a gate nobody should trust.

The baseline files are enforced shrink-only in CI by
[`scripts/check-baseline-shrink.sh`](scripts/check-baseline-shrink.sh) — run it
locally, and run `--self-test` to check the guard itself. Adding an entry needs
the `baseline-growth` label: deliberately awkward, because the pressure to add
one is highest exactly when someone is trying to turn a red build green.

A file that does not exist at the comparison base is being *introduced*, not
grown, and the guard says so instead of failing. Getting that wrong is what let
a guard failure skip the gate entirely on one merge to `main`; the judgement
steps now run **after** the harness for the same reason.

**One finding worth reading before you run it anywhere real.** Purging this
factory issues `launchctl bootout gui/<uid> …` against your *actual* login
session — cortex's `scripts.purge` hook enumerates plists under the redirected
`$HOME` (contained) but boots them out of `gui/$(id -u)` (not contained), and
`bootout` resolves the job by the label inside the plist. On a machine running
cortex, that label is live. The harness's `launchctl` stub is what stops it,
which makes the stub load-bearing rather than defensive. Details, and the fix,
in `scripts/known-failures.txt` under A6.3.

## What's inside (ratified MVP)

Runtime + governance + skills — **no agent bundle**: the agent is the
operator's first choice on top ("fresh machine → factory ready, agent one
install away").

| Member | Pin | Role |
|---|---|---|
| cortex | 6.13.3 | runtime |
| metafactory-cortex-adapter-discord | 0.2.0 | surface |
| compass-core | 0.6.0 | governance — SOPs (plan-breakdown, dev loop, code review) + skills |
| discord (skill) | 0.5.0 | narration surface |
| code-review (skill) | 0.4.2 | the review lane |

Pins are exact by design: a range would reintroduce the integration project
this package type exists to delete. Every pin is cited to its release in the
manifest.

**Five members, nine packages — and the gap is real.** Installing cortex also
pulls the four adapters and renderers it declares in its own
`depends_on.packages`: mattermost, slack, web, pagerduty. Those four are
**not** in the combined review, contribute no capability line to it, and land
**unpinned**, under cortex's cascade with consent already granted. So the one
review covers the five members this manifest declares — not everything the
install puts on your machine. That is
[arc#410](https://github.com/the-metafactory/arc/issues/410), open: *the
composition review does not cover members' `depends_on` cascades — packages
land unreviewed and unpinned under `yes: true`*. Until it closes, read the
review as the floor of what installs, not the ceiling.

Optional tier: pilot-review-loop · art · agent-state · soma · luna-lite.

![Inside the software factory](assets/software-factory-exploded.jpg)
