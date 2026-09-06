use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, ReactionMetadata, TurfHandle},
	world::{
		AdjacencyMutation, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		TurfAdjacencyMutation, TurfHeatAdjacencyMutation, TurfHeatMutation, TurfHeatState,
		TurfLifecycleMutation, WorldEvent, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};
use std::{error::Error, fmt::Write as _};

pub(super) const TURF_COUNTS: [usize; 3] = [1_000, 10_000, 100_000];
pub(super) const TOPOLOGIES: [Topology; 3] = [Topology::Corridor, Topology::Grid, Topology::Multiz];
pub(super) const STAGES: [WorldStage; 5] = [
	WorldStage::ProcessTurfs,
	WorldStage::TurfHeat,
	WorldStage::Equalize,
	WorldStage::ExcitedGroups,
	WorldStage::React,
];
const WORLD_BYTE_BUDGET: u64 = 8 * 1024 * 1024 * 1024;
pub(super) const STAGE_WORK_LIMIT: u32 = 4096;

#[derive(Clone, Copy)]
pub(super) enum Topology {
	Corridor,
	Grid,
	Multiz,
}

impl Topology {
	pub(super) fn name(self) -> &'static str {
		match self {
			Self::Corridor => "corridor",
			Self::Grid => "grid",
			Self::Multiz => "multiz",
		}
	}
}

pub(super) fn mixture(slot: usize) -> MixtureHandle {
	MixtureHandle {
		slot: slot as u32,
		generation: 1,
	}
}

pub(super) fn turf(slot: usize) -> TurfHandle {
	TurfHandle {
		slot: slot as u32,
		generation: 1,
	}
}

pub(super) fn build_world(
	turf_count: usize,
	topology: Topology,
) -> Result<DogmosWorld, Box<dyn Error>> {
	build_world_with_reactions(turf_count, topology, Vec::new())
}

pub(super) fn build_world_with_reactions(
	turf_count: usize,
	topology: Topology,
	reactions: Vec<ReactionMetadata>,
) -> Result<DogmosWorld, Box<dyn Error>> {
	let mut world = DogmosWorld::new_with_event_capacity(WORLD_BYTE_BUDGET, turf_count as u32);
	world.install_gases(vec![GasMetadata {
		id: GasId(0),
		key: "benchmark".into(),
		name: "Benchmark gas".into(),
		flags: 0,
		specific_heat: 20.0,
		fusion_power: 0.0,
		moles_visible: None,
		enthalpy: 0.0,
		fire_radiation_released: 0.0,
		fire_role: GasFireRole::None,
		fire_products: None,
	}])?;
	world.install_reactions(reactions)?;
	let mixtures = (0..turf_count)
		.map(|slot| LifecycleMutation {
			action: LifecycleAction::Register,
			handle: mixture(slot),
		})
		.collect::<Vec<_>>();
	world.apply_lifecycle(&mixtures)?;
	let states = (0..turf_count)
		.map(|slot| {
			let mut gases = [0.0; MAX_GAS_SLOTS];
			gases[0] = 5.0 + (slot % 17) as f32;
			MixtureStateMutation {
				handle: mixture(slot),
				expected_revision: 0,
				temperature: 273.15 + (slot % 80) as f32,
				volume: 2500.0,
				gases,
			}
		})
		.collect::<Vec<_>>();
	world.apply_mixture_state(&states)?;
	let turfs = (0..turf_count)
		.map(|slot| TurfLifecycleMutation::Register {
			handle: turf(slot),
			mixture: Some(mixture(slot)),
		})
		.collect::<Vec<_>>();
	world.apply_turf_lifecycle(&turfs)?;
	let heat = (0..turf_count)
		.map(|slot| TurfHeatMutation {
			handle: turf(slot),
			state: Some(TurfHeatState {
				temperature: 273.15 + (slot % 80) as f32,
				thermal_conductivity: 0.05,
				heat_capacity: 20_000.0,
				adjacent_to_space: slot % 97 == 0,
			}),
		})
		.collect::<Vec<_>>();
	world.apply_turf_heat(&heat)?;
	let edges = topology_edges(topology, turf_count);
	let mixture_edges = edges
		.iter()
		.map(|&(left, right)| AdjacencyMutation {
			left: mixture(left),
			right: mixture(right),
			conductivity: 0.75,
		})
		.collect::<Vec<_>>();
	world.apply_adjacency(&mixture_edges)?;
	let turf_edges = edges
		.iter()
		.map(|&(left, right)| TurfAdjacencyMutation {
			left: turf(left),
			right: turf(right),
			connected: true,
		})
		.collect::<Vec<_>>();
	world.apply_turf_adjacency(&turf_edges)?;
	let heat_edges = edges
		.into_iter()
		.map(|(left, right)| TurfHeatAdjacencyMutation {
			left: turf(left),
			right: turf(right),
			connected: true,
		})
		.collect::<Vec<_>>();
	world.apply_turf_heat_adjacency(&heat_edges)?;
	world.begin_frontier(1, turf_count as u32)?;
	let frontier = (0..turf_count).map(turf).collect::<Vec<_>>();
	world.append_frontier(1, 0, &frontier)?;
	world.commit_frontier(1)?;
	Ok(world)
}

