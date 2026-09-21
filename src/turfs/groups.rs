use super::*;
use coarsetime::{Duration, Instant};
use parking_lot::{const_mutex, Mutex};
use std::collections::{BTreeSet, HashSet, VecDeque};

static GROUPS_CHANNEL: Mutex<Option<BTreeSet<TurfID>>> = const_mutex(None);

pub fn flush_groups_channel() {
	*GROUPS_CHANNEL.lock() = None;
}

fn with_groups<T>(f: impl Fn(Option<BTreeSet<TurfID>>) -> T) -> T {
	f(GROUPS_CHANNEL.lock().take())
}

pub fn send_to_groups(sent: BTreeSet<TurfID>) {
	GROUPS_CHANNEL.try_lock().map(|mut opt| opt.replace(sent));
}
/// Returns: If this cycle is interrupted by overtiming or not. Starts a processing excited groups cycle, does nothing if process_turfs isn't ran.
#[auxmacros::bind("/datum/controller/subsystem/air/proc/process_excited_groups_auxtools")]
fn groups_hook(mut src: ByondValue, remaining: ByondValue) -> Result<ByondValue> {
	let group_pressure_goal = src
		.read_number_id(byond_string!("excited_group_pressure_goal"))
		.unwrap_or(0.5);
	let remaining_time = Duration::from_millis(remaining.get_number().unwrap_or(50.0) as u64);
	let start_time = Instant::now();
	let (num_eq, is_cancelled) = with_groups(|thing| {
		if let Some(high_pressure_turfs) = thing {
			excited_group_processing(
				group_pressure_goal,
				high_pressure_turfs,
				(&start_time, remaining_time),
			)
		} else {
			(0, false)
		}
	});

	let bench = start_time.elapsed().as_millis();
	let prev_cost = src
		.read_number_id(byond_string!("cost_groups"))
		.map_err(|_| eyre::eyre!("Attempt to interpret non-number value as number"))?;
	src.write_var_id(
		byond_string!("cost_groups"),
		&(0.8 * prev_cost + 0.2 * (bench as f32)).into(),
	)?;
	src.write_var_id(
		byond_string!("num_group_turfs_processed"),
		&(num_eq as f32).into(),
	)?;
	Ok(is_cancelled.into())
}

// Finds small differences in turf pressures and equalizes them.
#[cfg_attr(not(target_feature = "avx2"), auxmacros::generate_simd_functions)]
#[cfg_attr(feature = "tracy", tracing::instrument(skip_all))]
fn excited_group_processing(
	pressure_goal: f32,
	low_pressure_turfs: BTreeSet<TurfID>,
	(start_time, remaining_time): (&Instant, Duration),
) -> (usize, bool) {
	let mut found_turfs: HashSet<TurfID, FxBuildHasher> = Default::default();
	let mut is_cancelled = false;
	/*
		Both global locks are taken once for the whole pass rather than once per seed turf. The
		body calls no DM procs and never needs the arena's write lock, so there is nothing to
		re-enter, and the pass is bounded by the caller's time budget. `fdm` and `post_process`
		already hoist the same pair of locks this way.
	*/
	with_turf_gases_read(|arena| {
		GasArena::with_all_mixtures(|all_mixtures| {
			for initial_turf in low_pressure_turfs {
				if found_turfs.contains(&initial_turf) {
					continue;
				}

				if start_time.elapsed() >= remaining_time {
					is_cancelled = true;
					break;
				}

				let Some(initial_index) = arena.get_id(initial_turf) else {
					continue;
				};
				let Some(initial_mix_ref) = arena.get(initial_index) else {
					continue;
				};
				if !initial_mix_ref.enabled() {
					continue;
				}
				let Some(initial_lock) = all_mixtures.get(initial_mix_ref.mix) else {
					continue;
				};

				// Carry the node handle alongside the id so the walk below does not re-resolve
				// each turf through the id map on every pop and on every neighbor.
				let mut border_turfs: VecDeque<(TurfID, NodeIndex)> = VecDeque::with_capacity(40);
				let mut turfs: Vec<&TurfMixture> = Vec::with_capacity(200);
				let mut min_pressure = initial_lock.read().return_pressure();
				let mut max_pressure = min_pressure;
				let mut min_temperature = initial_lock.read().get_temperature();
				let mut max_temperature = min_temperature;
				let mut fully_mixed = Mixture::new();

				border_turfs.push_back((initial_turf, initial_index));
				found_turfs.insert(initial_turf);

				while let Some((_, index)) = border_turfs.pop_front() {
					if turfs.len() >= 2500 {
						break;
					}
					let Some(tmix) = arena.get(index) else {
						break;
					};
					if let Some(lock) = all_mixtures.get(tmix.mix) {
						let mix = lock.read();
						let temperature = mix.get_temperature();
						let this_min_temperature = min_temperature.min(temperature);
						let this_max_temperature = max_temperature.max(temperature);
						// Similar pressure does not imply thermal equilibrium. Leave fronts to
						// local diffusion/conduction rather than globally flattening them each cycle.
						if this_max_temperature - this_min_temperature
							> MINIMUM_TEMPERATURE_DELTA_TO_SUSPEND
						{
							continue;
						}
						let pressure = mix.return_pressure();
						let this_max = max_pressure.max(pressure);
						let this_min = min_pressure.min(pressure);
						if (this_max - this_min).abs() >= pressure_goal {
							continue;
						}
						min_temperature = this_min_temperature;
						max_temperature = this_max_temperature;
						min_pressure = this_min;
						max_pressure = this_max;
						turfs.push(tmix);
						fully_mixed.merge(&mix);
						fully_mixed.volume += mix.volume;
						for adjacent_index in arena.adjacent_node_ids(index) {
							let Some(adjacent) = arena.get(adjacent_index) else {
								continue;
							};
							// Marked found before the enabled check, as before: a disabled
							// neighbor still counts as visited and is simply not walked into.
							if !found_turfs.insert(adjacent.id) {
								continue;
							}
							if adjacent.enabled() {
								border_turfs.push_back((adjacent.id, adjacent_index));
							}
						}
					}
				}

				if turfs.is_empty() {
					continue;
				}
				fully_mixed.multiply(1.0 / turfs.len() as f32);
				if !fully_mixed.is_corrupt() {
					turfs
						.par_iter()
						.filter_map(|turf| all_mixtures.get(turf.mix))
						.for_each(|mix_lock| mix_lock.write().copy_from_mutable(&fully_mixed));
				}
			}
		});
	});
	(found_turfs.len(), is_cancelled)
}

