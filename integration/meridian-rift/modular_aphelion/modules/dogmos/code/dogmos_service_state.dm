/** Service-owned Dogmos state retained by Dream Maker only for identity translation. */
/datum/controller/subsystem/dogmos
	/// TRUE once this controller has permanently relinquished its service state.
	var/dogmos_runtime_state_released = FALSE
	/// TRUE after this destination has adopted once, including an uninitialized failed session.
	var/dogmos_runtime_state_adopted = FALSE
	/// Whether the production service passed identity and health checks.
	var/service_ready = FALSE
	/// Whether the first authoritative service failure has already emitted its diagnostic.
	var/service_failure_latched = FALSE
	/// Whether intentional shutdown has closed admission for late asynchronous producers.
	var/service_shutdown_requested = FALSE
	/// Opaque ownership tokens indexed by bounded IPC slot; tokens never retain mixtures.
	var/list/dogmos_mixture_slots = list()
	/// Current generation for every allocated mixture slot.
	var/list/dogmos_mixture_generations = list()
	/// Reusable mixture slots released by lifecycle unregister.
	var/list/dogmos_free_mixture_slots = list()
	/// Mixture unregister records deferred until the committed-frontier topology barrier.
	var/list/dogmos_pending_mixture_unregistrations = list()
	/// Dense numeric gas id keyed by DM gas path and native string id.
	var/list/dogmos_gas_ids = list()
	/// Gas paths indexed by numeric gas id plus one.
	var/list/dogmos_gas_paths = list()
	/// Reaction datums indexed by numeric reaction id plus one.
	var/list/dogmos_reaction_ids = list()
	/// Weak arbitrary-holder references indexed by bounded IPC slot.
	var/list/dogmos_holder_slots = list()
	/// Current generation for every arbitrary-holder slot.
	var/list/dogmos_holder_generations = list()
	/// Reusable arbitrary-holder slots.
	var/list/dogmos_free_holder_slots = list()
	/// Next expected callback sequence as four exact little-endian 16-bit words.
	var/list/dogmos_next_callback_sequence = list(1, 0, 0, 0)
	/// Callback batch retained across SSair fires when the current time budget expires.
	var/list/dogmos_pending_callback_batch
	/// Zero-based event index within the retained callback batch.
	var/dogmos_pending_callback_index = 0
	/// Event count validated when the retained batch was received, reused across resumes so
	/// process_atmos_callbacks() doesn't re-validate and re-walk the whole batch every call.
	var/dogmos_pending_callback_count = 0
	/// Number of callbacks still queued in dogmosd after the retained batch.
	var/dogmos_pending_service_callbacks = 0
	/// Number of stale turf callbacks rejected before invoking a gameplay proc.
	var/dogmos_stale_callback_count = 0
	/// Number of explicit health preflights performed by SSair fires.
	var/dogmos_health_preflight_count = 0
	/// Whether startup turf mutations are accumulating in bounded IPC batches.
	var/turf_registration_batching = FALSE
	/// Pending fixed-width turf lifecycle records keyed by turf slot.
	var/list/dogmos_pending_turf_lifecycle = list()
	/// Pending fixed-width turf adjacency records keyed by canonical slot pair.
	var/list/dogmos_pending_turf_adjacency = list()
	/// Reverse index: turf slot (string) -> set of dogmos_pending_turf_adjacency keys touching it.
	/// Lets discard_pending_turf_adjacencies() evict one turf's stale edges in O(its own degree)
	/// instead of scanning the entire pending batch - the scan cost otherwise multiplies against
	/// every register_dogmos_air() call in a startup/runtime rebuild, which is unnoticeable on a
	/// handful of test turfs but quadratic-ish and multi-minute on a real map's turf count.
	var/list/dogmos_pending_turf_adjacency_index = list()
	/// Pending fixed-width turf heat records keyed by turf slot.
	var/list/dogmos_pending_turf_heat = list()
	/// Pending fixed-width turf heat-adjacency records keyed by canonical slot pair.
	var/list/dogmos_pending_turf_heat_adjacency = list()
	/// Reverse index: turf slot (string) -> set of dogmos_pending_turf_heat_adjacency keys touching it.
	var/list/dogmos_pending_turf_heat_adjacency_index = list()
	/// Turfs whose adjacency pass must be retried after startup registration or a runtime stage barrier.
	var/list/dogmos_pending_adjacency_retry = list()
	/// Whether one runtime adjacency queue is coalescing repeated turf updates.
	var/runtime_topology_batching = FALSE
	/// Number of runtime topology records accepted by dogmosd.
	var/dogmos_runtime_topology_records = 0
	/// Number of runtime topology IPC calls accepted by dogmosd.
	var/dogmos_runtime_topology_calls = 0
	/// Maximum combined queued runtime topology mutations.
	var/dogmos_runtime_topology_max_queued = 0
	/// Number of topology flushes deferred behind a pending simulation stage.
	var/dogmos_runtime_topology_deferrals = 0
	/// Fixed-size direct-mapped cache of service mixture snapshots.
	var/list/dogmos_mixture_cache
	/// Exact integer epoch invalidating every cached snapshot in O(1).
	var/dogmos_mixture_cache_epoch = 1
	/// Number of mixture snapshot cache hits.
	var/dogmos_mixture_cache_hits = 0
	/// Number of mixture snapshot cache misses.
	var/dogmos_mixture_cache_misses = 0
	/// Number of live direct-mapped entries displaced by another handle.
	var/dogmos_mixture_cache_collisions = 0
	/// Number of stage-wide cache epoch invalidations.
	var/dogmos_mixture_cache_epoch_invalidations = 0

