use super::{
	canonicalize_gases, copy_record, world_allocation_failed, DogmosWorld, MixtureHandle,
	MixtureRecord, MixtureSlot, Versioned, WorldError,
};

impl DogmosWorld {
	/// Creates a mutable mixture with the same result as registration, constructor
	/// volume assignment, and CopyFrom. Only gases and temperature come from source.
	/// The destination must be free; this operation never replaces a live identity.
	pub fn create_mixture_from_source(
		&mut self,
		destination: MixtureHandle,
		source: MixtureHandle,
		volume: f32,
	) -> Result<(), WorldError> {
		if !volume.is_finite() || volume < 0.0 {
			return Err(WorldError::InvalidVolume);
		}
		if destination.slot == source.slot {
			return Err(WorldError::SameMixtureHandles(destination));
		}
		let source = self.require_handle(source)?;
		let current = self.projected_slot(destination.slot);
		if current.occupied {
			return Err(WorldError::OccupiedMixtureSlot(destination));
		}
		if let Some(generation) = current.generation {
			if destination.generation <= generation {
				return Err(WorldError::StaleHandle {
					requested: destination,
					current: generation,
				});
			}
		}
		self.validate_slot_capacity(destination.slot)?;
		let required_slots = usize::try_from(u64::from(destination.slot) + 1)
			.map_err(|_| WorldError::StateCapacityExceeded)?;

		let mut mixture = MixtureRecord::new();
		if mixture.volume != volume {
			mixture.volume = volume;
			mixture.revision += 1;
		}
		if mixture.gases != source.gases || mixture.temperature != source.temperature {
			copy_record(&mut mixture, source);
			canonicalize_gases(&mut mixture.gases);
			mixture.revision += 1;
		}

		// A free slot has no live edges or continuations: unregister retires those
		// owners. Reserve before publishing even a tombstone or changing the arena's
		// logical length. No fallible operation remains after this reservation.
		if required_slots > self.mixtures.len() {
			self.mixtures
				.try_reserve(required_slots - self.mixtures.len())
				.map_err(|_| world_allocation_failed())?;
			self.mixtures
				.resize_with(required_slots, MixtureSlot::default);
		}
		self.mixtures[destination.slot as usize] = MixtureSlot {
			generation: Some(destination.generation),
			mixture: Versioned::new(Some(mixture)),
		};
		self.graph = None;
		Ok(())
	}
}

#[cfg(test)]
mod tests {
	use super::super::*;

	fn handle(slot: u32) -> MixtureHandle {
		MixtureHandle {
			slot,
			generation: 1,
		}
	}

	fn register(world: &mut DogmosWorld, handle: MixtureHandle) {
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle,
			}])
			.unwrap();
	}

	#[test]
	fn creation_reads_visible_publication_without_invalidating_it() {
		for publish_first in [false, true] {
			let mut world = DogmosWorld::new(1024 * 1024);
			register(&mut world, handle(0));
			let publication = Publication::new();
			let mut pending = MixtureRecord::new();
			pending.temperature = 700.0;
			pending.gases[0] = 10.0;
			pending.revision = 1;
			world.mixtures[0].mixture.stage(pending, &publication);
			if publish_first {
				assert!(publication.publish());
			}
			world
				.create_mixture_from_source(handle(1), handle(0), 2500.0)
				.unwrap();
			let created = world.require_handle(handle(1)).unwrap();
			assert_eq!(created.temperature, if publish_first { 700.0 } else { 2.7 });
			assert_eq!(created.gases[0], if publish_first { 10.0 } else { 0.0 });
			assert_eq!(created.revision, u32::from(publish_first));
			if !publish_first {
				assert!(
					publication.publish(),
					"copying must not invalidate the pending source"
				);
			}
			assert_eq!(world.require_handle(handle(0)).unwrap().gases[0], 10.0);
			assert_eq!(
				world.require_handle(handle(1)).unwrap().gases[0],
				if publish_first { 10.0 } else { 0.0 }
			);
		}
	}

	#[test]
	fn source_revision_exhaustion_does_not_prevent_read_only_creation() {
		let mut world = DogmosWorld::new(1024 * 1024);
		register(&mut world, handle(0));
		let source = world.require_handle_mut(handle(0)).unwrap();
		source.revision = u32::MAX;
		source.temperature = 300.0;
		source.gases[0] = 0.009;
		source.gases[1] = 0.01;
		source.immutable = true;
		source.minimum_heat_capacity = 99.0;
		world
			.create_mixture_from_source(handle(1), handle(0), 125.0)
			.unwrap();
		let created = world.require_handle(handle(1)).unwrap();
		assert_eq!(created.revision, 2);
		assert_eq!(created.gases[0], 0.0);
		assert_eq!(created.gases[1], 0.01);
		assert_eq!(created.minimum_heat_capacity, 0.0);
		assert!(!created.immutable);
		let source = world.require_handle(handle(0)).unwrap();
		assert_eq!(source.revision, u32::MAX);
		assert_eq!(source.gases[0], 0.009);
	}

	#[test]
	fn recycled_destination_cannot_reacquire_retired_owners_or_continuations() {
		let mut world = DogmosWorld::new(1024 * 1024);
		let source = handle(0);
		let retired = handle(1);
		let unrelated = handle(2);
		for mixture in [source, retired, unrelated] {
			register(&mut world, mixture);
		}
		let turf = TurfHandle {
			slot: 0,
			generation: 1,
		};
		world
			.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
				handle: turf,
				mixture: Some(retired),
			}])
			.unwrap();
		world
			.apply_adjacency(&[
				AdjacencyMutation {
					left: source,
					right: retired,
					conductivity: 0.1,
				},
				AdjacencyMutation {
					left: source,
					right: unrelated,
					conductivity: 0.1,
				},
			])
			.unwrap();
		let suspended = |mixture| ReactionContinuation {
			turf: None,
			mixture,
			target: crate::metadata::GameplayHandle {
				slot: 0,
				generation: 1,
			},
			next_reaction_index: 1,
			reaction_profile_threshold_ms: None,
		};
		let old_token = world.allocate_continuation(suspended(retired)).unwrap();
		let live_token = world.allocate_continuation(suspended(unrelated)).unwrap();
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: retired,
			}])
			.unwrap();
		let replacement = MixtureHandle {
			slot: 1,
			generation: 2,
		};
		world
			.create_mixture_from_source(replacement, source, 2500.0)
			.unwrap();
		assert!(!world.is_reaction_continuation_pending(old_token));
		assert!(world.is_reaction_continuation_pending(live_token));
		assert_eq!(world.pending_reaction_continuations(), 1);
		assert_eq!(world.edge_count(), 1);
		assert!(!world.mixture_edges.contains_key(&replacement.slot));
		assert!(!world.mixture_turfs.contains_key(&retired));
		assert!(!world.mixture_turfs.contains_key(&replacement));
		assert!(world.require_turf_handle(turf).unwrap().mixture.is_none());
	}
}
