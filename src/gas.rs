#[allow(dead_code)]
pub mod constants;
pub mod mixture;
pub mod types;

use byondapi::prelude::*;
use eyre::Result;
pub use mixture::Mixture;
use parking_lot::{const_rwlock, RwLock};
use std::sync::atomic::{AtomicUsize, Ordering};
pub use types::*;

pub type GasIDX = usize;

/// Accessors for the shared gas-mixture arena.
pub struct GasArena {}

// Gas mixtures live in a lock-protected pool so worker threads can process them concurrently.
static GAS_MIXTURES: RwLock<Option<Vec<RwLock<Mixture>>>> = const_rwlock(None);

static NEXT_GAS_IDS: RwLock<Option<Vec<usize>>> = const_rwlock(None);
static ACTIVE_MIXTURE_SLOTS: AtomicUsize = AtomicUsize::new(0);
static MIXTURE_SLOT_HIGH_WATER: AtomicUsize = AtomicUsize::new(0);

// Bound unused slot storage instead of doubling a large contiguous i686 allocation.
const MIXTURE_GROWTH_SLOTS: usize = 4096;
// BYOND numbers must represent every slot exactly.
const MAX_MIXTURE_SLOTS: usize = 1 << 24;

#[cfg(test)]
pub(crate) static GAS_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct GasRuntimeMetrics {
	pub arena_len: usize,
	pub arena_capacity: usize,
	pub active_slots: usize,
	pub slot_high_water: usize,
	pub mixture_bytes: usize,
	pub mixture_lock_bytes: usize,
	pub mole_length_zero: usize,
	pub mole_length_one_to_four: usize,
	pub mole_length_five_to_eight: usize,
	pub mole_length_nine: usize,
	pub mole_spills: usize,
}

fn gas_slot_from_number(raw_slot: f32, arena_len: usize) -> Result<usize> {
	if !raw_slot.is_finite() || raw_slot < 0.0 || raw_slot.fract() != 0.0 {
		return Err(eyre::eyre!(
			"Gas mixture has an invalid arena slot: {raw_slot}"
		));
	}
	let slot = raw_slot as usize;
	if slot >= arena_len {
		return Err(eyre::eyre!(
			"Gas mixture arena slot {slot} is outside the arena (length {arena_len})"
		));
	}
	Ok(slot)
}

fn ensure_distinct_mixture_slots(src: usize, arg: usize) -> Result<()> {
	if src == arg {
		return Err(eyre::eyre!(
			"Cannot operate on the same gas mixture as both arguments"
		));
	}
	Ok(())
}

pub(crate) fn gas_slot_for_mix(mix: &ByondValue) -> Result<usize> {
	let raw_slot = mix.read_number_id(byond_string!("_extools_pointer_gasmixture"))?;
	let arena_len = GAS_MIXTURES
		.read()
		.as_ref()
		.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?
		.len();
	gas_slot_from_number(raw_slot, arena_len)
}

#[auxmacros::init]
pub fn initialize_gases() {
	*GAS_MIXTURES.write() = Some(Vec::new());
	*NEXT_GAS_IDS.write() = Some(Vec::new());
	ACTIVE_MIXTURE_SLOTS.store(0, Ordering::Relaxed);
	MIXTURE_SLOT_HIGH_WATER.store(0, Ordering::Relaxed);
}

pub fn prepare_gases_for_world() {
	if GAS_MIXTURES.read().is_none() || NEXT_GAS_IDS.read().is_none() {
		initialize_gases();
	}
}

pub fn shut_down_gases() {
	#[cfg(feature = "turf_processing")]
	crate::turfs::wait_for_tasks();
	GAS_MIXTURES.write().take();
	NEXT_GAS_IDS.write().take();
	ACTIVE_MIXTURE_SLOTS.store(0, Ordering::Relaxed);
	MIXTURE_SLOT_HIGH_WATER.store(0, Ordering::Relaxed);
}

