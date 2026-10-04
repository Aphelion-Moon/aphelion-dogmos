use super::*;
use byondapi::{byond_string, prelude::*};
//use indexmap::IndexSet;
use crate::GasArena;
use coarsetime::Instant;
use dogmos_core::numerics::conduction::{
	conduction_step_cancellable_with_scratch, BASE_HEAT_STEP_SECONDS,
};
use eyre::Result;
use parking_lot::{const_mutex, Mutex};
use std::{
	collections::HashSet,
	sync::{
		atomic::{AtomicBool, AtomicUsize, Ordering},
		LazyLock,
	},
};

type HeatNodeIndex = petgraph::graph::NodeIndex<usize>;

static TURF_HEAT: RwLock<Option<TurfHeat>> = const_rwlock(None);
static HEAT_WORKER: Mutex<Option<std::thread::JoinHandle<()>>> = const_mutex(None);
// The main-thread caller resumes this same interval if the worker queue is full.
static PENDING_HEAT: Mutex<Option<SSheatInfo>> = const_mutex(None);
static OUTSTANDING_HEAT: AtomicUsize = AtomicUsize::new(0);

static HEAT_CHANNEL: LazyLock<(
	flume::Sender<HeatWorkerMessage<'static>>,
	flume::Receiver<HeatWorkerMessage<'static>>,
)> = LazyLock::new(|| flume::bounded(1));

static HEAT_REGISTRATION_CHANGES: AtomicUsize = AtomicUsize::new(0);
static HEAT_REGISTRATION_TOTAL: AtomicUsize = AtomicUsize::new(0);
static HEAT_SHUTDOWN: AtomicBool = AtomicBool::new(false);
static HEAT_WORKER_RUNNING: AtomicBool = AtomicBool::new(false);

fn new_turf_heat() -> TurfHeat {
	TurfHeat {
		graph: StableDiGraph::with_capacity(0, 0),
		map: IndexMap::with_hasher(FxBuildHasher),
	}
}

fn try_start_heat_worker(worker_running: &AtomicBool) -> bool {
	worker_running
		.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
		.is_ok()
}

fn record_registration_change(pending: &AtomicUsize, total: &AtomicUsize) {
	pending.fetch_add(1, Ordering::Relaxed);
	total.fetch_add(1, Ordering::Relaxed);
}

#[auxmacros::init]
fn initialize_heat_statics() {
	HEAT_SHUTDOWN.store(false, Ordering::Release);
	*TURF_HEAT.write() = Some(new_turf_heat());
}

// Called by the exported DM shutdown hook before the remaining arenas are released.
#[allow(dead_code)]
pub fn shutdown_turf_heat() -> Result<()> {
	HEAT_SHUTDOWN.store(true, Ordering::Release);
	*PENDING_HEAT.lock() = None;
	let _ = HEAT_CHANNEL.0.try_send(HeatWorkerMessage::Shutdown);
	let Some(worker) = HEAT_WORKER.lock().take() else {
		if HEAT_WORKER_RUNNING.load(Ordering::Acquire) {
			return Err(eyre::eyre!(
				"Heat worker is running without an owned thread handle"
			));
		}
		HEAT_CHANNEL.1.try_iter().for_each(std::mem::drop);
		TURF_HEAT.write().take();
		return Ok(());
	};
	let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
	while !worker.is_finished() && std::time::Instant::now() < deadline {
		std::thread::sleep(std::time::Duration::from_millis(1));
	}
	if !worker.is_finished() {
		*HEAT_WORKER.lock() = Some(worker);
		return Err(eyre::eyre!(
			"Heat worker failed to stop within 5 seconds, this may indicate a deadlock"
		));
	}
	worker
		.join()
		.map_err(|_| eyre::eyre!("Heat worker panicked during shutdown"))?;
	HEAT_CHANNEL.1.try_iter().for_each(std::mem::drop);
	TURF_HEAT.write().take();
	Ok(())
}

/// Recreates heat state and rearms the worker after a BYOND world reuses this loaded DLL.
pub fn prepare_turf_heat_for_world() -> Result<()> {
	*PENDING_HEAT.lock() = None;
	if TURF_HEAT.read().is_none() {
		HEAT_CHANNEL.1.try_iter().for_each(std::mem::drop);
		*TURF_HEAT.write() = Some(new_turf_heat());
	}
	HEAT_REGISTRATION_CHANGES.store(0, Ordering::Relaxed);
	HEAT_SHUTDOWN.store(false, Ordering::Release);
	start_heat_worker()
}

fn with_turf_heat_read<T, F>(f: F) -> T
where
	F: FnOnce(&TurfHeat) -> T,
{
	f(TURF_HEAT.read().as_ref().unwrap())
}

fn with_turf_heat_write<T, F>(f: F) -> T
where
	F: FnOnce(&mut TurfHeat) -> T,
{
	f(TURF_HEAT.write().as_mut().unwrap())
}

#[derive(Copy, Clone, Debug, PartialEq)]
struct SSheatInfo {
	time_delta: f64,
	/// Selects Stefan-Boltzmann radiation instead of the faster linear vacuum sink.
	blackbody_enabled: bool,
}

// Ownership starts before publication and ends after the worker's last callback enqueue.
// TASKS alone cannot cover a queued request or the gap between dequeue and its read guard.
struct HeatWork<'a>(&'a AtomicUsize);

impl<'a> HeatWork<'a> {
	fn new(outstanding: &'a AtomicUsize) -> Self {
		outstanding.fetch_add(1, Ordering::AcqRel);
		Self(outstanding)
	}
}

impl Drop for HeatWork<'_> {
	fn drop(&mut self) {
		self.0.fetch_sub(1, Ordering::Release);
	}
}

pub(super) fn heat_work_pending() -> bool {
	OUTSTANDING_HEAT.load(Ordering::Acquire) != 0 || PENDING_HEAT.lock().is_some()
}

enum HeatWorkerMessage<'a> {
	Process(SSheatInfo, HeatWork<'a>),
	Shutdown,
}

#[derive(Default)]
struct ThermalInfo {
	pub id: TurfID,
	pub generation: u32,

	pub thermal_conductivity: f32,
	pub heat_capacity: f32,
	pub adjacent_to_space: bool,

	pub temperature: RwLock<f32>,
}

