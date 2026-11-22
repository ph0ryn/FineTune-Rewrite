# FineTune-Rewrite Development Guide

## Purpose and Scope

Redesign and reimplement FineTune for macOS, targeting baseline compatibility in features, UI, interaction model, settings, and external integrations.
The goal is to replace existing workflows with a structure where defects can be reproduced, fixed, and maintained independently.
Compatibility does not include reproducing known bugs; distinguish intended behavior from defects.

## Reference Baseline

- Use the [original FineTune](https://github.com/ronitsingh10/FineTune) as the comparison baseline. Track the pinned version and revision in the [specification](docs/spec.md); do not drift the baseline to latest `main` on every task.
- Record upstream issues, PRs, and fix history in [research notes](docs/research.md) as source material for reproduction steps and acceptance criteria. Do not assume a symptom is resolved solely because a fix commit exists.
- Whenever expected post-fix behavior differs from upstream behavior, document the difference explicitly in the [specification](docs/spec.md) and acceptance criteria.

## Design Assumptions

The [architecture](docs/architecture.md) document is the source of truth for responsibility boundaries, state and audio resource ownership, and real-time boundaries.
Validate aggregate handling, channel mapping, switching strategies, first-audio behavior, and idle handling on real hardware; never treat a passing build as proof of audio correctness or real-time safety.

## Document Roles

| Document | Question It Answers |
| --- | --- |
| [Specification](docs/spec.md) | What it must do (observable contract) |
| [Architecture](docs/architecture.md) | How it is designed |
| [Verification Policy](docs/verification.md) | How correctness is verified |
| [Development Guide](docs/development.md) | How to develop, build, and test |
| [Reference](docs/reference.md) | Exact inventories (license provenance, diagnostic fields) |
| [Research Notes](docs/research.md) | What was investigated and why divergences were chosen |

Update this document only when assumptions that affect pre-implementation decisions change.
Do not duplicate API listings, call sequences, or tool version numbers here.
