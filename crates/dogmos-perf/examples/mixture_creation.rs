//! Matched core-only constructor probe. Setup, snapshots and witnesses are untimed.
//! Allocated bytes count requests (including reallocations), not retained memory.
use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureSnapshot, WorldError,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	error::Error,
	fmt::Write as _,
	sync::atomic::{AtomicU64, Ordering},
	time::Instant,
};

struct Counter;
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);
#[global_allocator]
static ALLOCATOR: Counter = Counter;

fn count(pointer: *mut u8, bytes: usize) -> *mut u8 {
	if !pointer.is_null() {
		ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		BYTES.fetch_add(bytes as u64, Ordering::Relaxed);
	}
	pointer
}

unsafe impl GlobalAlloc for Counter {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		count(unsafe { System.alloc(layout) }, layout.size())
	}
	unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
		count(unsafe { System.alloc_zeroed(layout) }, layout.size())
	}
	unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
		count(unsafe { System.realloc(ptr, layout, size) }, size)
	}
	unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
		unsafe { System.dealloc(ptr, layout) }
	}
}

#[derive(Clone, Copy)]
struct Case {
	name: &'static str,
	volume: f32,
	temperature: f32,
	moles: f32,
	revision: u32,
	immutable: bool,
}

fn handle(slot: u32, generation: u32) -> MixtureHandle {
	MixtureHandle { slot, generation }
}

fn setup(case: Case, copies: u32, recycled: bool) -> Result<DogmosWorld, WorldError> {
	let mut world = DogmosWorld::new(512 * 1024 * 1024);
	world.install_gases(
		(0..MAX_GAS_SLOTS as u16)
			.map(|id| GasMetadata {
				id: GasId(id),
				key: format!("gas{id}").into(),
				name: format!("Gas {id}").into(),
				flags: 0,
				specific_heat: 20.0,
				fusion_power: 0.0,
				moles_visible: None,
				enthalpy: 0.0,
				fire_radiation_released: 0.0,
				fire_role: GasFireRole::None,
				fire_products: None,
			})
			.collect(),
	)?;
	let source = handle(0, 1);
	world.apply_lifecycle(&[LifecycleMutation {
		action: LifecycleAction::Register,
		handle: source,
	}])?;
	world.apply_command(Command::SetVolume {
		handle: source,
		volume: case.volume,
	})?;
	world.apply_command(Command::SetTemperature {
		handle: source,
		temperature: case.temperature,
	})?;
	for id in 0..MAX_GAS_SLOTS as u16 {
		world.apply_command(Command::SetMoles {
			handle: source,
			gas: GasId(id),
			amount: case.moles,
		})?;
	}
	world.apply_command(Command::SetMinimumHeatCapacity {
		handle: source,
		amount: 17.0,
	})?;
	if case.immutable {
		world.apply_command(Command::MarkImmutable { handle: source })?;
	}
	if recycled {
		let mut mutations: Vec<_> = (1..=copies)
			.map(|slot| LifecycleMutation {
				action: LifecycleAction::Register,
				handle: handle(slot, 1),
			})
			.collect();
		world.apply_lifecycle(&mutations)?;
		for mutation in &mut mutations {
			mutation.action = LifecycleAction::Unregister;
		}
		world.apply_lifecycle(&mutations)?;
	}
	Ok(world)
}

fn create(
	world: &mut DogmosWorld,
	copies: u32,
	recycled: bool,
	case: Case,
	fused: bool,
) -> Result<(), WorldError> {
	for slot in 1..=copies {
		let destination = handle(slot, if recycled { 2 } else { 1 });
		let source = handle(0, 1);
		if fused {
			world.create_mixture_from_source(destination, source, case.volume)?;
		} else {
			world.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle: destination,
			}])?;
			if case.volume != 2500.0 {
				world.apply_command(Command::SetVolume {
					handle: destination,
					volume: case.volume,
				})?;
			}
			world.apply_command(Command::CopyFrom {
				receiver: destination,
				giver: source,
			})?;
		}
	}
	Ok(())
}

