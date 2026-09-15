use super::*;
use crate::slot_index::PagedSlotIndex;
use std::{
	future::Future,
	pin::Pin,
	sync::atomic::{AtomicBool, Ordering},
	task::{Context, Poll},
};

type ComputationOutput = (
	ComponentKernel,
	IndexedTransaction<MixtureRecord>,
	Vec<WorldEvent>,
	Result<StageResult, WorldError>,
);

pub(super) struct Computation {
	future: Pin<Box<dyn Future<Output = ComputationOutput> + Send>>,
	cancelled: Arc<AtomicBool>,
}

impl Computation {
	pub(super) fn poll(&mut self, context: &mut Context<'_>) -> Poll<ComputationOutput> {
		self.future.as_mut().poll(context)
	}
	pub(super) fn cancel(mut self) -> ComputationOutput {
		// Every suspension point checks this flag before doing more kernel work.
		// Return owned scratch to the stage instead of deallocating it with the future.
		self.cancelled.store(true, Ordering::Relaxed);
		match self.poll(&mut Context::from_waker(std::task::Waker::noop())) {
			Poll::Ready(output) => output,
			Poll::Pending => unreachable!("cancelled component must return at its next suspension"),
		}
	}
}

struct Yield(bool);
impl Future for Yield {
	type Output = ();
	fn poll(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<()> {
		if self.0 {
			Poll::Ready(())
		} else {
			self.0 = true;
			Poll::Pending
		}
	}
}
async fn cooperate(cancelled: &AtomicBool) -> Result<(), WorldError> {
	if cancelled.load(Ordering::Relaxed) {
		return Err(WorldError::Cancelled);
	}
	Yield(false).await;
	if cancelled.load(Ordering::Relaxed) {
		return Err(WorldError::Cancelled);
	}
	Ok(())
}

pub(super) fn compute(
	mut kernel: ComponentKernel,
	mut transaction: IndexedTransaction<MixtureRecord>,
	mut events: Vec<WorldEvent>,
	stage: WorldStage,
) -> Computation {
	let cancelled = Arc::clone(&kernel.cancelled);
	let future = Box::pin(async move {
		let result = match stage {
			WorldStage::Equalize => kernel.compute_equalize(&mut transaction, &mut events).await,
			WorldStage::ExcitedGroups => kernel.compute_excited_groups(&mut transaction).await,
			_ => unreachable!("component stage"),
		};
		(kernel, transaction, events, result)
	});
	Computation { future, cancelled }
}

struct ComponentTopology(
	PagedSlotIndex<TurfHandle, [Option<crate::topology::TopologyNeighbor>; MAX_TURF_NEIGHBORS]>,
);
impl ComponentTopology {
	fn gas_neighbors(
		&self,
		handle: TurfHandle,
	) -> impl Iterator<Item = crate::topology::TopologyNeighbor> + '_ {
		self.0
			.get(&handle)
			.into_iter()
			.flat_map(|row| row.iter().flatten().copied())
	}
}

pub(super) struct ComponentKernel {
	cancelled: Arc<AtomicBool>,
	handles: Vec<TurfHandle>,
	handles_by_slot: SlotIndex<u32, TurfHandle>,
	turfs: PagedSlotIndex<TurfHandle, TurfRecord>,
	mixtures: PagedSlotIndex<MixtureHandle, MixtureRecord>,
	topology: ComponentTopology,
	gas_registry: Option<GasMetadataRegistry>,
	equalize_hard_turf_limit: u32,
	group_nodes: PagedVec<GroupNode>,
	group_sort_scratch: PagedVec<GroupNode>,
}

type GroupNode = (u32, TurfHandle, MixtureHandle);