fn with_heat_processing_callback_receiver<T>(
	f: impl Fn(&flume::Receiver<HeatWorkerMessage<'static>>) -> T,
) -> T {
	f(&HEAT_CHANNEL.1)
}

// Only the main thread submits heat work. Capture DM values outside the pending lock,
// and retry a rejected interval unchanged even if SSair's settings changed meanwhile.
fn submit_heat_interval<'a>(
	sender: &flume::Sender<HeatWorkerMessage<'a>>,
	pending: &Mutex<Option<SSheatInfo>>,
	outstanding: &'a AtomicUsize,
	capture: impl FnOnce() -> Result<SSheatInfo>,
) -> Result<bool> {
	let previous = pending.lock().take();
	let info = match previous {
		Some(info) => info,
		None => capture()?,
	};
	match sender.try_send(HeatWorkerMessage::Process(info, HeatWork::new(outstanding))) {
		Ok(()) => Ok(false),
		Err(error) => {
			*pending.lock() = Some(info);
			match error {
				flume::TrySendError::Full(_) => Ok(true),
				flume::TrySendError::Disconnected(_) => {
					Err(eyre::eyre!("Heat worker request channel disconnected"))
				}
			}
		}
	}
}
type HeatGraphMap = IndexMap<TurfID, NodeIndex<usize>, FxBuildHasher>;

//turf temperature infos goes here
struct TurfHeat {
	graph: StableDiGraph<ThermalInfo, (), usize>,
	map: HeatGraphMap,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct HeatRuntimeMetrics {
	pub nodes: usize,
	pub edges: usize,
	pub node_capacity: usize,
	pub edge_capacity: usize,
	pub map_capacity: usize,
	pub thermal_info_bytes: usize,
}

impl TurfHeat {
	fn runtime_metrics(&self) -> HeatRuntimeMetrics {
		let (node_capacity, edge_capacity) = self.graph.capacity();
		HeatRuntimeMetrics {
			nodes: self.graph.node_count(),
			edges: self.graph.edge_count(),
			node_capacity,
			edge_capacity,
			map_capacity: self.map.capacity(),
			thermal_info_bytes: std::mem::size_of::<ThermalInfo>(),
		}
	}

	pub fn insert_turf(&mut self, info: ThermalInfo) -> bool {
		if let Some(&node_id) = self.map.get(&info.id) {
			let thin = self.graph.node_weight_mut(node_id).unwrap();
			thin.thermal_conductivity = info.thermal_conductivity;
			thin.heat_capacity = info.heat_capacity;
			thin.adjacent_to_space = info.adjacent_to_space;
			thin.generation = info.generation;
			false
		} else {
			self.map.insert(info.id, self.graph.add_node(info));
			true
		}
	}

	pub fn remove_turf(&mut self, id: TurfID) -> bool {
		// `swap_remove` rather than `shift_remove`, which memmoves every following entry. Nothing
		// downstream depends on this map's order: the node set it yields is order-independent,
		// the dense snapshot sorts `touched_nodes`, and the conduction kernel canonicalizes and sorts
		// its edges before applying any substep, so the temperatures come out the same either way.
		if let Some(index) = self.map.swap_remove(&id) {
			self.graph.remove_node(index);
			true
		} else {
			false
		}
	}

	pub fn get(&self, idx: NodeIndex<usize>) -> Option<&ThermalInfo> {
		self.graph.node_weight(idx)
	}

	pub fn get_id(&self, idx: &TurfID) -> Option<&NodeIndex<usize>> {
		self.map.get(idx)
	}

	pub fn adjacent_node_ids(
		&self,
		index: NodeIndex<usize>,
	) -> impl Iterator<Item = NodeIndex<usize>> + '_ {
		self.graph.neighbors(index)
	}

	pub fn adjacent_heats(
		&self,
		index: NodeIndex<usize>,
	) -> impl Iterator<Item = &ThermalInfo> + '_ {
		self.graph
			.neighbors(index)
			.filter_map(|neighbor| self.graph.node_weight(neighbor))
	}

	pub fn update_adjacencies(
		&mut self,
		idx: TurfID,
		blocked_dirs: Directions,
		max_x: i32,
		max_y: i32,
	) {
		if let Some(&this_node) = self.get_id(&idx) {
			self.remove_adjacencies(this_node);
			for (_, adj_idx) in adjacent_tile_ids(
				Directions::ALL_CARDINALS_MULTIZ - blocked_dirs,
				idx,
				max_x,
				max_y,
			) {
				if let Some(&adjacent_node) = self.get_id(&adj_idx) {
					// Coordinate reuse can resolve a neighbor to the current node; a self-edge cannot
					// exchange heat and must not enter the graph.
					if adjacent_node != this_node {
						self.graph.add_edge(this_node, adjacent_node, ());
					}
				}
			}
		}
	}

	pub fn remove_adjacencies(&mut self, index: NodeIndex<usize>) {
		// Same as the gas graph: the heat adjacency update runs on the same hot registration path,
		// and bounded degree makes the buffering `Vec` pure overhead.
		while let Some(edge) = self.graph.edges(index).next().map(|edge| edge.id()) {
			self.graph.remove_edge(edge);
		}
	}
}

pub(crate) fn heat_runtime_metrics() -> HeatRuntimeMetrics {
	TURF_HEAT.read().as_ref().map_or_else(
		|| HeatRuntimeMetrics {
			thermal_info_bytes: std::mem::size_of::<ThermalInfo>(),
			..Default::default()
		},
		TurfHeat::runtime_metrics,
	)
}

pub fn supercond_update_ref(src: ByondValue) -> Result<()> {
	let id = src.get_ref()?;
	let therm_cond = src
		.read_number_id(byond_string!("thermal_conductivity"))
		.unwrap_or(0.0);
	let therm_cap = src
		.read_number_id(byond_string!("heat_capacity"))
		.unwrap_or(0.0);
	let registration_changed = if therm_cond > 0.0 && therm_cap > 0.0 {
		let therm_info = ThermalInfo {
			id,
			generation: src
				.read_number_id(byond_string!("dogmos_registration_generation"))
				.unwrap_or(0.0) as u32,
			adjacent_to_space: src
				.call_id(byond_string!("should_conduct_to_space"), &[])?
				.get_number()?
				> 0.0,
			heat_capacity: therm_cap,
			thermal_conductivity: therm_cond,
			temperature: RwLock::new(
				src.read_number_id(byond_string!("initial_temperature"))
					.unwrap_or(TCMB),
			),
		};
		with_turf_heat_write(|arena| arena.insert_turf(therm_info))
	} else {
		with_turf_heat_write(|arena| arena.remove_turf(id))
	};
	if registration_changed {
		record_registration_change(&HEAT_REGISTRATION_CHANGES, &HEAT_REGISTRATION_TOTAL);
	}
	Ok(())
}