#[cfg(all(test, feature = "katmos", feature = "superconductivity"))]
mod tests {
	use super::*;
	use crate::gas::{types::*, GAS_TEST_LOCK};

	#[test]
	fn equal_pressure_group_does_not_flatten_a_thermal_front() {
		let guard = GAS_TEST_LOCK.lock().unwrap();
		set_gas_statics_manually();
		register_gas_manually("o2", 20.0);
		let mut hot = Mixture::new();
		hot.set_moles(0, 10.0).unwrap();
		hot.set_temperature(1200.0);
		let mut cold = Mixture::new();
		cold.set_moles(0, 40.0).unwrap();
		cold.set_temperature(300.0);
		// Both cells have exactly the same pressure; only the thermal front differs.
		assert_eq!(hot.return_pressure(), cold.return_pressure());
		crate::gas::install_mixtures_for_test(vec![hot, cold]);
		initialize_turfs();
		with_turf_gases_write(|arena| {
			for (mix, id) in [(0, 10), (1, 11)] {
				arena.insert_turf(TurfMixture {
					mix,
					id,
					generation: 1,
					flags: SimulationFlags::SIMULATION_ALL,
					..Default::default()
				});
			}
			let left = arena.get_id(10).unwrap();
			let right = arena.get_id(11).unwrap();
			arena.graph.add_edge(left, right, AdjacentFlags::empty());
			arena.graph.add_edge(right, left, AdjacentFlags::empty());
		});
		excited_group_processing(
			0.5,
			BTreeSet::from([10, 11]),
			(&Instant::now(), Duration::from_secs(10)),
		);
		let temperatures = GasArena::with_all_mixtures(|mixes| {
			[
				mixes[0].read().get_temperature(),
				mixes[1].read().get_temperature(),
			]
		});
		// The optimization still mixes an isothermal, nearly settled component.
		GasArena::with_all_mixtures(|mixes| {
			for (index, moles) in [10.0, 10.1].into_iter().enumerate() {
				let mut mix = mixes[index].write();
				mix.set_moles(0, moles).unwrap();
				mix.set_temperature(300.0);
			}
		});
		excited_group_processing(
			0.5,
			BTreeSet::from([10, 11]),
			(&Instant::now(), Duration::from_secs(10)),
		);
		let settled_moles = GasArena::with_all_mixtures(|mixes| {
			[mixes[0].read().total_moles(), mixes[1].read().total_moles()]
		});
		shutdown_turfs();
		crate::gas::shut_down_gases();
		destroy_gas_statics();
		drop(guard);
		assert_eq!(temperatures, [1200.0, 300.0]);
		assert_eq!(settled_moles, [10.05, 10.05]);
	}
}