#[cfg(all(test, feature = "katmos"))]
pub(crate) fn install_mixtures_for_test(mixtures: Vec<Mixture>) {
	let active = mixtures.len();
	*GAS_MIXTURES.write() = Some(mixtures.into_iter().map(RwLock::new).collect());
	*NEXT_GAS_IDS.write() = Some(Vec::new());
	ACTIVE_MIXTURE_SLOTS.store(active, Ordering::Relaxed);
	MIXTURE_SLOT_HIGH_WATER.store(active, Ordering::Relaxed);
}

impl GasArena {
	/// Read-only settlement classification: source immutability, then 0 for equal,
	/// 1 for a differing immutable neighbor, or 2 for a differing mutable neighbor.
	pub(crate) fn settlement_batch(src: usize, neighbors: &[usize]) -> Result<Vec<u8>> {
		if neighbors.len() > 6 {
			return Err(eyre::eyre!(
				"Settlement accepts at most six cardinal neighbors"
			));
		}
		let arena = GAS_MIXTURES.read();
		let mixtures = arena
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		// Hold each distinct slot once, in the same order as numerical writers.
		// The cardinal bound keeps lock bookkeeping on the stack, even for spilled mixtures.
		let mut slots = [src; 7];
		let slots = &mut slots[..neighbors.len() + 1];
		slots[1..].copy_from_slice(neighbors);
		slots.sort_unstable();
		let mut guards: [Option<parking_lot::RwLockReadGuard<'_, Mixture>>; 7] =
			[const { None }; 7];
		for (index, &slot) in slots.iter().enumerate() {
			if index == 0 || slot != slots[index - 1] {
				guards[index] = Some(
					mixtures
						.get(slot)
						.ok_or_else(|| eyre::eyre!("No gas mixture with ID {slot} exists!"))?
						.read(),
				);
			}
		}
		let mixture_at = |slot| {
			guards[slots.partition_point(|&locked_slot| locked_slot < slot)]
				.as_deref()
				.unwrap()
		};
		let source = mixture_at(src);
		let mut result = Vec::with_capacity(neighbors.len() + 1);
		result.push(u8::from(source.is_immutable()));
		for &slot in neighbors {
			if slot == src {
				result.push(0);
				continue;
			}
			let neighbor = mixture_at(slot);
			let differs = source.temperature_compare(neighbor)
				|| source.compare_with(neighbor, constants::MINIMUM_MOLES_DELTA_TO_MOVE);
			result.push(if !differs {
				0
			} else if neighbor.is_immutable() {
				1
			} else {
				2
			});
		}
		Ok(result)
	}

	/// Locks the gas arena and and runs the given closure with it locked.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	pub fn with_all_mixtures<T, F>(f: F) -> T
	where
		F: FnOnce(&[RwLock<Mixture>]) -> T,
	{
		f(GAS_MIXTURES.read().as_ref().unwrap())
	}

	/// Read locks the given gas mixture and runs the given closure on it.
	/// # Errors
	/// If no such gas mixture exists or the closure itself errors.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	pub fn with_gas_mixture<T, F>(id: usize, f: F) -> Result<T>
	where
		F: FnOnce(&Mixture) -> Result<T>,
	{
		let lock = GAS_MIXTURES.read();
		let gas_mixtures = lock
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		let mix = gas_mixtures
			.get(id)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {id} exists!"))?
			.read();
		f(&mix)
	}
	/// Write locks the given gas mixture and runs the given closure on it.
	/// # Errors
	/// If no such gas mixture exists or the closure itself errors.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	pub fn with_gas_mixture_mut<T, F>(id: usize, f: F) -> Result<T>
	where
		F: FnOnce(&mut Mixture) -> Result<T>,
	{
		let lock = GAS_MIXTURES.read();
		let gas_mixtures = lock
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		let mut mix = gas_mixtures
			.get(id)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {id} exists!"))?
			.write();
		f(&mut mix)
	}
	/// Read locks the given gas mixtures and runs the given closure on them.
	/// # Errors
	/// If no such gas mixture exists or the closure itself errors.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	pub fn with_gas_mixtures<T, F>(src: usize, arg: usize, f: F) -> Result<T>
	where
		F: FnOnce(&Mixture, &Mixture) -> Result<T>,
	{
		let lock = GAS_MIXTURES.read();
		let gas_mixtures = lock
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		let src_lock = gas_mixtures
			.get(src)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {src} exists!"))?;
		let arg_lock = gas_mixtures
			.get(arg)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {arg} exists!"))?;
		if src == arg {
			// A second read can block behind a writer waiting for our first read.
			let mix = src_lock.read();
			f(&mix, &mix)
		} else if src < arg {
			let src_mix = src_lock.read();
			let arg_mix = arg_lock.read();
			f(&src_mix, &arg_mix)
		} else {
			let arg_mix = arg_lock.read();
			let src_mix = src_lock.read();
			f(&src_mix, &arg_mix)
		}
	}
	/// Locks the given gas mixtures and runs the given closure on them.
	/// # Errors
	/// If no such gas mixture exists or the closure itself errors.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	pub fn with_gas_mixtures_mut<T, F>(src: usize, arg: usize, f: F) -> Result<T>
	where
		F: FnOnce(&mut Mixture, &mut Mixture) -> Result<T>,
	{
		let lock = GAS_MIXTURES.read();
		let gas_mixtures = lock
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		Self::with_gas_mixtures_mut_in(gas_mixtures, src, arg, f)
	}
	/// As `with_gas_mixtures_mut`, but against an arena slice the caller already holds.
	///
	/// Callers that have hoisted `with_all_mixtures` out of a loop must use this rather than
	/// re-entering `GAS_MIXTURES.read()`: a second read acquisition while a writer is queued
	/// would block behind that writer and deadlock. The per-mixture lock ordering is identical.
	/// # Errors
	/// If either slot is absent, the slots alias, or the closure itself errors.
	pub fn with_gas_mixtures_mut_in<T, F>(
		all_mixtures: &[RwLock<Mixture>],
		src: usize,
		arg: usize,
		f: F,
	) -> Result<T>
	where
		F: FnOnce(&mut Mixture, &mut Mixture) -> Result<T>,
	{
		let src_lock = all_mixtures
			.get(src)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {src} exists!"))?;
		let arg_lock = all_mixtures
			.get(arg)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {arg} exists!"))?;
		ensure_distinct_mixture_slots(src, arg)?;
		if src < arg {
			let mut src_mix = src_lock.write();
			let mut arg_mix = arg_lock.write();
			f(&mut src_mix, &mut arg_mix)
		} else {
			let mut arg_mix = arg_lock.write();
			let mut src_mix = src_lock.write();
			f(&mut src_mix, &mut arg_mix)
		}
	}
	/// Write locks `src` and read locks `arg` in slot order, preserving argument order.
	/// # Errors
	/// If no such gas mixture exists or the closure itself errors.
	/// # Panics
	/// if `GAS_MIXTURES` hasn't been initialized, somehow.
	fn with_gas_mixtures_mut_and_read<T, F>(src: usize, arg: usize, f: F) -> Result<T>
	where
		F: FnOnce(&mut Mixture, &Mixture) -> Result<T>,
	{
		let lock = GAS_MIXTURES.read();
		let gas_mixtures = lock
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		let src_lock = gas_mixtures
			.get(src)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {src} exists!"))?;
		let arg_lock = gas_mixtures
			.get(arg)
			.ok_or_else(|| eyre::eyre!("No gas mixture with ID {arg} exists!"))?;
		ensure_distinct_mixture_slots(src, arg)?;
		if src < arg {
			let mut src_mix = src_lock.write();
			let arg_mix = arg_lock.read();
			f(&mut src_mix, &arg_mix)
		} else {
			let arg_mix = arg_lock.read();
			let mut src_mix = src_lock.write();
			f(&mut src_mix, &arg_mix)
		}
	}
	/// Fills in the first unused slot in the gas mixtures vector, or adds another one, then sets the argument ByondValue to point to it.
	/// # Errors
	/// If `initial_volume` is incorrect, either gas arena is not initialized, or
	/// `_extools_pointer_gasmixture` doesn't exist.
	pub fn register_mix(mut mix: ByondValue) -> Result<ByondValue> {
		let init_volume = mix.read_number_id(byond_string!("initial_volume"))?;
		if !init_volume.is_finite() || init_volume < 0.0 {
			return Err(eyre::eyre!(
				"Gas mixture volume must be finite and non-negative, got {init_volume}"
			));
		}
		let arena_len = GAS_MIXTURES
			.read()
			.as_ref()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?
			.len();
		let reusable_idx = {
			let mut next_gas_ids = NEXT_GAS_IDS.write();
			let next_gas_ids = next_gas_ids
				.as_mut()
				.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
			let reusable_position = (0..next_gas_ids.len()).rev().find(|position| {
				if next_gas_ids[*position] >= arena_len {
					return false;
				}
				#[cfg(feature = "turf_processing")]
				let referenced = crate::turfs::gas_mix_is_referenced(next_gas_ids[*position]);
				#[cfg(not(feature = "turf_processing"))]
				let referenced = {
					let _ = position;
					false
				};
				!referenced
			});
			reusable_position.map(|position| next_gas_ids.swap_remove(position))
		};

		if let Some(idx) = reusable_idx {
			GAS_MIXTURES
				.read()
				.as_ref()
				.unwrap()
				.get(idx)
				.ok_or_else(|| {
					eyre::eyre!("Reusable gas mixture ID {idx} is outside the gas arena")
				})?
				.write()
				.clear_with_vol(init_volume);
			if let Err(error) = mix.write_var_id(
				byond_string!("_extools_pointer_gasmixture"),
				&(idx as f32).into(),
			) {
				// Removal left room in the free list; restoring it cannot allocate.
				NEXT_GAS_IDS.write().as_mut().unwrap().push(idx);
				return Err(error.into());
			}
		} else {
			let mut gas_lock = GAS_MIXTURES.write();
			let gas_mixtures = gas_lock.as_mut().unwrap();
			let next_idx = gas_mixtures.len();
			if next_idx >= MAX_MIXTURE_SLOTS {
				return Err(eyre::eyre!(
					"Gas arena exhausted exact BYOND slot identities"
				));
			}
			if next_idx == gas_mixtures.capacity() {
				gas_mixtures
					.try_reserve_exact(MIXTURE_GROWTH_SLOTS)
					.map_err(|error| {
						eyre::eyre!("Unable to grow the gas mixture arena: {error}")
					})?;
			}
			gas_mixtures.push(RwLock::new(Mixture::from_vol(init_volume)));

			if let Err(error) = mix.write_var_id(
				byond_string!("_extools_pointer_gasmixture"),
				&(next_idx as f32).into(),
			) {
				gas_mixtures.pop();
				return Err(error.into());
			}

			// Spare capacity stays uninitialized; only retired live slots enter the free list.
		}
		let active_slots = ACTIVE_MIXTURE_SLOTS.fetch_add(1, Ordering::Relaxed) + 1;
		MIXTURE_SLOT_HIGH_WATER.fetch_max(active_slots, Ordering::Relaxed);
		Ok(ByondValue::null())
	}
	/// Marks the ByondValue's gas mixture as unused, allowing it to be reallocated to another.
	///
	/// # Errors
	/// If the mix has no valid arena slot or the arena has not been initialized.
	pub fn unregister_mix(mix: &ByondValue) -> Result<()> {
		let idx = gas_slot_for_mix(mix)?;

		let mut next_gas_ids = NEXT_GAS_IDS.write();
		let next_gas_ids = next_gas_ids
			.as_mut()
			.ok_or_else(|| eyre::eyre!("Gas arena is not initialized"))?;
		if !next_gas_ids.contains(&idx) {
			next_gas_ids
				.try_reserve(1)
				.map_err(|error| eyre::eyre!("Unable to retire gas mixture slot {idx}: {error}"))?;
			next_gas_ids.push(idx);
			ACTIVE_MIXTURE_SLOTS.fetch_sub(1, Ordering::Relaxed);
		}
		Ok(())
	}
}

/// Gets the mix for the given value, and calls the provided closure with a reference to that mix as an argument.
/// # Errors
/// If a gasmixture ID is not a number or the callback returns an error.
pub fn with_mix<T, F>(mix: &ByondValue, f: F) -> Result<T>
where
	F: FnOnce(&Mixture) -> Result<T>,
{
	GasArena::with_gas_mixture(gas_slot_for_mix(mix)?, f)
}

/// As `with_mix`, but mutable.
/// # Errors
/// If a gasmixture ID is not a number or the callback returns an error.
pub fn with_mix_mut<T, F>(mix: &ByondValue, f: F) -> Result<T>
where
	F: FnOnce(&mut Mixture) -> Result<T>,
{
	GasArena::with_gas_mixture_mut(gas_slot_for_mix(mix)?, f)
}

/// As `with_mix`, but with two mixes.
/// # Errors
/// If a gasmixture ID is not a number or the callback returns an error.
pub fn with_mixes<T, F>(src_mix: &ByondValue, arg_mix: &ByondValue, f: F) -> Result<T>
where
	F: FnOnce(&Mixture, &Mixture) -> Result<T>,
{
	GasArena::with_gas_mixtures(gas_slot_for_mix(src_mix)?, gas_slot_for_mix(arg_mix)?, f)
}

/// As `with_mix_mut`, but with two mixes.
/// # Errors
/// If a gasmixture ID is not a number or the callback returns an error.
pub fn with_mixes_mut<T, F>(src_mix: &ByondValue, arg_mix: &ByondValue, f: F) -> Result<T>
where
	F: FnOnce(&mut Mixture, &mut Mixture) -> Result<T>,
{
	GasArena::with_gas_mixtures_mut(gas_slot_for_mix(src_mix)?, gas_slot_for_mix(arg_mix)?, f)
}

/// Runs a closure with a mutable source and read-only argument, locked in slot order.
/// # Errors
/// If a gasmixture ID is not a number or the callback returns an error.
pub fn with_mixes_mut_and_read<T, F>(src_mix: &ByondValue, arg_mix: &ByondValue, f: F) -> Result<T>
where
	F: FnOnce(&mut Mixture, &Mixture) -> Result<T>,
{
	GasArena::with_gas_mixtures_mut_and_read(
		gas_slot_for_mix(src_mix)?,
		gas_slot_for_mix(arg_mix)?,
		f,
	)
}

/// Gets the amount of gases that are active in byond.
/// # Panics
/// if `GAS_MIXTURES` hasn't been initialized, somehow.
pub fn amt_gases() -> usize {
	let gas_mixtures = GAS_MIXTURES.read();
	let next_gas_ids = NEXT_GAS_IDS.read();
	match (gas_mixtures.as_ref(), next_gas_ids.as_ref()) {
		(Some(gas_mixtures), Some(next_gas_ids)) => gas_mixtures.len() - next_gas_ids.len(),
		_ => 0,
	}
}

/// Gets the amount of gases that are allocated, but not necessarily active in byond.
/// # Panics
/// if `GAS_MIXTURES` hasn't been initialized, somehow.
pub fn tot_gases() -> usize {
	GAS_MIXTURES.read().as_ref().map_or(0, Vec::len)
}

pub(crate) fn gas_runtime_metrics() -> GasRuntimeMetrics {
	let gas_mixtures = GAS_MIXTURES.read();
	let Some(gas_mixtures) = gas_mixtures.as_ref() else {
		return GasRuntimeMetrics {
			mixture_bytes: std::mem::size_of::<Mixture>(),
			mixture_lock_bytes: std::mem::size_of::<RwLock<Mixture>>(),
			..Default::default()
		};
	};
	let mut metrics = GasRuntimeMetrics {
		arena_len: gas_mixtures.len(),
		arena_capacity: gas_mixtures.capacity(),
		active_slots: ACTIVE_MIXTURE_SLOTS.load(Ordering::Relaxed),
		slot_high_water: MIXTURE_SLOT_HIGH_WATER.load(Ordering::Relaxed),
		mixture_bytes: std::mem::size_of::<Mixture>(),
		mixture_lock_bytes: std::mem::size_of::<RwLock<Mixture>>(),
		..Default::default()
	};
	for mixture in gas_mixtures {
		let mixture = mixture.read();
		match mixture.mole_len() {
			0 => metrics.mole_length_zero += 1,
			1..=4 => metrics.mole_length_one_to_four += 1,
			5..=8 => metrics.mole_length_five_to_eight += 1,
			9 => metrics.mole_length_nine += 1,
			_ => (),
		}
		metrics.mole_spills += usize::from(mixture.moles_spilled());
	}
	metrics
}

#[cfg(test)]
mod tests {
	use super::{
		ensure_distinct_mixture_slots, gas_runtime_metrics, gas_slot_from_number, initialize_gases,
		prepare_gases_for_world, shut_down_gases, GasArena, GAS_MIXTURES, GAS_TEST_LOCK,
		NEXT_GAS_IDS,
	};