/// Removes a turf from the heat graph and records the registration change.
pub fn remove_turf(id: TurfID) {
	with_turf_heat_write(|arena| {
		if arena.remove_turf(id) {
			record_registration_change(&HEAT_REGISTRATION_CHANGES, &HEAT_REGISTRATION_TOTAL);
		}
	});
}

// Map bounds are supplied by DM because World intrinsic properties are not regular FFI vars.
pub fn supercond_update_adjacencies(id: u32, max_x: i32, max_y: i32) -> Result<()> {
	let src_turf = ByondValue::new_ref(ValueType::Turf, id);
	let blocked_dirs = src_turf
		.read_number_id(byond_string!("conductivity_blocked_directions"))
		.ok();
	with_turf_heat_write(|arena| -> Result<()> {
		if let Some(blocked_dirs) = blocked_dirs {
			let actual_dir = Directions::from_bits_truncate(blocked_dirs as u8);
			arena.update_adjacencies(id, actual_dir, max_x, max_y)
		} else if let Some(&idx) = arena.get_id(&id) {
			arena.remove_adjacencies(idx)
		}
		Ok(())
	})?;
	Ok(())
}

// This overrides the existing atom temperature proc for registered heat nodes.
#[auxmacros::bind("/turf/return_temperature")]
fn hook_turf_temperature(src: ByondValue) -> Result<ByondValue> {
	let native_temperature = hook_dogmos_heat_temperature(src)?;
	if !native_temperature.is_null() {
		return Ok(native_temperature);
	}
	// Preserve the game's DM fallback for unregistered or nonconducting turfs.
	let temperature = src.read_number_id(byond_string!("temperature"))?;
	if !temperature.is_finite() {
		return Err(eyre::eyre!("Turf fallback temperature must be finite"));
	}
	Ok(temperature.into())
}

// Return null for unregistered nodes so DM can use its compatibility temperature.
#[auxmacros::bind("/turf/proc/__dogmos_heat_temperature")]
fn hook_dogmos_heat_temperature(src: ByondValue) -> Result<ByondValue> {
	let id = src.get_ref()?;
	with_turf_heat_read(|arena| -> Result<ByondValue> {
		let Some(&node_index) = arena.get_id(&id) else {
			return Ok(ByondValue::null());
		};
		let info = arena.get(node_index).unwrap();
		let read = info.temperature.read();
		if read.is_finite() {
			Ok((*read).into())
		} else {
			Ok(ByondValue::null())
		}
	})
}

// Raw bind for the DM temperature wrapper. Writes before registration are safe no-ops because the
// wrapper also maintains the compatibility value.
#[auxmacros::bind("/turf/proc/__set_temperature")]
fn hook_turf_temperature_set(src: ByondValue, arg_temp: ByondValue) -> Result<ByondValue> {
	let id = src.get_ref()?;
	let v = arg_temp.get_number()?;
	if !v.is_finite() {
		return Err(eyre::eyre!(
			"Attempted to set a turf's temperature to a number that is NaN or infinite."
		));
	}
	set_turf_temperature(id, v);
	Ok(ByondValue::null())
}

fn set_turf_temperature(id: TurfID, temperature: f32) {
	// A heat pass holds the graph read lock from snapshot through commit.
	// Serialize absolute writes with that whole pass so its snapshot cannot erase them.
	with_turf_heat_write(|arena| {
		if let Some(&node_index) = arena.get_id(&id) {
			let info = arena.get(node_index).unwrap();
			*info.temperature.write() = temperature;
		}
	});
}

// Expected function call: process_turf_heat()
// Returns TRUE if SSair must pause and retry this interval, FALSE once admitted.
#[auxmacros::bind("/datum/controller/subsystem/air/proc/process_turf_heat")]
fn process_heat_notify(src: ByondValue) -> Result<ByondValue> {
	if HEAT_SHUTDOWN.load(Ordering::Acquire) {
		return Ok(ByondValue::null());
	}
	/*
		Replacing LINDA's superconductivity system is this much more brute-force
		system--it shares heat between turfs and their neighbors,
		then receives and emits radiation to space, then shares
		between turfs and their gases. Since the latter requires a write lock,
		it's done after the previous step. This one doesn't care about
		consistency like the processing step does--this can run in full parallel.
		Can't get a number from src in the thread, so we get it here.
		Have to get the time delta because the radiation
		is actually physics-based--the stefan boltzmann constant
		and radiation from space both have dimensions of second^-1 that
		need to be multiplied out to have any physical meaning.
		They also have dimensions of meter^-2, but I'm assuming
		turf tiles are 1 meter^2 anyway--the atmos subsystem
		does this in general, thus turf gas mixtures being 2.5 m^3.
	*/
	Ok(
		submit_heat_interval(&HEAT_CHANNEL.0, &PENDING_HEAT, &OUTSTANDING_HEAT, || {
			let wait = src.read_number_id(byond_string!("wait")).map_err(|_| {
				eyre::eyre!(
					"Attempt to interpret non-number value as number {} {}:{}",
					std::file!(),
					std::line!(),
					std::column!()
				)
			})?;
			if !wait.is_finite() || wait < 0.0 {
				return Err(eyre::eyre!(
					"Atmos heat budget must be finite and non-negative"
				));
			}
			let time_delta = f64::from(wait) / 10.0;
			// Preserve the physical model if the mode toggle cannot be read.
			let blackbody_enabled = src
				.read_number_id(byond_string!("realistic_space_radiation"))
				.map_or(true, |v| v != 0.0);
			Ok(SSheatInfo {
				time_delta,
				blackbody_enabled,
			})
		})?
		.into(),
	)
}

/// Threshold for BYOND's finite representation of infinite heat capacity.
const BYOND_INFINITY_THRESHOLD: f32 = 1e30;

/// Computes the energy share for two heat capacities.
fn get_share_energy(delta: f32, cap_1: f32, cap_2: f32) -> f32 {
	let cap_1_infinite = cap_1 >= BYOND_INFINITY_THRESHOLD;
	let cap_2_infinite = cap_2 >= BYOND_INFINITY_THRESHOLD;
	if cap_1_infinite && cap_2_infinite {
		return 0.0;
	}
	if cap_1_infinite {
		return delta * cap_2;
	}
	if cap_2_infinite {
		return delta * cap_1;
	}
	delta * harmonic_heat_capacity(cap_1, cap_2)
}