fn topology_edges(topology: Topology, turf_count: usize) -> Vec<(usize, usize)> {
	let mut edges = Vec::new();
	match topology {
		Topology::Corridor => {
			for slot in 1..turf_count {
				edges.push((slot - 1, slot));
			}
		}
		Topology::Grid => {
			let width = (turf_count as f64).sqrt().ceil() as usize;
			for slot in 0..turf_count {
				if slot % width + 1 < width && slot + 1 < turf_count {
					edges.push((slot, slot + 1));
				}
				if slot + width < turf_count {
					edges.push((slot, slot + width));
				}
			}
		}
		Topology::Multiz => {
			let layer_size = turf_count.div_ceil(3);
			for slot in 0..turf_count {
				if slot % layer_size + 1 < layer_size && slot + 1 < turf_count {
					edges.push((slot, slot + 1));
				}
				if slot + layer_size < turf_count {
					edges.push((slot, slot + layer_size));
				}
			}
		}
	}
	edges
}

pub(super) fn transcript_hash(
	world: &mut DogmosWorld,
	stage: WorldStage,
	topology: Topology,
	turf_count: usize,
	baseline_work: Option<u64>,
	drain: bool,
) -> Result<u64, Box<dyn Error>> {
	let mut hash = 0xcbf2_9ce4_8422_2325_u64;
	hash_bytes(&mut hash, stage_name(stage).as_bytes());
	hash_bytes(&mut hash, topology.name().as_bytes());
	hash_bytes(&mut hash, &turf_count.to_le_bytes());
	if let Some(work) = baseline_work {
		hash_bytes(&mut hash, &work.to_le_bytes());
	}
	for slot in 0..turf_count {
		let snapshot = world.snapshot(mixture(slot))?;
		hash_bytes(&mut hash, &snapshot.revision.to_le_bytes());
		hash_bytes(&mut hash, &snapshot.temperature.to_bits().to_le_bytes());
		hash_bytes(&mut hash, &snapshot.volume.to_bits().to_le_bytes());
		for gas in snapshot.gases {
			hash_bytes(&mut hash, &gas.to_bits().to_le_bytes());
		}
		if let Some(state) = world.turf_heat(turf(slot))? {
			hash_bytes(&mut hash, &state.temperature.to_bits().to_le_bytes());
			hash_bytes(
				&mut hash,
				&state.thermal_conductivity.to_bits().to_le_bytes(),
			);
			hash_bytes(&mut hash, &state.heat_capacity.to_bits().to_le_bytes());
			hash_bytes(&mut hash, &[u8::from(state.adjacent_to_space)]);
		}
	}
	let mut events = Vec::new();
	if drain {
		world.drain_events_into(u32::MAX, &mut events);
	} else {
		events.extend_from_slice(world.pending_events(u32::MAX));
	}
	for event in events {
		hash_event(&mut hash, event)?;
	}
	Ok(hash)
}

fn hash_event(hash: &mut u64, event: WorldEvent) -> Result<(), std::fmt::Error> {
	let mut encoded = String::new();
	write!(&mut encoded, "{event:?}")?;
	hash_bytes(hash, encoded.as_bytes());
	Ok(())
}

fn hash_bytes(hash: &mut u64, bytes: &[u8]) {
	for byte in bytes {
		*hash ^= u64::from(*byte);
		*hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
	}
}

pub(super) fn stage_name(stage: WorldStage) -> &'static str {
	match stage {
		WorldStage::ProcessTurfs => "process_turfs",
		WorldStage::Equalize => "equalize",
		WorldStage::ExcitedGroups => "excited_groups",
		WorldStage::TurfHeat => "turf_heat",
		WorldStage::React => "react",
	}
}