/** Preserves the live service session and transfers its DM identity boundary during MC recovery. */
/datum/controller/subsystem/dogmos/Recover()
	adopt_runtime_state(SSdogmos)

/**
 * Adopts every recoverable field, then revokes the previous owner without yielding.
 *
 * Only a fresh, inactive controller may adopt. Failure and shutdown state are preserved;
 * this operation never starts a service, recreates gas state or modifies a transferred list.
 * Arguments:
 * * previous_owner - Controller relinquishing the same live or failed service session.
 */
/datum/controller/subsystem/dogmos/proc/adopt_runtime_state(datum/controller/subsystem/dogmos/previous_owner)
	if(!previous_owner || previous_owner == src || previous_owner.dogmos_runtime_state_released || QDELETED(previous_owner))
		CRASH("Dogmos recovery requires an unreleased previous owner.")
	if(gases_registered || service_ready || dogmos_runtime_state_released || dogmos_runtime_state_adopted)
		CRASH("Dogmos recovery requires a fresh inactive destination.")
	dogmos_runtime_state_adopted = TRUE
	ss_flags |= SS_NO_INIT
	initialized = previous_owner.initialized
	gases_registered = previous_owner.gases_registered
	service_ready = previous_owner.service_ready
	service_failure_latched = previous_owner.service_failure_latched
	service_shutdown_requested = previous_owner.service_shutdown_requested
	dogmos_mixture_slots = previous_owner.dogmos_mixture_slots
	dogmos_mixture_generations = previous_owner.dogmos_mixture_generations
	dogmos_free_mixture_slots = previous_owner.dogmos_free_mixture_slots
	dogmos_pending_mixture_unregistrations = previous_owner.dogmos_pending_mixture_unregistrations
	dogmos_gas_ids = previous_owner.dogmos_gas_ids
	dogmos_gas_paths = previous_owner.dogmos_gas_paths
	dogmos_reaction_ids = previous_owner.dogmos_reaction_ids
	dogmos_holder_slots = previous_owner.dogmos_holder_slots
	dogmos_holder_generations = previous_owner.dogmos_holder_generations
	dogmos_free_holder_slots = previous_owner.dogmos_free_holder_slots
	dogmos_next_callback_sequence = previous_owner.dogmos_next_callback_sequence
	dogmos_pending_callback_batch = previous_owner.dogmos_pending_callback_batch
	dogmos_pending_callback_index = previous_owner.dogmos_pending_callback_index
	dogmos_pending_callback_count = previous_owner.dogmos_pending_callback_count
	dogmos_pending_service_callbacks = previous_owner.dogmos_pending_service_callbacks
	dogmos_stale_callback_count = previous_owner.dogmos_stale_callback_count
	dogmos_health_preflight_count = previous_owner.dogmos_health_preflight_count
	turf_registration_batching = previous_owner.turf_registration_batching
	dogmos_pending_turf_lifecycle = previous_owner.dogmos_pending_turf_lifecycle
	dogmos_pending_turf_adjacency = previous_owner.dogmos_pending_turf_adjacency
	dogmos_pending_turf_adjacency_index = previous_owner.dogmos_pending_turf_adjacency_index
	dogmos_pending_turf_heat = previous_owner.dogmos_pending_turf_heat
	dogmos_pending_turf_heat_adjacency = previous_owner.dogmos_pending_turf_heat_adjacency
	dogmos_pending_turf_heat_adjacency_index = previous_owner.dogmos_pending_turf_heat_adjacency_index
	dogmos_pending_adjacency_retry = previous_owner.dogmos_pending_adjacency_retry
	runtime_topology_batching = previous_owner.runtime_topology_batching
	dogmos_runtime_topology_records = previous_owner.dogmos_runtime_topology_records
	dogmos_runtime_topology_calls = previous_owner.dogmos_runtime_topology_calls
	dogmos_runtime_topology_max_queued = previous_owner.dogmos_runtime_topology_max_queued
	dogmos_runtime_topology_deferrals = previous_owner.dogmos_runtime_topology_deferrals
	dogmos_mixture_cache = previous_owner.dogmos_mixture_cache
	dogmos_mixture_cache_epoch = previous_owner.dogmos_mixture_cache_epoch
	dogmos_mixture_cache_hits = previous_owner.dogmos_mixture_cache_hits
	dogmos_mixture_cache_misses = previous_owner.dogmos_mixture_cache_misses
	dogmos_mixture_cache_collisions = previous_owner.dogmos_mixture_cache_collisions
	dogmos_mixture_cache_epoch_invalidations = previous_owner.dogmos_mixture_cache_epoch_invalidations
	previous_owner.release_runtime_state()

