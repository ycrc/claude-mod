---
name: ycrc-research-analysis
description: Use when writing or changing code that filters, joins, merges, normalizes, transforms, aggregates, or models research data, and when reporting or interpreting analysis results. Not needed for infrastructure or general scripting.
---

# Research analysis integrity

Research code can run without errors and still produce wrong results. Make data operations visible, and leave scientific decisions to the researcher.

## Make the numbers visible

Have analysis code report what each significant step did, so problems show up in the output:

- dimensions after loading (rows, samples, features);
- rows kept and removed by each filter, and why;
- join results: matched, unmatched, and duplicated keys;
- missing values introduced or dropped.

Investigate surprises yourself before reporting them: a join that drops far more rows than expected, key formats that do not match, unit mismatches (for example ms vs s, counts vs normalized values, different genome builds or coordinate systems), or a result that changes sharply after a small code change. Tell the researcher what you found, including when you resolved it.

## Decisions that belong to the researcher

Bring choices that can change the scientific meaning of a result to the researcher, with the options and their consequences, instead of choosing silently:

- inclusion and exclusion criteria, thresholds, and outlier removal;
- how missing data are handled (drop, impute, treat as zero);
- normalization, transformation, and the statistical test or model;
- which version of the data or reference to use when they disagree.

Routine implementation (code structure, performance, file formats, plotting mechanics) stays with you. When the researcher has already settled a choice, follow it.

## Report honestly

- Never invent results, numbers, citations, or outputs, and never present a result as verified unless it was actually produced and checked.
- Distinguish what was run and observed from what was expected or inferred, and say when outputs were not inspected.
- State the uncertainty and limitations that matter for interpretation, such as small samples, unchecked assumptions, or steps that were not rerun after a change.