fn measure(
	operation: impl FnOnce() -> Result<(), WorldError>,
) -> Result<(u64, u64, u128), WorldError> {
	ALLOCATIONS.store(0, Ordering::Relaxed);
	BYTES.store(0, Ordering::Relaxed);
	let start = Instant::now();
	operation()?;
	let elapsed = start.elapsed().as_nanos();
	Ok((
		ALLOCATIONS.load(Ordering::Relaxed),
		BYTES.load(Ordering::Relaxed),
		elapsed,
	))
}

fn hash_snapshot(mut hash: u64, handle: MixtureHandle, snapshot: &MixtureSnapshot) -> u64 {
	let words = [
		handle.slot,
		handle.generation,
		snapshot.revision,
		snapshot.temperature.to_bits(),
		snapshot.volume.to_bits(),
		snapshot.minimum_heat_capacity.to_bits(),
		snapshot.total_moles.to_bits(),
		snapshot.pressure.to_bits(),
		snapshot.heat_capacity.to_bits(),
		u32::from(snapshot.immutable),
	];
	for word in words
		.into_iter()
		.chain(snapshot.gases.iter().map(|value| value.to_bits()))
	{
		for byte in word.to_le_bytes() {
			hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
		}
	}
	hash
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: mixture_creation --output <csv>".into());
	}
	let output = args.next().ok_or("missing output path")?;
	if args.next().is_some() {
		return Err("unexpected argument".into());
	}
	let cases = [
		Case {
			name: "cold_vacuum",
			volume: 2500.0,
			temperature: 2.7,
			moles: 0.0,
			revision: 0,
			immutable: false,
		},
		Case {
			name: "warm_gas",
			volume: 2500.0,
			temperature: 293.15,
			moles: 2.0,
			revision: 1,
			immutable: false,
		},
		Case {
			name: "custom_volume_immutable_source",
			volume: 125.0,
			temperature: 700.0,
			moles: 2.0,
			revision: 2,
			immutable: true,
		},
		Case {
			name: "negative_zero_volume",
			volume: -0.0,
			temperature: 2.7,
			moles: 0.0,
			revision: 1,
			immutable: false,
		},
	];
	let mut csv = String::from("case,copies,recycled,round,implementation,allocations,allocated_bytes,elapsed_ns,state_hash,events\n");
	for copies in [1_000, 10_000, 100_000] {
		for case in cases {
			for recycled in [false, true] {
				for round in 1..=3 {
					let mut control = setup(case, copies, recycled)?;
					let mut candidate = setup(case, copies, recycled)?;
					let source_before = control.snapshot(handle(0, 1))?;
					// Alternate execution order to reduce a systematic first-run cache bias.
					let (old, new) = if round % 2 == 1 {
						let old = measure(|| create(&mut control, copies, recycled, case, false))?;
						let new = measure(|| create(&mut candidate, copies, recycled, case, true))?;
						(old, new)
					} else {
						let new = measure(|| create(&mut candidate, copies, recycled, case, true))?;
						let old = measure(|| create(&mut control, copies, recycled, case, false))?;
						(old, new)
					};
					let mut hash = 0xcbf29ce484222325;
					for slot in 1..=copies {
						let destination = handle(slot, if recycled { 2 } else { 1 });
						let actual = candidate.snapshot(destination)?;
						assert_eq!(actual, control.snapshot(destination)?);
						assert_eq!(actual.volume.to_bits(), case.volume.to_bits());
						assert_eq!(actual.temperature.to_bits(), case.temperature.to_bits());
						assert_eq!(actual.gases, [case.moles; MAX_GAS_SLOTS]);
						assert_eq!(actual.revision, case.revision);
						assert_eq!(actual.minimum_heat_capacity, 0.0);
						assert!(!actual.immutable);
						hash = hash_snapshot(hash, destination, &actual);
					}
					assert_eq!(candidate.snapshot(handle(0, 1))?, source_before);
					assert_eq!(control.snapshot(handle(0, 1))?, source_before);
					assert!(candidate.pending_events(u32::MAX).is_empty());
					assert!(control.pending_events(u32::MAX).is_empty());
					for (implementation, (allocations, bytes, elapsed)) in
						[("sequence", old), ("fused", new)]
					{
						writeln!(csv, "{},{copies},{recycled},{round},{implementation},{allocations},{bytes},{elapsed},{hash:016x},0", case.name)?;
					}
				}
			}
		}
	}
	std::fs::write(output, csv)?;
	Ok(())
}
