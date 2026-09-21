# Numerical invariants

Every externally observable mole count, temperature, volume, heat capacity, pressure input, and intermediate returned to DM is finite. Mole counts and volume are non-negative. Existing public temperature bounds, including the cosmic microwave background floor, remain enforced. Immutable mixtures do not change through mutators.

Merge, remove, transfer, diffusion, and finite-capacity heat conduction conserve total moles or energy within an explicitly named tolerance derived independently of the implementation, except for the legacy numerical floor below. A source-free diffusion/conduction step does not create a value outside its connected component's pre-step extrema. Tests use literal/golden fixtures and property inputs; they do not compute expected results with the code under test.

The native engine retains the legacy `0.0001`-mole numerical floor and transfer precision. Positive per-gas amounts below `0.01` mole remain real gas, with heat capacity and reaction participation; splitting or reconciling a mixture must not delete them merely because a component is smaller than a centimole. Existing mutators may zero values at or below the legacy floor. Analyzer display rounding is not state mutation.

Diffusion topology is reciprocal, duplicate-free, self-edge-free, and cardinal-degree bounded at six including multiz. Invalid topology returns a diagnostic before processing. The current diffusion constant and relaxation budget are gameplay contracts; do not reinterpret the iteration budget as elapsed seconds or tune coefficients as an optimization.

Heat processing receives explicit elapsed seconds. Conductance updates must be stable for supported four- and six-neighbor graphs, unequal/zero/infinite capacities, and high conductivity. Space radiation applies once per elapsed interval. Deterministic inputs require deterministic event order and repeatable same-build values; cross-platform comparisons use documented tolerances where floating-point order differs.

Validate at the Rust domain boundary before mutation. Reject non-finite inputs with caller-legible context. Repair functions zero or clamp invalid state deliberately and invalidate dependent caches; they never hide corruption by leaving a stale value in place.

The in-process slow-decompression callback retains the historical one-quarter
of room-average moles limit per visited turf. Space frontage must not multiply
that loss into an immediate room-wide clear. Low-pressure excited-group mixing
must also respect the existing temperature suspension threshold across the
whole group; equal pressure alone does not justify erasing a thermal front.
