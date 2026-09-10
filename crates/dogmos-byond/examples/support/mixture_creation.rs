use dogmos_byond::{encode_production_mixture_command, DogmosClient};
use dogmos_protocol::{
	encode_lifecycle_batch, LifecycleAction, LifecycleMutation, MixtureCommandResponse,
	MixtureSnapshot, MixtureSnapshotRequest, OperationKind, ServiceErrorCode, WireHandle,
	MIXTURE_COMMAND_RESPONSE_LEN, MIXTURE_SNAPSHOT_LEN,
};
use std::error::Error;

const DEFAULT_VOLUME: f32 = 2500.0;
const FIRST_SLOT: u32 = 10_000;

#[derive(Clone, Copy)]
struct Case {
	name: &'static str,
	volume: f32,
	populated: bool,
	recycled: bool,
}

#[derive(Default)]
struct ConstructionCalls {
	old: u32,
	fused: u32,
}

pub(super) fn verify(client: &mut DogmosClient) -> Result<(), Box<dyn Error>> {
	let cases = [
		Case {
			name: "default",
			volume: DEFAULT_VOLUME,
			populated: true,
			recycled: false,
		},
		Case {
			name: "custom",
			volume: 125.0,
			populated: true,
			recycled: false,
		},
		Case {
			name: "empty",
			volume: DEFAULT_VOLUME,
			populated: false,
			recycled: false,
		},
		Case {
			name: "recycled",
			volume: 375.0,
			populated: true,
			recycled: true,
		},
	];
	let mut next_slot = FIRST_SLOT;
	for copies in [16_u32, 64] {
		for case in cases {
			verify_case(client, case, copies, &mut next_slot)?;
		}
	}
	verify_rejections_and_retry(client, &mut next_slot)?;
	println!(
		"mixture creation transport: matched 16/64-copy default/custom/empty/recycled witnesses; construction RPC counts recorded at request calls"
	);
	Ok(())
}

fn verify_case(
	client: &mut DogmosClient,
	case: Case,
	copies: u32,
	next_slot: &mut u32,
) -> Result<(), Box<dyn Error>> {
	let old_source = allocate(next_slot);
	let fused_source = allocate(next_slot);
	setup_source(client, old_source, case.populated)?;
	setup_source(client, fused_source, case.populated)?;
	let old_source_before = snapshot(client, old_source)?;
	let fused_source_before = snapshot(client, fused_source)?;

	let old_destinations = allocate_handles(next_slot, copies, case.recycled);
	let fused_destinations = allocate_handles(next_slot, copies, case.recycled);
	if case.recycled {
		prepare_recycled_destinations(client, &old_destinations)?;
		prepare_recycled_destinations(client, &fused_destinations)?;
	}

	let mut calls = ConstructionCalls::default();
	for (old_destination, fused_destination) in old_destinations
		.iter()
		.copied()
		.zip(fused_destinations.iter().copied())
	{
		old_create(
			client,
			old_destination,
			old_source,
			case.volume,
			&mut calls.old,
		)?;
		let response = fused_create(
			client,
			fused_destination,
			fused_source,
			case.volume,
			&mut calls.fused,
		)?;
		if response != (MixtureCommandResponse::Applied { updated: 1 }) {
			return Err(
				format!("{} fused create response changed: {response:?}", case.name).into(),
			);
		}
		if snapshot(client, old_destination)? != snapshot(client, fused_destination)? {
			return Err(format!(
				"{} {copies}-copy source creation diverged at destination slot {}",
				case.name, old_destination.slot
			)
			.into());
		}
	}

	let expected_old_per_copy = if case.volume == DEFAULT_VOLUME { 2 } else { 3 };
	if calls.old != expected_old_per_copy * copies || calls.fused != copies {
		return Err(format!(
			"{} {copies}-copy construction request counts changed: old={}, fused={}",
			case.name, calls.old, calls.fused
		)
		.into());
	}
	if snapshot(client, old_source)? != old_source_before
		|| snapshot(client, fused_source)? != fused_source_before
	{
		return Err(format!("{} source changed during creation", case.name).into());
	}
	println!(
		"mixture creation {name} copies={copies}: old_calls={} fused_calls={}",
		calls.old,
		calls.fused,
		name = case.name
	);
	Ok(())
}