fn blackbody_temperature_after_cooling(
	temperature: f32,
	heat_capacity: f32,
	emissivity_constant: f64,
	radiation_from_space_tick: f64,
) -> f32 {
	if heat_capacity.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
		return TCMB;
	}
	let blackbody_radiation =
		(emissivity_constant * f64::from(temperature).powi(4)) - radiation_from_space_tick;
	let cooled_temperature =
		f64::from(temperature) - blackbody_radiation / f64::from(heat_capacity);
	cooled_temperature.max(f64::from(TCMB)) as f32
}

#[cfg(test)]
fn unique_heat_edges(
	edges: impl IntoIterator<Item = (HeatNodeIndex, HeatNodeIndex)>,
) -> Vec<(HeatNodeIndex, HeatNodeIndex)> {
	let mut seen: HashSet<(usize, usize), FxBuildHasher> = Default::default();
	let mut unique_edges = Vec::new();
	unique_heat_edges_into(edges, &mut seen, &mut unique_edges);
	unique_edges
}

fn unique_heat_edges_into(
	edges: impl IntoIterator<Item = (HeatNodeIndex, HeatNodeIndex)>,
	seen: &mut HashSet<(usize, usize), FxBuildHasher>,
	unique_edges: &mut Vec<(HeatNodeIndex, HeatNodeIndex)>,
) {
	seen.clear();
	unique_edges.clear();
	edges
		.into_iter()
		.filter_map(|(first, second)| {
			if first == second {
				return None;
			}
			let edge = if first.index() < second.index() {
				(first, second)
			} else {
				(second, first)
			};
			seen.insert((edge.0.index(), edge.1.index()))
				.then_some(edge)
		})
		.for_each(|edge| unique_edges.push(edge));
}

#[derive(Default)]
struct HeatProcessingScratch {
	seen_edges: HashSet<(usize, usize), FxBuildHasher>,
	unique_edges: Vec<(HeatNodeIndex, HeatNodeIndex)>,
	touched_nodes: Vec<HeatNodeIndex>,
	temperatures: Vec<f32>,
	conductivities: Vec<f32>,
	heat_capacities: Vec<f32>,
	dense_edges: Vec<(u32, u32)>,
	row_sums: Vec<f32>,
}

fn record_heat_metrics(
	telemetry: &dogmos_perf::Telemetry,
	nodes_scanned: usize,
	nodes_changed: usize,
	edges_attempted: usize,
	edges_applied: u64,
) {
	use dogmos_perf::RuntimeMetric;

	telemetry.increment_metric(RuntimeMetric::HeatNodesScanned, nodes_scanned as u64);
	telemetry.increment_metric(RuntimeMetric::HeatNodesChanged, nodes_changed as u64);
	telemetry.increment_metric(RuntimeMetric::HeatEdgesAttempted, edges_attempted as u64);
	telemetry.increment_metric(RuntimeMetric::HeatEdgesApplied, edges_applied);
}

#[cfg(all(test, feature = "katmos"))]
pub(crate) fn capture_two_turf_heat_trace() -> super::katmos::LegacyStageTrace {
	let mut temperatures = [1000.0, 300.0];
	let conductivities = [0.05, 0.05];
	let heat_capacities = [100.0, 200.0];
	dogmos_core::numerics::conduction::conduction_step(
		&mut temperatures,
		&conductivities,
		&heat_capacities,
		&[(0, 1)],
		0.5,
	)
	.unwrap();
	super::katmos::LegacyStageTrace {
		work_items: 2,
		left_value: temperatures[0],
		right_value: temperatures[1],
		pressure_events: Vec::new(),
	}
}

#[cfg(test)]
fn accumulate_heat_edge_deltas(
	edges: &[(HeatNodeIndex, HeatNodeIndex)],
	temperatures: &[f32],
	conductivities: &[f32],
	heat_capacities: &[f32],
) -> Vec<f32> {
	let mut deltas = Vec::new();
	accumulate_heat_edge_deltas_into(
		edges,
		temperatures,
		conductivities,
		heat_capacities,
		&mut deltas,
	);
	deltas
}

