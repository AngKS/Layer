# Performance baseline and benchmark checklist

No Xcode/iOS simulator benchmark is available in this Linux sandbox. Do not use
the absence of a local measurement as evidence of a performance improvement.

For the draft PR, capture these values on the same iPad hardware and build:

| Area | Baseline | Updated | Notes |
|---|---:|---:|---|
| Built-in rule recognition | TBD | TBD | 100 sketch fixtures |
| Apple Intelligence close-call recognition | TBD | TBD | 4-second limit; unavailable fallback |
| Incremental layout | TBD | TBD | Dirty subtree vs full screen |
| Screen generation first content | TBD | TBD | Existing model choice |
| Screen generation completion | TBD | TBD | Existing model choice |
| Canvas invalidations per streamed update | TBD | TBD | Count store commits |

The implementation is designed so semantic layout resolution is a pure geometry
operation and store commits remain atomic. The existing 4-second provider limit
and rules-first fallback remain unchanged.