fn verify_rejections_and_retry(
	client: &mut DogmosClient,
	next_slot: &mut u32,
) -> Result<(), Box<dyn Error>> {
	let source = allocate(next_slot);
	setup_source(client, source, true)?;
	let destination = allocate(next_slot);
	assert_server_error(
		fused_create_untracked(client, destination, stale_handle(source), DEFAULT_VOLUME),
		ServiceErrorCode::StaleHandle,
		"stale source",
	)?;
	assert_eq!(
		fused_create_untracked(client, destination, source, DEFAULT_VOLUME)?,
		MixtureCommandResponse::Applied { updated: 1 }
	);
	assert_server_error(
		fused_create_untracked(client, destination, source, DEFAULT_VOLUME),
		ServiceErrorCode::InvalidRequest,
		"occupied destination",
	)?;
	let retry = allocate(next_slot);
	assert_eq!(
		fused_create_untracked(client, retry, source, DEFAULT_VOLUME)?,
		MixtureCommandResponse::Applied { updated: 1 }
	);
	Ok(())
}

fn assert_server_error(
	result: Result<MixtureCommandResponse, Box<dyn Error>>,
	expected: ServiceErrorCode,
	label: &str,
) -> Result<(), Box<dyn Error>> {
	match result {
		Err(error)
			if matches!(
				error.downcast_ref::<dogmos_byond::ClientError>(),
				Some(dogmos_byond::ClientError::Server(actual)) if *actual == expected
			) =>
		{
			Ok(())
		}
		other => Err(format!("{label} returned {other:?}, expected {expected:?}").into()),
	}
}

fn setup_source(
	client: &mut DogmosClient,
	source: WireHandle,
	populated: bool,
) -> Result<(), Box<dyn Error>> {
	apply_lifecycle(client, LifecycleAction::Register, source)?;
	if populated {
		assert_applied(production_command(
			client,
			[
				14.0,
				0.0,
				source.slot as f32,
				source.generation as f32,
				0.0,
				0.0,
				401.0,
				0.0,
				0.0,
				0.0,
				0.0,
			],
		)?)?;
		assert_applied(production_command(
			client,
			[
				1.0,
				0.0,
				source.slot as f32,
				source.generation as f32,
				0.0,
				0.0,
				17.0,
				0.0,
				0.0,
				0.0,
				0.0,
			],
		)?)?;
	}
	Ok(())
}

fn prepare_recycled_destinations(
	client: &mut DogmosClient,
	destinations: &[WireHandle],
) -> Result<(), Box<dyn Error>> {
	for destination in destinations {
		let retired = WireHandle {
			slot: destination.slot,
			generation: 1,
		};
		apply_lifecycle(client, LifecycleAction::Register, retired)?;
		apply_lifecycle(client, LifecycleAction::Unregister, retired)?;
	}
	Ok(())
}

fn old_create(
	client: &mut DogmosClient,
	destination: WireHandle,
	source: WireHandle,
	volume: f32,
	calls: &mut u32,
) -> Result<(), Box<dyn Error>> {
	apply_lifecycle(client, LifecycleAction::Register, destination)?;
	*calls += 1;
	if volume != DEFAULT_VOLUME {
		assert_applied(production_command(
			client,
			[
				15.0,
				0.0,
				destination.slot as f32,
				destination.generation as f32,
				0.0,
				0.0,
				volume,
				0.0,
				0.0,
				0.0,
				0.0,
			],
		)?)?;
		*calls += 1;
	}
	assert_applied(production_command(
		client,
		[
			20.0,
			0.0,
			destination.slot as f32,
			destination.generation as f32,
			source.slot as f32,
			source.generation as f32,
			0.0,
			0.0,
			0.0,
			0.0,
			0.0,
		],
	)?)?;
	*calls += 1;
	Ok(())
}