/// Stable slot order without a node-per-turf tree or an uninterruptible full sort.
/// Each sorting quantum examines or copies at most 64 small records.
async fn sort_group_nodes(
	nodes: &mut PagedVec<GroupNode>,
	scratch: &mut PagedVec<GroupNode>,
	cancelled: &AtomicBool,
) -> Result<(), WorldError> {
	let mut sorted = true;
	for index in 1..nodes.len() {
		if (index - 1).is_multiple_of(64) {
			cooperate(cancelled).await?;
		}
		sorted &= nodes[index - 1].0 <= nodes[index].0;
	}
	if sorted {
		return Ok(());
	}
	let mut width = 1;
	while width < nodes.len() {
		scratch.clear();
		for start in (0..nodes.len()).step_by(width * 2) {
			let middle = (start + width).min(nodes.len());
			let end = (middle + width).min(nodes.len());
			let (mut left, mut right) = (start, middle);
			while left < middle || right < end {
				if scratch.len().is_multiple_of(64) {
					cooperate(cancelled).await?;
				}
				let next = if right == end || (left < middle && nodes[left].0 <= nodes[right].0) {
					let next = nodes[left];
					left += 1;
					next
				} else {
					let next = nodes[right];
					right += 1;
					next
				};
				scratch
					.try_push(next)
					.map_err(|_| world_allocation_failed())?;
			}
		}
		std::mem::swap(nodes, scratch);
		width *= 2;
	}
	Ok(())
}

fn group_position(nodes: &PagedVec<GroupNode>, slot: u32) -> Option<usize> {
	let (mut low, mut high) = (0, nodes.len());
	while low < high {
		let middle = low + (high - low) / 2;
		match nodes[middle].0.cmp(&slot) {
			std::cmp::Ordering::Less => low = middle + 1,
			std::cmp::Ordering::Greater => high = middle,
			std::cmp::Ordering::Equal => return Some(middle),
		}
	}
	None
}