#[cfg(test)]
fn accumulate_heat_edge_deltas_into(
	edges: &[(HeatNodeIndex, HeatNodeIndex)],
	temperatures: &[f32],
	conductivities: &[f32],
	heat_capacities: &[f32],
	deltas: &mut Vec<f32>,
) {
	deltas.clear();
	deltas.resize(temperatures.len(), 0.0);
	for &(first, second) in edges {
		let first_index = first.index();
		let second_index = second.index();
		let shared_energy = conductivities[first_index].min(conductivities[second_index])
			* get_share_energy(
				temperatures[second_index] - temperatures[first_index],
				heat_capacities[first_index],
				heat_capacities[second_index],
			);
		deltas[first_index] += shared_energy / heat_capacities[first_index];
		deltas[second_index] -= shared_energy / heat_capacities[second_index];
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use dogmos_perf::RuntimeMetric;
	static HEAT_LIFECYCLE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

	#[test]
	fn turf_temperature_setter_survives_an_in_progress_heat_snapshot() {
		let _guard = HEAT_LIFECYCLE_TEST_LOCK.lock().unwrap();
		let mut arena = new_turf_heat();
		arena.insert_turf(ThermalInfo {
			id: 1,
			temperature: RwLock::new(300.0),
			..Default::default()
		});
		let previous = TURF_HEAT.write().replace(arena);
		let heat_pass = TURF_HEAT.read();
		let arena = heat_pass.as_ref().unwrap();
		let node = arena.get(*arena.get_id(&1).unwrap()).unwrap();
		let snapshot = *node.temperature.read();
		let (started, ready) = std::sync::mpsc::channel();
		let (finished, completion) = std::sync::mpsc::channel();
		let setter = std::thread::spawn(move || {
			started.send(()).unwrap();
			set_turf_temperature(1, 500.0);
			finished.send(()).unwrap();
		});
		ready
			.recv_timeout(std::time::Duration::from_secs(1))
			.unwrap();
		let finished_before_commit = completion
			.recv_timeout(std::time::Duration::from_millis(100))
			.is_ok();
		*node.temperature.write() = snapshot + 1.0;
		drop(heat_pass);
		if !finished_before_commit {
			completion
				.recv_timeout(std::time::Duration::from_secs(1))
				.unwrap();
		}
		setter.join().unwrap();
		let final_temperature = with_turf_heat_read(|arena| {
			*arena
				.get(*arena.get_id(&1).unwrap())
				.unwrap()
				.temperature
				.read()
		});
		*TURF_HEAT.write() = previous;
		assert_eq!(final_temperature, 500.0, "heat commit erased the setter");
		assert!(
			!finished_before_commit,
			"setter must serialize after the heat pass"
		);
	}

	#[test]
	fn heat_admission_retries_each_interval_once_with_its_original_settings() {
		let outstanding = AtomicUsize::new(0);
		let (sender, receiver) = flume::bounded(1);
		let pending = Mutex::new(None);
		let first = SSheatInfo {
			time_delta: 0.5,
			blackbody_enabled: true,
		};
		let second = SSheatInfo {
			time_delta: 0.25,
			blackbody_enabled: false,
		};
		let third = SSheatInfo {
			time_delta: 1.0,
			blackbody_enabled: true,
		};
		let receive = || match receiver.try_recv().unwrap() {
			HeatWorkerMessage::Process(info, _work) => info,
			HeatWorkerMessage::Shutdown => panic!("unexpected shutdown"),
		};
		assert!(!submit_heat_interval(&sender, &pending, &outstanding, || Ok(first)).unwrap());
		assert!(submit_heat_interval(&sender, &pending, &outstanding, || {
			assert!(
				pending.try_lock().is_some(),
				"capture must not hold the pending lock"
			);
			Ok(second)
		})
		.unwrap());
		for _ in 0..3 {
			assert!(submit_heat_interval(&sender, &pending, &outstanding, || {
				panic!("a pending interval must not read newer settings")
			})
			.unwrap());
		}
		assert_eq!(receive(), first);
		assert!(!submit_heat_interval(&sender, &pending, &outstanding, || {
			panic!("admission must keep the pending interval's settings")
		})
		.unwrap());
		assert_eq!(receive(), second);
		assert!(pending.lock().is_none());
		assert!(!submit_heat_interval(&sender, &pending, &outstanding, || Ok(third)).unwrap());
		assert_eq!(receive(), third);
		assert!(matches!(
			receiver.try_recv(),
			Err(flume::TryRecvError::Empty)
		));
	}

	#[test]
	fn heat_completion_covers_queued_dequeued_and_discarded_work() {
		let outstanding = AtomicUsize::new(0);
		let (sender, receiver) = flume::bounded(1);
		let pending = Mutex::new(None);
		let info = SSheatInfo {
			time_delta: 0.5,
			blackbody_enabled: true,
		};
		assert!(!submit_heat_interval(&sender, &pending, &outstanding, || Ok(info)).unwrap());
		assert_eq!(
			outstanding.load(Ordering::Acquire),
			1,
			"queued work must be busy"
		);
		assert!(submit_heat_interval(&sender, &pending, &outstanding, || Ok(info)).unwrap());
		assert_eq!(
			outstanding.load(Ordering::Acquire),
			1,
			"rejected sends must release their token"
		);
		let work = receiver.try_recv().unwrap();
		assert_eq!(
			outstanding.load(Ordering::Acquire),
			1,
			"dequeue cannot declare completion before TASKS is acquired"
		);
		assert!(
			!submit_heat_interval(&sender, &pending, &outstanding, || panic!(
				"retry must reuse pending work"
			))
			.unwrap()
		);
		assert_eq!(outstanding.load(Ordering::Acquire), 2);
		let (callbacks, callback_receiver) = flume::unbounded();
		std::thread::scope(|scope| {
			scope.spawn(move || {
				callbacks.send(()).unwrap();
				drop(work);
			});
		});
		assert_eq!(outstanding.load(Ordering::Acquire), 1);
		callback_receiver
			.try_recv()
			.expect("completion must follow callback publication");
		receiver.try_iter().for_each(std::mem::drop);
		assert_eq!(
			outstanding.load(Ordering::Acquire),
			0,
			"discarding queued work releases its ownership"
		);
		assert!(pending.lock().is_none());
	}

	#[test]
	fn heat_admission_reports_disconnection_without_forgetting_the_interval() {
		let outstanding = AtomicUsize::new(0);
		let (sender, receiver) = flume::bounded(1);
		drop(receiver);
		let pending = Mutex::new(None);
		let info = SSheatInfo {
			time_delta: 0.5,
			blackbody_enabled: true,
		};
		let error = submit_heat_interval(&sender, &pending, &outstanding, || Ok(info)).unwrap_err();
		assert!(error.to_string().contains("disconnected"));
		assert_eq!(*pending.lock(), Some(info));
		assert_eq!(outstanding.load(Ordering::Acquire), 0);
	}

	#[test]
	fn heat_edge_accumulation_visits_each_undirected_edge_once() {
		let edges = vec![
			(HeatNodeIndex::new(0), HeatNodeIndex::new(1)),
			(HeatNodeIndex::new(1), HeatNodeIndex::new(0)),
			(HeatNodeIndex::new(1), HeatNodeIndex::new(2)),
			(HeatNodeIndex::new(2), HeatNodeIndex::new(1)),
		];

		let unique_edges = unique_heat_edges(edges);
		assert_eq!(
			unique_edges,
			vec![
				(HeatNodeIndex::new(0), HeatNodeIndex::new(1)),
				(HeatNodeIndex::new(1), HeatNodeIndex::new(2)),
			]
		);
	}

	#[test]
	fn heat_metrics_count_work_without_combining_dimensions() {
		let telemetry = dogmos_perf::Telemetry::new();
		record_heat_metrics(&telemetry, 256, 32, 48, 44);
		let snapshot = telemetry.snapshot(0);
		assert_eq!(snapshot.metric(RuntimeMetric::HeatNodesScanned), 256);
		assert_eq!(snapshot.metric(RuntimeMetric::HeatNodesChanged), 32);
		assert_eq!(snapshot.metric(RuntimeMetric::HeatEdgesAttempted), 48);
		assert_eq!(snapshot.metric(RuntimeMetric::HeatEdgesApplied), 44);
	}

	#[test]
	fn heat_edge_accumulation_conserves_finite_temperature_energy() {
		let edges = vec![(HeatNodeIndex::new(0), HeatNodeIndex::new(1))];
		let temperatures = vec![1000.0, 300.0];
		let conductivities = vec![0.05, 0.05];
		let heat_capacities = vec![100.0, 200.0];

		let deltas =
			accumulate_heat_edge_deltas(&edges, &temperatures, &conductivities, &heat_capacities);

		assert_eq!(deltas.len(), 2);
		let energy_delta = deltas[0] * heat_capacities[0] + deltas[1] * heat_capacities[1];
		assert!(energy_delta.abs() < f32::EPSILON);
		assert!(deltas[0] < 0.0);
		assert!(deltas[1] > 0.0);
	}

	#[test]
	fn heat_edge_accumulation_reuses_delta_buffer() {
		let edges = vec![(HeatNodeIndex::new(0), HeatNodeIndex::new(1))];
		let temperatures = vec![1000.0, 300.0];
		let conductivities = vec![0.05, 0.05];
		let heat_capacities = vec![100.0, 200.0];
		let mut deltas = Vec::new();

		accumulate_heat_edge_deltas_into(
			&edges,
			&temperatures,
			&conductivities,
			&heat_capacities,
			&mut deltas,
		);
		let first_result = deltas.clone();
		let first_capacity = deltas.capacity();

		accumulate_heat_edge_deltas_into(
			&edges,
			&temperatures,
			&conductivities,
			&heat_capacities,
			&mut deltas,
		);
		assert_eq!(deltas, first_result);
		assert_eq!(deltas.capacity(), first_capacity);
	}

	#[test]
	fn infinite_heat_capacity_does_not_overflow_edge_energy() {
		let finite_side_energy = get_share_energy(500.0, BYOND_INFINITY_THRESHOLD, 100.0);
		assert_eq!(finite_side_energy, 50_000.0);
		assert!(finite_side_energy.is_finite());
		assert_eq!(
			get_share_energy(500.0, BYOND_INFINITY_THRESHOLD, BYOND_INFINITY_THRESHOLD),
			0.0,
		);
	}

	#[test]
	fn finite_large_heat_capacity_does_not_overflow_edge_energy() {
		let energy = get_share_energy(500.0, 1e20, 1e20);
		assert!(energy.is_finite());
		assert!((energy - 2.5e22).abs() / 2.5e22 < 1e-6);
	}

	#[test]
	fn blackbody_cooling_stays_above_cosmic_background() {
		let temperature = blackbody_temperature_after_cooling(274.0, 1.0, 1e10, 0.0);
		assert_eq!(temperature, TCMB);
	}

	#[test]
	fn heat_registration_total_survives_pending_batch_reset() {
		let pending = AtomicUsize::new(0);
		let total = AtomicUsize::new(0);

		record_registration_change(&pending, &total);
		record_registration_change(&pending, &total);
		assert_eq!(pending.load(Ordering::Relaxed), 2);
		assert_eq!(total.load(Ordering::Relaxed), 2);

		pending.swap(0, Ordering::Relaxed);
		record_registration_change(&pending, &total);
		assert_eq!(pending.load(Ordering::Relaxed), 1);
		assert_eq!(total.load(Ordering::Relaxed), 3);
	}

	#[test]
	fn heat_worker_can_rearm_after_shutdown() {
		let worker_running = AtomicBool::new(false);
		assert!(try_start_heat_worker(&worker_running));
		assert!(!try_start_heat_worker(&worker_running));
		worker_running.store(false, Ordering::Release);
		assert!(try_start_heat_worker(&worker_running));
	}

	#[test]
	fn heat_worker_and_arena_are_released_before_rearm() {
		let _guard = HEAT_LIFECYCLE_TEST_LOCK.lock().unwrap();
		let old_interval = SSheatInfo {
			time_delta: 0.5,
			blackbody_enabled: true,
		};
		*PENDING_HEAT.lock() = Some(old_interval);
		shutdown_turf_heat().unwrap();
		assert!(PENDING_HEAT.lock().is_none());
		assert!(!heat_work_pending());
		assert!(!HEAT_WORKER_RUNNING.load(Ordering::Acquire));
		assert!(HEAT_WORKER.lock().is_none());
		assert!(TURF_HEAT.read().is_none());

		*PENDING_HEAT.lock() = Some(old_interval);
		prepare_turf_heat_for_world().unwrap();
		assert!(PENDING_HEAT.lock().is_none());
		assert!(!heat_work_pending());
		assert!(HEAT_WORKER_RUNNING.load(Ordering::Acquire));
		assert!(HEAT_WORKER.lock().is_some());
		assert!(TURF_HEAT.read().is_some());

		shutdown_turf_heat().unwrap();
		prepare_turf_heat_for_world().unwrap();
	}

	#[test]
	fn heat_reregistration_refreshes_turf_generation() {
		let mut arena = TurfHeat {
			graph: StableDiGraph::<ThermalInfo, (), usize>::with_capacity(0, 0),
			map: IndexMap::default(),
		};
		let initial_info = ThermalInfo {
			id: 1,
			generation: 1,
			thermal_conductivity: 1.0,
			heat_capacity: 1.0,
			adjacent_to_space: false,
			temperature: RwLock::new(300.0),
		};
		assert!(arena.insert_turf(initial_info));

		let replacement_info = ThermalInfo {
			id: 1,
			generation: 2,
			thermal_conductivity: 2.0,
			heat_capacity: 2.0,
			adjacent_to_space: true,
			temperature: RwLock::new(400.0),
		};
		assert!(!arena.insert_turf(replacement_info));

		let node_id = *arena.get_id(&1).unwrap();
		let stored_info = arena.get(node_id).unwrap();
		assert_eq!(stored_info.generation, 2);
		assert_eq!(stored_info.thermal_conductivity, 2.0);
		assert_eq!(stored_info.heat_capacity, 2.0);
		assert!(stored_info.adjacent_to_space);
	}

	#[test]
	fn heat_runtime_metrics_report_source_layout_and_reserved_capacity() {
		let arena = new_turf_heat();
		let metrics = arena.runtime_metrics();
		assert_eq!(metrics.thermal_info_bytes, 28);
		assert_eq!(metrics.node_capacity, 0);
		assert_eq!(metrics.edge_capacity, 0);
		assert_eq!(metrics.map_capacity, 0);
	}
}

/// Returns the number of registered turfs in the heat graph.
#[auxmacros::bind("/proc/dogmos_heat_graph_count")]
fn dogmos_heat_graph_count() -> Result<ByondValue> {
	Ok((with_turf_heat_read(|arena| arena.map.len()) as f32).into())
}

/// Returns the cumulative number of heat-graph insertions and removals since the DLL initialized.
/// This is intentionally monotonic: the per-cycle registration counter is delivered through the
/// asynchronous callback queue and can be zero when a perf sample races that callback, while this
/// direct atomic read cannot lose a completed registration event to queue timing.
#[auxmacros::bind("/proc/dogmos_heat_registration_total")]
fn dogmos_heat_registration_total() -> Result<ByondValue> {
	Ok((HEAT_REGISTRATION_TOTAL.load(Ordering::Relaxed) as f32).into())
}

struct HeatWorkerGuard;

impl Drop for HeatWorkerGuard {
	fn drop(&mut self) {
		HEAT_WORKER_RUNNING.store(false, Ordering::Release);
	}
}

// Starts one owned worker thread per live BYOND world.
fn start_heat_worker() -> Result<()> {
	if HEAT_SHUTDOWN.load(Ordering::Acquire) {
		return Ok(());
	}
	let mut worker_owner = HEAT_WORKER.lock();
	if worker_owner
		.as_ref()
		.is_some_and(|worker| !worker.is_finished())
	{
		return Ok(());
	}
	if let Some(worker) = worker_owner.take() {
		worker
			.join()
			.map_err(|_| eyre::eyre!("Previous heat worker panicked"))?;
	}
	if !try_start_heat_worker(&HEAT_WORKER_RUNNING) {
		return Ok(());
	}
	let worker = match std::thread::Builder::new()
		.name("dogmos-heat".into())
		.spawn(|| {
			let _worker_guard = HeatWorkerGuard;
			let mut scratch = HeatProcessingScratch::default();
			while let Ok(HeatWorkerMessage::Process(info, work)) =
				with_heat_processing_callback_receiver(|receiver| receiver.recv())
			{
				if HEAT_SHUTDOWN.load(Ordering::Acquire) {
					break;
				}
				let task_lock = TASKS.read();
				let start_time = Instant::now();
				let emissivity_constant: f64 = STEFAN_BOLTZMANN_CONSTANT * info.time_delta;
				let radiation_from_space_tick: f64 = RADIATION_FROM_SPACE * info.time_delta;
				let elapsed_heat_scale = info.time_delta as f32 / BASE_HEAT_STEP_SECONDS;
				// Extracted before the closures below, which shadow the name `info` with each turf's own
				// ThermalInfo - this is SSheatInfo's toggle, not a per-turf value.
				let blackbody_enabled = info.blackbody_enabled;
				let mut heat_graph_nodes = 0;
				let mut heat_nodes_changed = 0;
				let mut heat_edge_attempts = 0;
				let mut heat_edges_applied = 0_u64;
				let mut heat_lock_contention = 0;
				let mut heat_processing_error = None;
				with_turf_heat_read(|arena| {
					heat_graph_nodes = arena.map.len();
					with_turf_gases_read(|air_arena| {
						// Keep one read view of the global mixture slice for both snapshot filtering and gas exchange.
						// Per-mixture locks still protect concurrent gas mutation; only the slice lookup lock is shared.
						GasArena::with_all_mixtures(|all_mixtures| {
							let gas_exchange_error = std::sync::OnceLock::new();
							let adjacencies_to_consider = arena
								.map
								.par_iter()
								.filter_map(|(&turf_id, &heat_index)| {
									/*
										If it has no thermal conductivity, low thermal capacity or has no adjacencies,
										then it's not gonna interact, or at least shouldn't.
									*/
									let info = arena.get(heat_index).unwrap();
									let temp = { *info.temperature.read() };
									//can share w/ adjacents?
									if arena.adjacent_heats(heat_index).any(|item| {
										(temp - *item.temperature.read()).abs()
											> MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER
									}) {
										return Some((turf_id, heat_index, true));
									}
									if temp > MINIMUM_TEMPERATURE_FOR_SUPERCONDUCTION {
										//can share w/ space/air?
										if info.adjacent_to_space
											|| air_arena
												.get_id(turf_id)
												.and_then(|nodeid| {
													air_arena.get(nodeid)?.enabled().then_some(())
												})
												.is_some()
										{
											Some((turf_id, heat_index, false))
										} else {
											None
										}
									} else if let Some(node) = air_arena.get_id(turf_id) {
										let cur_mix = air_arena.get(node).unwrap();
										if !cur_mix.enabled() {
											return None;
										}
										let air_temp = all_mixtures.get(cur_mix.mix)?.try_read();
										air_temp.as_ref()?;
										let air_temp = air_temp.unwrap().get_temperature();

										if air_temp < MINIMUM_TEMPERATURE_FOR_SUPERCONDUCTION {
											return None;
										}
										if (temp - air_temp).abs()
											> MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER
										{
											Some((turf_id, heat_index, false))
										} else {
											None
										}
									} else {
										None
									}
								})
								.filter_map(|(id, node_index, has_adjacents)| {
									let info = arena.get(node_index).unwrap();
									let Some(mut temp_write) = info.temperature.try_write() else {
										return has_adjacents.then_some(node_index);
									};

									if info.adjacent_to_space && *temp_write > T0C {
										if blackbody_enabled {
											*temp_write = blackbody_temperature_after_cooling(
												*temp_write,
												info.heat_capacity,
												emissivity_constant,
												radiation_from_space_tick,
											);
										} else if *temp_write > T20C {
											let delta = *temp_write - TCMB;
											let energy = get_share_energy(
												info.thermal_conductivity
													* elapsed_heat_scale * delta,
												HEAT_CAPACITY_VACUUM,
												info.heat_capacity,
											);
											*temp_write -= energy / info.heat_capacity;
										}
									}

									//share w/ air
									if let Some(air_node) = air_arena.get_id(id) {
										let tmix = air_arena.get(air_node).unwrap();
										if tmix.enabled() {
											if let Some(entry) = all_mixtures.get(tmix.mix) {
												if let Some(mut gas) = entry.try_write() {
													let exchange = gas.temperature_share_non_gas(
														/*
															This value should be lower than the
															turf-to-turf conductivity for balance reasons
															as well as realism, otherwise fires will
															just sort of solve theirselves over time.
														*/
														info.thermal_conductivity
															* OPEN_HEAT_TRANSFER_COEFFICIENT,
														*temp_write,
														info.heat_capacity,
													);
													match exchange {
														Ok(temperature) => {
															*temp_write = temperature
														}
														Err(error) => {
															gas_exchange_error.get_or_init(|| {
																format!("gas/turf heat exchange at turf {id}: {error}")
															});
														}
													}
												}
											}
										}
									}

									if !temp_write.is_normal() {
										*temp_write = TCMB;
									}

									if *temp_write > MINIMUM_TEMPERATURE_START_SUPERCONDUCTION
										&& *temp_write > info.heat_capacity
									{
										// not what heat capacity means but whatever
										let generation = info.generation;
										let _ = auxcallback::queue_callback(
											Box::new(move || {
												if !crate::turfs::turf_callback_is_current(
													id, generation,
												) {
													return Ok(());
												}
												let mut turf =
													ByondValue::new_ref(ValueType::Turf, id);
												turf.write_var_id(
													byond_string!("to_be_destroyed"),
													&1.0_f32.into(),
												)?;
												Ok(())
											}),
											0,
										);
									}
									has_adjacents.then_some(node_index)
								})
								.collect::<Vec<_>>();
							if let Some(error) = gas_exchange_error.into_inner() {
								heat_processing_error = Some(error);
							}

							// Read every undirected edge from a stable snapshot. The core applies deterministic,
							// conservative substeps using SSair's elapsed time before each node is written once.
							unique_heat_edges_into(
								adjacencies_to_consider.iter().flat_map(|&cur_index| {
									arena
										.adjacent_node_ids(cur_index)
										.map(move |other_index| (cur_index, other_index))
								}),
								&mut scratch.seen_edges,
								&mut scratch.unique_edges,
							);
							heat_edge_attempts = scratch.unique_edges.len();
							scratch.touched_nodes.clear();
							scratch.touched_nodes.extend(
								scratch
									.unique_edges
									.iter()
									.flat_map(|&(first, second)| [first, second]),
							);
							scratch
								.touched_nodes
								.sort_unstable_by_key(|node_index| node_index.index());
							scratch.touched_nodes.dedup();

							let touched_node_count = scratch.touched_nodes.len();
							heat_nodes_changed = touched_node_count;
							scratch.temperatures.clear();
							scratch.temperatures.resize(touched_node_count, 0.0);
							scratch.conductivities.clear();
							scratch.conductivities.resize(touched_node_count, 0.0);
							scratch.heat_capacities.clear();
							scratch.heat_capacities.resize(touched_node_count, 0.0);
							for (dense_index, &node_index) in
								scratch.touched_nodes.iter().enumerate()
							{
								let info = arena.get(node_index).unwrap();
								scratch.temperatures[dense_index] = *info.temperature.read();
								scratch.conductivities[dense_index] = info.thermal_conductivity;
								scratch.heat_capacities[dense_index] = info.heat_capacity;
							}

							scratch.dense_edges.clear();
							for &(first, second) in &scratch.unique_edges {
								let first_dense = scratch
									.touched_nodes
									.binary_search_by_key(&first.index(), |node_index| {
										node_index.index()
									});
								let second_dense = scratch
									.touched_nodes
									.binary_search_by_key(&second.index(), |node_index| {
										node_index.index()
									});
								let (Ok(first_dense), Ok(second_dense)) =
									(first_dense, second_dense)
								else {
									heat_processing_error = Some(
									"heat edge endpoint was absent from the dense node snapshot"
										.to_owned(),
								);
									break;
								};
								scratch
									.dense_edges
									.push((first_dense as u32, second_dense as u32));
							}

							if heat_processing_error.is_none() {
								match conduction_step_cancellable_with_scratch(
									&mut scratch.temperatures,
									&scratch.conductivities,
									&scratch.heat_capacities,
									&mut scratch.dense_edges,
									info.time_delta as f32,
									&mut scratch.row_sums,
									|| false,
								) {
									Ok(stats) => heat_edges_applied = stats.edges_applied,
									Err(error) => heat_processing_error = Some(error.to_string()),
								}
							}
							if heat_processing_error.is_none() {
								for (dense_index, &node_index) in
									scratch.touched_nodes.iter().enumerate()
								{
									let info = arena.get(node_index).unwrap();
									let mut temp_write = match info.temperature.try_write() {
										Some(temperature) => temperature,
										None => {
											heat_lock_contention += 1;
											info.temperature.write()
										}
									};
									*temp_write = scratch.temperatures[dense_index];
									if !temp_write.is_normal() {
										*temp_write = TCMB;
									}
								}
							}
						});
					});
				});
				record_heat_metrics(
					&crate::DOGMOS_TELEMETRY,
					heat_graph_nodes,
					heat_nodes_changed,
					heat_edge_attempts,
					heat_edges_applied,
				);
				let bench = start_time.elapsed().as_millis();
				let registration_changes = HEAT_REGISTRATION_CHANGES.swap(0, Ordering::Relaxed);
				let owned_bytes = heat_processing_error.as_ref().map_or(0, String::capacity);
				let _ = auxcallback::queue_callback(
					Box::new(move || {
						let ssair_owner = crate::ffi::OwnedByondValue::adopt(
							ByondValue::new_global_ref().read_var_id(byond_string!("SSair"))?,
						);
						let mut ssair = *ssair_owner;
						let prev_cost = ssair
							.read_number_id(byond_string!("cost_superconductivity"))
							.map_err(|_| {
								eyre::eyre!(
									"Attempt to interpret non-number value as number {} {}:{}",
									std::file!(),
									std::line!(),
									std::column!()
								)
							})?;
						ssair.write_var_id(
							byond_string!("cost_superconductivity"),
							&(0.8 * prev_cost + 0.2 * (bench as f32)).into(),
						)?;
						ssair.write_var_id(
							byond_string!("dogmos_heat_graph_nodes"),
							&(heat_graph_nodes as f32).into(),
						)?;
						ssair.write_var_id(
							byond_string!("dogmos_heat_edge_attempts"),
							&(heat_edge_attempts as f32).into(),
						)?;
						ssair.write_var_id(
							byond_string!("dogmos_heat_edges_applied"),
							&(heat_edges_applied as f32).into(),
						)?;
						ssair.write_var_id(
							byond_string!("dogmos_heat_lock_contention"),
							&(heat_lock_contention as f32).into(),
						)?;
						ssair.write_var_id(
							byond_string!("dogmos_heat_registration_changes"),
							&(registration_changes as f32).into(),
						)?;
						if let Some(error) = heat_processing_error {
							return Err(eyre::eyre!(
								"Dogmos TurfHeat numerical step rejected: {error}"
							));
						}
						Ok(())
					}),
					owned_bytes,
				);
				drop(task_lock);
				drop(work);
			}
		}) {
		Ok(worker) => worker,
		Err(error) => {
			HEAT_WORKER_RUNNING.store(false, Ordering::Release);
			return Err(error.into());
		}
	};
	*worker_owner = Some(worker);
	Ok(())
}

#[auxmacros::init]
fn process_heat_start() {
	let _ = start_heat_worker();
}
