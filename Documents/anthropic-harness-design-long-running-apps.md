# Harness Design for Long-Running Application Development

**Source:** https://www.anthropic.com/engineering/harness-design-long-running-apps
**Author:** Prithvi Rajasekaran, Anthropic Labs

---

## Overview

Explores how to improve Claude's performance on two challenging domains: frontend design and autonomous full-stack development. The core insight—inspired by Generative Adversarial Networks (GANs)—is that **separating generation from evaluation dramatically improves output quality**.

---

## Core Problems with Naive Implementations

### Context Management Issues
- Models exhibit "context anxiety": they prematurely wrap up work as they approach perceived context limits
- **Compaction** helps but is imperfect
- **Context resets** provide a clean slate by moving to fresh agents with structured handoffs — adds complexity and token overhead but often worth it

### Self-Evaluation Failures
- Agents uncritically praise their own work
- Separating the **evaluator** from the **generator** is far more effective than making generators self-critical
- This is the key architectural principle: **never let the generator grade itself**

---

## Frontend Design: Making Subjectivity Measurable

To guide iterative design improvement, four grading criteria were developed:

| Criterion | Description |
|-----------|-------------|
| **Design Quality** | Cohesive visual identity: colors, typography, layout |
| **Originality** | Avoids generic patterns and recognizable "AI defaults" |
| **Craft** | Technical execution: spacing, hierarchy, contrast |
| **Functionality** | Usability and task completion |

- Criteria explicitly **penalized generic "AI slop" patterns**, emphasizing originality
- Evaluator used **Playwright** to interact with live pages
- Provided detailed feedback across **5–15 iterations**
- Result: generator moved from conventional layouts to innovative spatial CSS experiences

---

## Three-Agent Full-Stack Architecture

### Planner Agent
- Expands brief prompts into comprehensive product specifications
- Incorporates AI features and design direction

### Generator Agent
- Implements features iteratively
- Stack: React, Vite, FastAPI, SQLite/PostgreSQL
- Uses git version control throughout

### Evaluator Agent
- Tests running applications via **Playwright**
- Grades against **negotiated sprint contracts** with specific, testable criteria
- Before each sprint, generator and evaluator **negotiate a contract** defining success before implementation begins

---

## Sprint Contracts: A Key Pattern

> "Before each sprint, the generator and evaluator negotiated a sprint contract" defining success criteria before implementation.

This pattern:
- Prevents ambiguous success conditions
- Forces explicit criteria definition upfront
- Gives the evaluator objective ground truth to test against

---

## Comparative Results

### Retro Game Maker Example

| Run | Time | Cost | Outcome |
|-----|------|------|---------|
| Solo (no harness) | 20 min | $9 | Basic interface, broken gameplay mechanics |
| Full harness | 6 hr | $200 | Fully functional, polished UX, animation systems, AI-assisted generation |

- Evaluator caught critical failures: *"Rectangle fill tool only places tiles at drag start/end points instead of filling the region."*
- **20x more expensive but qualitatively superior**

### DAW Project (Claude Opus 4.6)
- Total time: 3 hr 50 min
- Cost: $124.70
- Multiple QA rounds still caught missing features: audio recording, effect visualizations

---

## Model Evolution and Harness Simplification

Claude Opus 4.6 improvements (better planning, longer task sustainability, improved code review) allowed:
- Removing sprint decomposition structure that was necessary in earlier models
- Simplifying the harness over time as model capability grew

Key insight: **the necessity of each harness component should be re-evaluated as model capability improves**

---

## Key Insights

1. **Task decomposition matters less as models improve** — harness architecture should evolve accordingly, removing scaffolding that is no longer load-bearing
2. **Grading criteria directly shape output** — phrasing like "museum quality" tangibly influences aesthetic direction; criteria design is as important as architecture design
3. **External evaluation is load-bearing** — catches subtle bugs and design gaps that generators consistently miss
4. **The harness-model relationship is dynamic**: *"Every component in a harness encodes an assumption about what the model can't do on its own"* — stress-test those assumptions continuously

---

## Forward Perspective

As capabilities expand:
- The space for sophisticated harnesses **shifts**, not shrinks
- Developers should **continuously stress-test assumptions** about what models need
- Remove unnecessary scaffolding; add specialized agents for genuinely hard sub-tasks
- The harness is a **living system**, not a fixed architecture

---

## Applicability to Evaluation Harnesses

Though framed around application development, the patterns directly transfer to test/eval harnesses:

- **Separate evaluator from generator** — never let the system that produces output also grade it
- **Sprint contracts ≈ test contracts** — define expected field values/formats before running extraction
- **Playwright-style live interaction** — evaluate against running outputs, not static snapshots
- **Iterative grading criteria** — criteria wording shapes what you get; refine criteria as a first-class task
- **Context management** — long-running evaluation pipelines need structured handoffs, not just compaction