impl ComponentKernel {
	pub(super) fn capacity_bytes(&self) -> usize {
		self.handles.capacity() * std::mem::size_of::<TurfHandle>()
			+ (self.group_nodes.capacity() + self.group_sort_scratch.capacity())
				* std::mem::size_of::<GroupNode>()
			+ self.handles_by_slot.capacity_bytes()
			+ self.turfs.capacity_bytes()
			+ self.mixtures.capacity_bytes()
			+ self.topology.0.capacity_bytes()
	}
	pub(super) fn new(world: &DogmosWorld) -> Self {
		Self {
			cancelled: Arc::new(AtomicBool::new(false)),
			handles: Vec::new(),
			handles_by_slot: SlotIndex::new(),
			turfs: PagedSlotIndex::new(),
			mixtures: PagedSlotIndex::new(),
			topology: ComponentTopology(PagedSlotIndex::new()),
			gas_registry: world.gas_registry.clone(),
			equalize_hard_turf_limit: world.equalize_hard_turf_limit,
			group_nodes: PagedVec::new(),
			group_sort_scratch: PagedVec::new(),
		}
	}
	pub(super) fn capture(
		&mut self,
		world: &DogmosWorld,
		handle: TurfHandle,
	) -> Result<(), WorldError> {
		let turf = world.require_turf_handle(handle)?.clone();
		if let Some(mixture) = turf.mixture {
			self.mixtures
				.try_insert(mixture, world.require_handle(mixture)?.clone())
				.map_err(|_| world_allocation_failed())?;
		}
		self.turfs
			.try_insert(handle, turf)
			.map_err(|_| world_allocation_failed())?;
		self.handles.push(handle);
		self.handles_by_slot.insert(handle.slot, handle);
		let mut row = [None; MAX_TURF_NEIGHBORS];
		for (entry, neighbor) in row.iter_mut().zip(world.topology.gas_neighbors(handle)) {
			*entry = Some(neighbor);
		}
		self.topology
			.0
			.try_insert(handle, row)
			.map_err(|_| world_allocation_failed())?;
		Ok(())
	}
	pub(super) fn clear(&mut self) {
		self.cancelled.store(false, Ordering::Relaxed);
		self.handles.clear();
		self.handles_by_slot.clear();
		self.turfs.clear();
		self.mixtures.clear();
		self.topology.0.clear();
		self.group_nodes.clear();
		self.group_sort_scratch.clear();
	}
	fn stage_turf_handles(&self) -> Cow<'_, [TurfHandle]> {
		Cow::Borrowed(&self.handles)
	}
	fn require_turf_handle(&self, handle: TurfHandle) -> Result<&TurfRecord, WorldError> {
		self.turfs
			.get(&handle)
			.ok_or(WorldError::UnknownTurfHandle(handle))
	}
	fn require_handle(&self, handle: MixtureHandle) -> Result<&MixtureRecord, WorldError> {
		self.mixtures
			.get(&handle)
			.ok_or(WorldError::UnknownHandle(handle))
	}
	fn current_turf_handle(&self, slot: u32) -> Result<TurfHandle, WorldError> {
		self.handles_by_slot
			.get(&slot)
			.copied()
			.ok_or(WorldError::UnknownTurfHandle(TurfHandle {
				slot,
				generation: 0,
			}))
	}
	fn current_turf_mixture(&self, slot: u32) -> Result<MixtureHandle, WorldError> {
		let turf_handle = self.current_turf_handle(slot)?;
		self.require_turf_handle(turf_handle)?
			.mixture
			.ok_or(WorldError::TurfMissingMixture(turf_handle))
	}
	pub(super) async fn compute_excited_groups(
		&mut self,
		transaction: &mut IndexedTransaction<MixtureRecord>,
	) -> Result<StageResult, WorldError> {
		cooperate(&self.cancelled).await?;
		self.group_nodes.clear();
		for index in 0..self.handles.len() {
			cooperate(&self.cancelled).await?;
			let handle = self.handles[index];
			if let Some(mixture) = self
				.require_turf_handle(handle)
				.ok()
				.and_then(|turf| turf.mixture)
			{
				self.group_nodes
					.try_push((handle.slot, handle, mixture))
					.map_err(|_| world_allocation_failed())?;
			}
		}
		sort_group_nodes(
			&mut self.group_nodes,
			&mut self.group_sort_scratch,
			&self.cancelled,
		)
		.await?;
		let nodes = &self.group_nodes;
		if nodes.len() == 0 {
			return Ok(StageResult { work_items: 0 });
		}
		let position_of = |slot| group_position(nodes, slot);
		let specific_heats = self
			.gas_registry
			.as_ref()
			.ok_or(WorldError::GasRegistryMissing)?
			.specific_heats();
		let mut heat_values = [0.0; MAX_GAS_SLOTS];
		heat_values[..specific_heats.len()].copy_from_slice(specific_heats);
		// Positions in `nodes` are dense, so visited marking is a direct index rather than a
		// tree insert. `queue` and `accepted` carry positions for the same reason.
		let mut found = vec![false; nodes.len()];
		let mut queue: Vec<usize> = Vec::new();
		let mut accepted: Vec<usize> = Vec::new();
		let mut work_items = 0_u32;
		for initial_position in 0..nodes.len() {
			cooperate(&self.cancelled).await?;
			if found[initial_position]
				|| !self
					.topology
					.gas_neighbors(nodes[initial_position].1)
					.any(|neighbor| {
						position_of(neighbor.handle.slot)
							.is_some_and(|position| nodes[position].1 == neighbor.handle)
					}) {
				continue;
			}
			cooperate(&self.cancelled).await?;
			let initial_mixture = self.require_handle(nodes[initial_position].2)?;
			if initial_mixture.immutable {
				continue;
			}
			let initial_pressure = mixture_pressure(initial_mixture);
			let mut minimum_pressure = initial_pressure;
			let mut maximum_pressure = initial_pressure;
			queue.clear();
			queue.push(initial_position);
			let mut queue_index = 0;
			accepted.clear();
			found[initial_position] = true;
			while queue_index < queue.len() && accepted.len() < 2500 {
				cooperate(&self.cancelled).await?;
				let position = queue[queue_index];
				queue_index += 1;
				let mixture = self.require_handle(nodes[position].2)?;
				if mixture.immutable {
					continue;
				}
				let pressure = mixture_pressure(mixture);
				let next_minimum = minimum_pressure.min(pressure);
				let next_maximum = maximum_pressure.max(pressure);
				if (next_maximum - next_minimum).abs() >= EXCITED_GROUP_PRESSURE_GOAL_KPA {
					continue;
				}
				minimum_pressure = next_minimum;
				maximum_pressure = next_maximum;
				accepted.push(position);
				for neighbor in self.topology.gas_neighbors(nodes[position].1) {
					let Some(neighbor_position) = position_of(neighbor.handle.slot) else {
						continue;
					};
					if nodes[neighbor_position].1 == neighbor.handle && !found[neighbor_position] {
						found[neighbor_position] = true;
						queue.push(neighbor_position);
					}
				}
			}
			if accepted.is_empty() {
				continue;
			}
			let mut mixed_gases = [0.0; MAX_GAS_SLOTS];
			let mut total_capacity = 0.0;
			let mut total_energy = 0.0;
			for &position in &accepted {
				cooperate(&self.cancelled).await?;
				let handle = nodes[position].2;
				let mixture = self.require_handle(handle)?;
				if transaction.contains(handle) {
					return Err(WorldError::DuplicateMutableTurfMixture(handle));
				}
				if mixture.revision == u32::MAX {
					return Err(WorldError::RevisionExhausted(handle));
				}
				transaction
					.touch(handle, mixture.revision, mixture)
					.map_err(transaction_world_error)?;
				for (total, amount) in mixed_gases.iter_mut().zip(mixture.gases) {
					*total += amount;
				}
				let capacity = record_heat_capacity(mixture, &heat_values);
				total_capacity += capacity;
				total_energy += capacity * mixture.temperature;
			}
			let divisor = accepted.len() as f32;
			for amount in &mut mixed_gases {
				*amount /= divisor;
			}
			let mixed_temperature = if total_capacity > MINIMUM_HEAT_CAPACITY {
				total_energy / total_capacity
			} else {
				MINIMUM_TEMPERATURE_K
			};
			for &position in &accepted {
				cooperate(&self.cancelled).await?;
				let handle = nodes[position].2;
				let candidate = transaction
					.candidate_mut(handle)
					.expect("accepted mixture was reserved before averaging");
				candidate.gases = mixed_gases;
				candidate.temperature = mixed_temperature;
				work_items = work_items
					.checked_add(1)
					.ok_or_else(|| WorldError::State("excited turf count exceeds u32".into()))?;
			}
		}
		cooperate(&self.cancelled).await?;
		Ok(StageResult { work_items })
	}
	pub(super) async fn compute_equalize(
		&self,
		transaction: &mut IndexedTransaction<MixtureRecord>,
		staged_events: &mut Vec<WorldEvent>,
	) -> Result<StageResult, WorldError> {
		cooperate(&self.cancelled).await?;
		let turf_handles = self.stage_turf_handles();
		if turf_handles.is_empty() {
			return Ok(StageResult { work_items: 0 });
		}
		let active_by_slot = &self.handles_by_slot;
		let specific_heats = self
			.gas_registry
			.as_ref()
			.map(|registry| {
				let mut values = [0.0; MAX_GAS_SLOTS];
				values[..registry.specific_heats().len()]
					.copy_from_slice(registry.specific_heats());
				values
			})
			.unwrap_or([0.0; MAX_GAS_SLOTS]);
		// Captured turfs have stable dense positions for this computation. Tracking
		// them here avoids allocating tree nodes without indexing sparse slots.
		let mut visited = vec![false; turf_handles.len()];
		let mut work_items = 0_u32;
		for &start in turf_handles.iter() {
			cooperate(&self.cancelled).await?;
			let start_index = self.turfs.index_of(&start).expect("captured turf");
			if self.require_turf_handle(start)?.mixture.is_none()
				|| std::mem::replace(&mut visited[start_index], true)
			{
				continue;
			}
			cooperate(&self.cancelled).await?;
			let mut component = vec![start.slot];
			let mut parents = vec![0_usize];
			let mut queue_index = 0;
			while queue_index < component.len() {
				cooperate(&self.cancelled).await?;
				let current = component[queue_index];
				queue_index += 1;
				for neighbor in self.topology.gas_neighbors(active_by_slot[&current]) {
					let Some(neighbor_index) = self.turfs.index_of(&neighbor.handle) else {
						continue;
					};
					if component.len() >= self.equalize_hard_turf_limit as usize {
						continue;
					}
					if !std::mem::replace(&mut visited[neighbor_index], true) {
						parents.push(queue_index - 1);
						component.push(neighbor.handle.slot);
					}
				}
			}
			if component.len() < 2 {
				continue;
			}
			let mut component_moles = 0.0;
			let mut minimum_moles = f32::INFINITY;
			let mut maximum_moles = 0.0_f32;
			let mut immutable_turfs = BTreeSet::new();
			for turf_slot in &component {
				cooperate(&self.cancelled).await?;
				let mixture_handle = self.current_turf_mixture(*turf_slot)?;
				let mixture = self.require_handle(mixture_handle)?;
				if mixture.immutable {
					immutable_turfs.insert(*turf_slot);
					continue;
				}
				if transaction.contains(mixture_handle) {
					return Err(WorldError::DuplicateMutableTurfMixture(mixture_handle));
				}
				if mixture.revision == u32::MAX {
					return Err(WorldError::RevisionExhausted(mixture_handle));
				}
				let moles = total_moles(mixture);
				component_moles += moles;
				minimum_moles = minimum_moles.min(moles);
				maximum_moles = maximum_moles.max(moles);
				transaction
					.touch(mixture_handle, mixture.revision, mixture)
					.map_err(transaction_world_error)?;
			}
			if !immutable_turfs.is_empty() {
				if maximum_moles >= 10.0 && immutable_turfs.len() < component.len() {
					self.stage_decompression_component(
						&component,
						&immutable_turfs,
						component_moles,
						transaction,
						staged_events,
					)
					.await?;
				}
				work_items = work_items
					.checked_add(u32::try_from(component.len()).map_err(|_| {
						WorldError::State("equalized turf count exceeds u32".into())
					})?)
					.ok_or_else(|| WorldError::State("equalized turf count exceeds u32".into()))?;
				continue;
			}
			if maximum_moles < 10.0 || maximum_moles - minimum_moles < MINIMUM_MOLES_DELTA_TO_MOVE {
				continue;
			}
			let average_moles = component_moles / component.len() as f32;
			let mut subtree_balance = Vec::with_capacity(component.len());
			for slot in &component {
				cooperate(&self.cancelled).await?;
				let handle = self.current_turf_mixture(*slot)?;
				subtree_balance.push(
					total_moles(transaction.candidate(handle).expect("component mixture"))
						- average_moles,
				);
			}
			let mut flows = Vec::<(u32, u32, f32)>::new();
			for child_index in (1..component.len()).rev() {
				cooperate(&self.cancelled).await?;
				let parent_index = parents[child_index];
				let balance = subtree_balance[child_index];
				flows.push((component[child_index], component[parent_index], balance));
				subtree_balance[parent_index] += balance;
			}
			for &(child, parent, balance) in flows.iter().filter(|(_, _, balance)| *balance > 0.0) {
				cooperate(&self.cancelled).await?;
				self.stage_equalization_transfer(
					child,
					parent,
					balance,
					&specific_heats,
					transaction,
					staged_events,
				)?;
			}
			for &(child, parent, balance) in
				flows.iter().rev().filter(|(_, _, balance)| *balance < 0.0)
			{
				cooperate(&self.cancelled).await?;
				self.stage_equalization_transfer(
					parent,
					child,
					-balance,
					&specific_heats,
					transaction,
					staged_events,
				)?;
			}
			work_items = work_items
				.checked_add(component.len() as u32)
				.ok_or_else(|| WorldError::State("equalized turf count exceeds u32".into()))?;
		}
		cooperate(&self.cancelled).await?;
		Ok(StageResult { work_items })
	}
	async fn stage_decompression_component(
		&self,
		component: &[u32],
		immutable_turfs: &BTreeSet<u32>,
		component_moles: f32,
		transaction: &mut IndexedTransaction<MixtureRecord>,
		events: &mut Vec<WorldEvent>,
	) -> Result<(), WorldError> {
		let mut component_slots = BTreeSet::new();
		for &slot in component {
			cooperate(&self.cancelled).await?;
			component_slots.insert(slot);
		}
		let mut queue = Vec::new();
		let mut reached = BTreeSet::new();
		for &slot in immutable_turfs {
			cooperate(&self.cancelled).await?;
			queue.push(slot);
			reached.insert(slot);
		}
		let mut parents = BTreeMap::<u32, u32>::new();
		let mut queue_index = 0;
		while queue_index < queue.len() {
			cooperate(&self.cancelled).await?;
			let current = queue[queue_index];
			queue_index += 1;
			let current_handle = self.current_turf_handle(current)?;
			for neighbor in self.topology.gas_neighbors(current_handle) {
				if component_slots.contains(&neighbor.handle.slot)
					&& reached.insert(neighbor.handle.slot)
				{
					parents.insert(neighbor.handle.slot, current);
					queue.push(neighbor.handle.slot);
				}
			}
		}

		let mutable_count = component.len() - immutable_turfs.len();
		if mutable_count == 0 {
			return Ok(());
		}
		let frontage = immutable_turfs.len().clamp(1, 4) as f32;
		let removal_per_turf = component_moles / mutable_count as f32 * frontage / 4.0;
		struct DecompressionLoss {
			local: f32,
			accumulated: f32,
		}
		// The charged traversal fills this vector in slot order, allowing binary
		// lookups without allocating or cloning a loss tree.
		let mut losses = Vec::with_capacity(mutable_count);
		// The component set preserves the old slot-sorted mutable traversal. Charge
		// skipped immutable turfs too so a long boundary cannot monopolize a poll.
		for &turf_slot in &component_slots {
			cooperate(&self.cancelled).await?;
			if immutable_turfs.contains(&turf_slot) {
				continue;
			}
			let mixture_handle = self.current_turf_mixture(turf_slot)?;
			let mixture = transaction
				.candidate_mut(mixture_handle)
				.expect("component mixtures were touched before decompression");
			let before = total_moles(mixture);
			let ratio = if before > 0.0 {
				(removal_per_turf / before).clamp(0.0, 1.0)
			} else {
				0.0
			};
			for amount in &mut mixture.gases {
				*amount -= quantized_removal(*amount, ratio);
			}
			let lost = before - total_moles(mixture);
			losses.push((
				turf_slot,
				DecompressionLoss {
					local: lost,
					accumulated: lost,
				},
			));
		}
		for left in component_slots.iter().copied() {
			cooperate(&self.cancelled).await?;
			let left_handle = self.current_turf_handle(left)?;
			for neighbor in self.topology.gas_neighbors(left_handle).filter(|neighbor| {
				neighbor.firelock
					&& left < neighbor.handle.slot
					&& component_slots.contains(&neighbor.handle.slot)
			}) {
				let right = neighbor.handle.slot;
				let (source_slot, target_slot) =
					if immutable_turfs.contains(&left) && !immutable_turfs.contains(&right) {
						(right, left)
					} else {
						(left, right)
					};
				events.push(WorldEvent::FirelockConsideration {
					source: self.current_turf_handle(source_slot)?,
					target: self.current_turf_handle(target_slot)?,
				});
			}
		}

		for &source_slot in queue.iter().rev() {
			cooperate(&self.cancelled).await?;
			if immutable_turfs.contains(&source_slot) {
				continue;
			}
			let Some(&target_slot) = parents.get(&source_slot) else {
				continue;
			};
			let source_index = losses
				.binary_search_by_key(&source_slot, |&(slot, _)| slot)
				.expect("mutable source has a local loss");
			let pressure_moles = losses[source_index].1.accumulated;
			if pressure_moles > 0.0 {
				events.push(WorldEvent::PressureDifference {
					source: self.current_turf_handle(source_slot)?,
					target: self.current_turf_handle(target_slot)?,
					moles: pressure_moles,
				});
			}
			if immutable_turfs.contains(&target_slot) {
				let moles_lost = losses[source_index].1.local;
				if moles_lost > 0.0 {
					events.push(WorldEvent::DecompressionFloorRip {
						turf: self.current_turf_handle(source_slot)?,
						moles_lost,
					});
				}
			} else if component_slots.contains(&target_slot) {
				let target_index = losses
					.binary_search_by_key(&target_slot, |&(slot, _)| slot)
					.expect("mutable target has a local loss");
				losses[target_index].1.accumulated += pressure_moles;
			}
		}
		Ok(())
	}
	fn stage_equalization_transfer(
		&self,
		source_slot: u32,
		target_slot: u32,
		amount: f32,
		specific_heats: &[f32; MAX_GAS_SLOTS],
		transaction: &mut IndexedTransaction<MixtureRecord>,
		events: &mut Vec<WorldEvent>,
	) -> Result<(), WorldError> {
		let source_handle = self.current_turf_mixture(source_slot)?;
		let target_handle = self.current_turf_mixture(target_slot)?;
		if source_handle == target_handle {
			return Err(WorldError::DuplicateMutableTurfMixture(source_handle));
		}
		let (source, target) = transaction
			.candidate_pair_mut(source_handle, target_handle)
			.map_err(transaction_world_error)?;
		let moved = transfer_moles(source, target, amount, specific_heats)?;
		if moved > 0.0 {
			events.push(WorldEvent::PressureDifference {
				source: self.current_turf_handle(source_slot)?,
				target: self.current_turf_handle(target_slot)?,
				moles: moved,
			});
		}
		Ok(())
	}
}