/**
 * Relinquishes references and admission after transfer; repeated release is harmless.
 *
 * Assign null rather than clearing lists: the new owner now holds their exact contents.
 * No native call or SSair mutation belongs here, including begin_service_shutdown().
 */
/datum/controller/subsystem/dogmos/proc/release_runtime_state()
	dogmos_runtime_state_released = TRUE
	gases_registered = FALSE
	service_ready = FALSE
	service_shutdown_requested = TRUE
	ss_flags |= SS_NO_INIT | SS_NO_FIRE
	can_fire = FALSE
	turf_registration_batching = FALSE
	runtime_topology_batching = FALSE
	dogmos_pending_callback_index = 0
	dogmos_pending_callback_count = 0
	dogmos_pending_service_callbacks = 0
	dogmos_mixture_slots = null
	dogmos_mixture_generations = null
	dogmos_free_mixture_slots = null
	dogmos_pending_mixture_unregistrations = null
	dogmos_gas_ids = null
	dogmos_gas_paths = null
	dogmos_reaction_ids = null
	dogmos_holder_slots = null
	dogmos_holder_generations = null
	dogmos_free_holder_slots = null
	dogmos_next_callback_sequence = null
	dogmos_pending_callback_batch = null
	dogmos_pending_turf_lifecycle = null
	dogmos_pending_turf_adjacency = null
	dogmos_pending_turf_adjacency_index = null
	dogmos_pending_turf_heat = null
	dogmos_pending_turf_heat_adjacency = null
	dogmos_pending_turf_heat_adjacency_index = null
	dogmos_pending_adjacency_retry = null
	dogmos_mixture_cache = null