	#[test]
	fn mixture_access_preserves_worker_lock_order() {
		use std::{
			sync::mpsc,
			thread,
			time::{Duration, Instant},
		};
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		*GAS_MIXTURES.write() = Some(
			(0..3)
				.map(|_| parking_lot::RwLock::new(super::Mixture::new()))
				.collect(),
		);
		type Operation = fn() -> eyre::Result<()>;
		let operations: [(&str, Operation); 3] = [
			("compare", || {
				GasArena::with_gas_mixtures(2, 0, |_, _| Ok(()))
			}),
			("merge/copy", || {
				GasArena::with_gas_mixtures_mut_and_read(2, 0, |_, _| Ok(()))
			}),
			("settlement", || {
				GasArena::settlement_batch(2, &[1, 0, 1, 2]).map(|_| ())
			}),
		];
		let mut inverted = Vec::new();
		for (name, operation) in operations {
			let arena = GAS_MIXTURES.read();
			let mixtures = arena.as_ref().unwrap();
			let low = mixtures[0].write();
			let (started, ready) = mpsc::channel();
			let worker = thread::spawn(move || {
				started.send(()).unwrap();
				operation()
			});
			ready.recv_timeout(Duration::from_secs(2)).unwrap();
			// Keep the lower slot blocked while giving the operation a chance to run.
			// Holding an upper slot here would deadlock a worker that next needed it.
			let deadline = Instant::now() + Duration::from_millis(100);
			while Instant::now() < deadline {
				if mixtures[1].try_write().is_none() || mixtures[2].try_write().is_none() {
					inverted.push(name);
					break;
				}
				thread::yield_now();
			}
			// Release the obstruction before joining, including on the regression path.
			drop(low);
			worker.join().unwrap().unwrap();
		}
		assert!(
			inverted.is_empty(),
			"mixture lock order inverted by {inverted:?}"
		);
	}

