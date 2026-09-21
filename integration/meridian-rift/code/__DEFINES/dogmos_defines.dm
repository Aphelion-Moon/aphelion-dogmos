// Hand-maintained Dogmos constants that have no generated binding of their own - they're plain
// numeric bit values the Rust fork expects on specific FFI calls, not proc/var bindings that
// `cargo test generate_binds` would emit. Do not move these into dogmos_bindings.dm (generated;
// keep them aligned with the Rust definitions).

/// SimulationFlags bit for /turf/proc/update_air_ref(flag): fully active, normally-simulated turf
/// (a plain open floor). Matches Rust's SimulationFlags::SIMULATION_ALL (aphelion-dogmos src/turfs.rs).
#define DOGMOS_SIMULATION_ALL (1<<1)
/// SimulationFlags bit for update_air_ref(flag): a semi-permeable turf that diffuses air without
/// being a fully active simulation node (e.g. a grille/window). Matches SimulationFlags::SIMULATION_DIFFUSE.
#define DOGMOS_SIMULATION_DIFFUSE (1<<0)
/// Pass to update_air_ref() to remove/unregister a turf from Dogmos' gas graph entirely (any negative
/// value works per hook_register_turf's `flag >= 0` check, but this name documents intent at call sites).
#define DOGMOS_SIMULATION_NONE -1
/// Pass to update_air_ref() when a turf replacement removes the old turf from both Dogmos graphs.
/// Unlike DOGMOS_SIMULATION_NONE, this does not perform the heat-only registration used when an open
/// turf has not created its air datum yet.
#define DOGMOS_SIMULATION_REMOVE -3
/// Sentinel (not a real SimulationFlags bit) for /turf/open/space/register_dogmos_air() to pass to
/// update_air_ref(). Registers the turf as a present-but-never-processed, immutable gas-graph node
/// instead of a normal SIMULATION_ALL turf - see hook_register_turf's SPACE_BOUNDARY_FLAG handling
/// (aphelion-dogmos src/turfs.rs) for why space needs this rather than the ordinary path. Must stay
/// numerically distinct from every real SimulationFlags value and from DOGMOS_SIMULATION_NONE.
#define DOGMOS_SIMULATION_SPACE_BOUNDARY -2

/// AdjacentFlags bit written into atmos_adjacent_turfs list values, consumed by
/// __update_auxtools_turf_adjacency_info(). Matches Rust's AdjacentFlags::ATMOS_ADJACENT_FIRELOCK.
#define DOGMOS_ADJACENT_FIRELOCK (1<<1)

/// Selects the legacy DM turf temperature for blocked-turf consumers.
#define DOGMOS_TEMPERATURE_AUTHORITY_DM 0
/// Selects the registered Dogmos TurfHeat temperature for blocked-turf consumers, falling back to DM
/// when a turf has no heat-graph node.
#define DOGMOS_TEMPERATURE_AUTHORITY_RUST 1

/// Runs FDM pressure diffusion without Katmos whole-zone equalization.
#define DOGMOS_EQUALIZE_PROFILE_FDM_ONLY 0
/// Runs the current Katmos whole-zone equalizer after FDM pressure diffusion.
#define DOGMOS_EQUALIZE_PROFILE_FAST_ZONE 1

/// Preserves the original flamethrower hotspot exposure when its directional-spread setting is off.
#define DOGMOS_FLAMETHROWER_LEGACY_HOTSPOT_EXPOSURE_VOLUME 500
/// Keeps a flamethrower's initial hotspot below LINDA's bypass threshold, so its radiated heat does not
/// create a second fire source behind the user. Gas diffusion and ordinary hotspot spread still apply.
#define DOGMOS_FLAMETHROWER_HOTSPOT_EXPOSURE_VOLUME (CELL_VOLUME / 50)
/// Number of valid projection turfs skipped before a directional flamethrower starts igniting.
#define DOGMOS_FLAMETHROWER_DIRECTIONAL_START_TILES 1

// APHELION EDIT ADDITION START - DOGMOS
/// Station-safe goggles mode that marks recent decompression breaches.
#define DOGMOS_GOGGLE_MODE_BREACHES "breach alerts"
/// Station-safe goggles mode that marks recent reaction hotspots.
#define DOGMOS_GOGGLE_MODE_REACTIONS "reaction profile"
/// Administrative goggles mode that marks reactions exceeding the measured cost threshold.
#define DOGMOS_GOGGLE_MODE_HIGH_COST "cost profile"
/// Administrative goggles mode that marks structures pinned by Kennel diagnostics.
#define DOGMOS_GOGGLE_MODE_STRUCTURES "structure pins"
/// Administrative goggles mode that displays every Kennel diagnostic overlay.
#define DOGMOS_GOGGLE_MODE_ALL "full kennel"

/// Kennel overlay category for recent decompression breaches.
#define KENNEL_OVERLAY_BREACH "breach"
/// Kennel overlay category for reactions exceeding the measured cost threshold.
#define KENNEL_OVERLAY_HIGH_COST "high_cost"
/// Kennel overlay category for recent reaction hotspots.
#define KENNEL_OVERLAY_REACTION "reaction"
/// Kennel overlay category for structures pinned by diagnostics.
#define KENNEL_OVERLAY_STRUCTURE "structure"
/// Maximum turfs lit per Kennel event overlay category.
#define KENNEL_OVERLAY_RECENT_CAP 15
// APHELION EDIT ADDITION END