fn fused_create(
	client: &mut DogmosClient,
	destination: WireHandle,
	source: WireHandle,
	volume: f32,
	calls: &mut u32,
) -> Result<MixtureCommandResponse, Box<dyn Error>> {
	let response = fused_create_untracked(client, destination, source, volume)?;
	*calls += 1;
	Ok(response)
}

fn fused_create_untracked(
	client: &mut DogmosClient,
	destination: WireHandle,
	source: WireHandle,
	volume: f32,
) -> Result<MixtureCommandResponse, Box<dyn Error>> {
	production_command(
		client,
		[
			37.0,
			0.0,
			destination.slot as f32,
			destination.generation as f32,
			source.slot as f32,
			source.generation as f32,
			volume,
			0.0,
			0.0,
			0.0,
			0.0,
		],
	)
}

fn production_command(
	client: &mut DogmosClient,
	fields: [f32; 11],
) -> Result<MixtureCommandResponse, Box<dyn Error>> {
	let request = encode_production_mixture_command(fields)?;
	let mut response = [0_u8; MIXTURE_COMMAND_RESPONSE_LEN];
	let response_len =
		client.round_trip_into(OperationKind::MixtureCommand, &request, &mut response)?;
	if response_len != MIXTURE_COMMAND_RESPONSE_LEN {
		return Err("mixture command response changed".into());
	}
	Ok(MixtureCommandResponse::decode(&response)?)
}

fn apply_lifecycle(
	client: &mut DogmosClient,
	action: LifecycleAction,
	handle: WireHandle,
) -> Result<(), Box<dyn Error>> {
	let mut request = Vec::new();
	encode_lifecycle_batch(&[LifecycleMutation { action, handle }], &mut request)?;
	let mut response = [0_u8; 4];
	let response_len = client.round_trip_into(
		OperationKind::MixtureLifecycleBatch,
		&request,
		&mut response,
	)?;
	if response_len != response.len() || u32::from_le_bytes(response) != 1 {
		return Err("mixture lifecycle response changed".into());
	}
	Ok(())
}

fn snapshot(
	client: &mut DogmosClient,
	handle: WireHandle,
) -> Result<MixtureSnapshot, Box<dyn Error>> {
	let mut response = [0_u8; MIXTURE_SNAPSHOT_LEN];
	let response_len = client.round_trip_into(
		OperationKind::MixtureSnapshot,
		&MixtureSnapshotRequest { handle }.encode(),
		&mut response,
	)?;
	if response_len != response.len() {
		return Err("mixture snapshot response changed".into());
	}
	Ok(MixtureSnapshot::decode(&response)?)
}

fn assert_applied(response: MixtureCommandResponse) -> Result<(), Box<dyn Error>> {
	if matches!(response, MixtureCommandResponse::Applied { .. }) {
		Ok(())
	} else {
		Err(format!("expected applied response, got {response:?}").into())
	}
}

fn allocate(next_slot: &mut u32) -> WireHandle {
	let handle = WireHandle {
		slot: *next_slot,
		generation: 1,
	};
	*next_slot += 1;
	handle
}

fn allocate_handles(next_slot: &mut u32, count: u32, recycled: bool) -> Vec<WireHandle> {
	(0..count)
		.map(|_| {
			let mut handle = allocate(next_slot);
			if recycled {
				handle.generation = 2;
			}
			handle
		})
		.collect()
}

fn stale_handle(handle: WireHandle) -> WireHandle {
	WireHandle {
		slot: handle.slot,
		generation: handle.generation - 1,
	}
}