	#[test]
	fn mixture_pair_access_preserves_arguments_and_alias_policy() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		*GAS_MIXTURES.write() = Some(
			[10.0, 20.0]
				.map(|volume| parking_lot::RwLock::new(super::Mixture::from_vol(volume)))
				.into(),
		);
		for (src, arg, expected) in [
			(0, 1, (10.0, 20.0)),
			(1, 0, (20.0, 10.0)),
			(0, 0, (10.0, 10.0)),
		] {
			assert_eq!(
				GasArena::with_gas_mixtures(src, arg, |source, other| {
					assert_eq!(std::ptr::eq(source, other), src == arg);
					Ok((source.get_volume(), other.get_volume()))
				})
				.unwrap(),
				expected,
			);
		}
		for (src, arg) in [(0, 1), (1, 0)] {
			let giver_volume = GasArena::with_gas_mixture(arg, |mix| Ok(mix.get_volume())).unwrap();
			GasArena::with_gas_mixtures_mut_and_read(src, arg, |source, other| {
				assert_eq!(other.get_volume(), giver_volume);
				source.set_volume(100.0 + src as f32)?;
				Ok(())
			})
			.unwrap();
			assert_eq!(
				GasArena::with_gas_mixture(src, |mix| Ok(mix.get_volume())).unwrap(),
				100.0 + src as f32
			);
			assert_eq!(
				GasArena::with_gas_mixture(arg, |mix| Ok(mix.get_volume())).unwrap(),
				giver_volume
			);
		}
		assert!(
			GasArena::with_gas_mixtures_mut_and_read::<(), _>(0, 0, |_, _| panic!(
				"aliased mutation"
			))
			.is_err()
		);
		assert!(
			GasArena::with_gas_mixtures_mut::<(), _>(0, 0, |_, _| panic!("aliased mutation"))
				.is_err()
		);
		assert!(GasArena::with_gas_mixtures::<(), _>(0, 2, |_, _| panic!("invalid slot")).is_err());
		assert!(
			GasArena::with_gas_mixtures_mut_and_read::<(), _>(2, 0, |_, _| panic!("invalid slot"))
				.is_err()
		);
	}