#[cfg(test)]
mod sort_tests {
	use super::*;

	fn rows(slots: impl IntoIterator<Item = u32>) -> PagedVec<GroupNode> {
		let mut result = PagedVec::new();
		for slot in slots {
			result
				.try_push((
					slot,
					TurfHandle {
						slot,
						generation: 2,
					},
					MixtureHandle {
						slot,
						generation: 3,
					},
				))
				.unwrap();
		}
		result
	}

	#[test]
	fn cooperative_sort_matches_independent_slot_order_across_pages() {
		for count in [0, 1, 17, 513] {
			let slots: Vec<_> = (0..count).map(|index| (index * 137) % 1021).collect();
			let mut expected = slots.clone();
			expected.sort_unstable();
			let mut nodes = rows(slots);
			let mut scratch = PagedVec::new();
			let cancelled = AtomicBool::new(false);
			{
				let mut sort =
					std::pin::pin!(sort_group_nodes(&mut nodes, &mut scratch, &cancelled));
				let mut polls = 0;
				loop {
					polls += 1;
					assert!(polls < 1000, "bounded fixture exceeded sorting work");
					if let Poll::Ready(result) = sort
						.as_mut()
						.poll(&mut Context::from_waker(std::task::Waker::noop()))
					{
						result.unwrap();
						break;
					}
				}
			}
			for (index, slot) in expected.into_iter().enumerate() {
				assert_eq!(
					nodes[index],
					(
						slot,
						TurfHandle {
							slot,
							generation: 2
						},
						MixtureHandle {
							slot,
							generation: 3
						}
					)
				);
				assert_eq!(group_position(&nodes, slot), Some(index));
			}
			assert_eq!(group_position(&nodes, 2048), None);
		}
	}

	#[test]
	fn sorting_cancellation_returns_at_every_suspension_without_freeing_pages() {
		for cutoff in 0..100 {
			let mut nodes = rows([6, 3, 11, 0, 2]);
			let mut scratch = PagedVec::new();
			let cancelled = AtomicBool::new(false);
			let capacity = nodes.capacity();
			let mut finished = false;
			{
				let mut sort =
					std::pin::pin!(sort_group_nodes(&mut nodes, &mut scratch, &cancelled));
				for _ in 0..cutoff {
					if let Poll::Ready(result) = sort
						.as_mut()
						.poll(&mut Context::from_waker(std::task::Waker::noop()))
					{
						result.unwrap();
						finished = true;
						break;
					}
				}
				if !finished {
					cancelled.store(true, Ordering::Relaxed);
					assert!(matches!(
						sort.as_mut()
							.poll(&mut Context::from_waker(std::task::Waker::noop())),
						Poll::Ready(Err(WorldError::Cancelled))
					));
				}
			}
			assert!(nodes.capacity() >= capacity);
			if finished {
				return;
			}
		}
		panic!("sorting never completed");
	}
}