	#[test]
	fn settlement_batch_preserves_direction_immutability_and_aliases() {
		use super::{constants::MINIMUM_MOLES_DELTA_TO_MOVE, types::*, Mixture};
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		set_gas_statics_manually();
		register_gas_manually("o2", 20.0);
		let mut source = Mixture::new();
		source.set_moles(0, 10.0).unwrap();
		source.set_temperature(300.0);
		let mut hotter = source.clone();
		hotter.set_temperature(1000.0);
		let mut fixed = hotter.clone();
		fixed.mark_immutable();
		let empty = Mixture::new();
		*GAS_MIXTURES.write() = Some(
			[source, hotter, fixed, empty]
				.into_iter()
				.map(parking_lot::RwLock::new)
				.collect(),
		);
		assert_eq!(
			GasArena::settlement_batch(0, &[0, 1, 2, 3, 1, 0]).unwrap(),
			vec![0, 0, 2, 1, 2, 2, 0]
		);
		assert_eq!(
			GasArena::settlement_batch(2, &[0, 2]).unwrap(),
			vec![1, 2, 0]
		);
		assert_eq!(GasArena::settlement_batch(0, &[]).unwrap(), vec![0]);
		// Each call must see mutations; never reuse a pre-simulation answer.
		GasArena::with_gas_mixture_mut(1, |mix| {
			mix.set_temperature(300.0);
			Ok(())
		})
		.unwrap();
		assert_eq!(GasArena::settlement_batch(0, &[1]).unwrap(), vec![0, 0]);
		// Compare direction matters for sparse mixtures and the exact mole threshold.
		GasArena::with_gas_mixture_mut(3, |mix| {
			mix.set_moles(0, MINIMUM_MOLES_DELTA_TO_MOVE)?;
			Ok(())
		})
		.unwrap();
		for source in 0..4 {
			for neighbor in 0..4 {
				let expected = GasArena::with_gas_mixture(source, |left| {
					GasArena::with_gas_mixture(neighbor, |right| {
						let differs = left.temperature_compare(right)
							|| left.compare_with(right, MINIMUM_MOLES_DELTA_TO_MOVE);
						Ok(vec![
							u8::from(left.is_immutable()),
							if !differs {
								0
							} else if right.is_immutable() {
								1
							} else {
								2
							},
						])
					})
				})
				.unwrap();
				assert_eq!(
					GasArena::settlement_batch(source, &[neighbor]).unwrap(),
					expected
				);
			}
		}
	}

	#[test]
	fn settlement_batch_rejects_invalid_slots_and_oversized_batches() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		*GAS_MIXTURES.write() = Some(vec![parking_lot::RwLock::new(super::Mixture::new())]);
		assert!(GasArena::settlement_batch(1, &[]).is_err());
		assert!(GasArena::settlement_batch(0, &[1]).is_err());
		assert!(GasArena::settlement_batch(0, &[0; 7]).is_err());
		*GAS_MIXTURES.write() = None;
		assert!(GasArena::settlement_batch(0, &[]).is_err());
	}

	#[test]
	fn rejects_invalid_or_stale_gas_arena_slots() {
		assert!(gas_slot_from_number(f32::NAN, 4).is_err());
		assert!(gas_slot_from_number(-1.0, 4).is_err());
		assert!(gas_slot_from_number(1.5, 4).is_err());
		assert!(gas_slot_from_number(4.0, 4).is_err());
		assert_eq!(gas_slot_from_number(3.0, 4).unwrap(), 3);
	}

	#[test]
	fn rejects_aliased_mutation_slots() {
		assert!(ensure_distinct_mixture_slots(4, 4).is_err());
		assert!(ensure_distinct_mixture_slots(4, 5).is_ok());
	}

	#[test]
	fn gas_runtime_metrics_report_source_layout_and_reserved_capacity() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		let metrics = gas_runtime_metrics();
		assert_eq!(metrics.mixture_bytes, 60);
		assert_eq!(metrics.mixture_lock_bytes, 64);
		assert_eq!(metrics.arena_capacity, 0);
		assert_eq!(metrics.active_slots, 0);
	}

	#[test]
	fn gas_runtime_metrics_count_retained_mole_allocations() {
		use super::{types::*, Mixture};
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		set_gas_statics_manually();
		for id in ["a", "b", "c", "d", "e", "f", "g", "h", "i"] {
			register_gas_manually(id, 20.0);
		}
		let mut mixture = Mixture::new();
		mixture.set_moles(0, 2.0).unwrap();
		mixture.set_moles(8, 1.0).unwrap();
		*GAS_MIXTURES.write() = Some(vec![parking_lot::RwLock::new(mixture)]);
		assert_eq!(gas_runtime_metrics().mole_spills, 1);
		GasArena::with_gas_mixture_mut(0, |mix| {
			mix.set_moles(8, 0.0)?;
			Ok(())
		})
		.unwrap();
		let metrics = gas_runtime_metrics();
		assert_eq!(metrics.mole_length_one_to_four, 1);
		assert_eq!(
			metrics.mole_spills, 1,
			"truncating moles retains the heap allocation"
		);
		GasArena::with_gas_mixture_mut(0, |mix| {
			mix.set_moles(0, 0.0)?;
			Ok(())
		})
		.unwrap();
		let metrics = gas_runtime_metrics();
		assert_eq!(metrics.mole_length_zero, 1);
		assert_eq!(
			metrics.mole_spills, 1,
			"an empty mixture can still own heap storage"
		);
		destroy_gas_statics();
	}

	#[test]
	fn gas_arenas_are_released_and_recreated_for_world_reuse() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		shut_down_gases();
		assert!(GAS_MIXTURES.read().is_none());
		assert!(NEXT_GAS_IDS.read().is_none());
		let metrics = gas_runtime_metrics();
		assert_eq!(metrics.arena_capacity, 0);
		assert_eq!(metrics.active_slots, 0);
		assert_eq!(metrics.slot_high_water, 0);
		let error = GasArena::with_gas_mixture(0, |_| Ok(())).unwrap_err();
		assert!(error.to_string().contains("not initialized"));

		prepare_gases_for_world();
		assert_eq!(gas_runtime_metrics().arena_capacity, 0);
	}
}
