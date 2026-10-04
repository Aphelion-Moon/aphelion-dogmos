use super::{
	constants::*, gas_visibility, total_num_gases, with_reactions, with_specific_heats, GasIDX,
};
use crate::reaction::{Reaction, ReactionPriority};
use atomic_float::AtomicF32;
use dogmos_core::numerics::{
	exchange_temperatures_wide, quantize_moles as quantize, weighted_temperature,
	weighted_temperature_wide,
};
use eyre::Result;
use itertools::{
	Either,
	EitherOrBoth::{Both, Left, Right},
	Itertools,
};
use std::collections::BTreeMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use tinyvec::TinyVec;

type SpecificFireInfo = (usize, f32, f32);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MixtureValueError {
	InvalidValue {
		quantity: &'static str,
		class: &'static str,
	},
	GasIndexOutOfRange {
		index: GasIDX,
		gas_count: usize,
	},
	MoleOverflow {
		index: GasIDX,
	},
}

impl fmt::Display for MixtureValueError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::InvalidValue { quantity, class } => {
				write!(formatter, "{quantity} rejected numeric class {class}")
			}
			Self::GasIndexOutOfRange { index, gas_count } => write!(
				formatter,
				"gas index {index} is outside the registered gas count {gas_count}"
			),
			Self::MoleOverflow { index } => {
				write!(formatter, "gas index {index} overflowed finite f32 moles")
			}
		}
	}
}

impl std::error::Error for MixtureValueError {}

fn invalid_numeric_class(value: f32) -> &'static str {
	if value.is_nan() {
		"NaN"
	} else if value == f32::INFINITY {
		"positive infinity"
	} else if value == f32::NEG_INFINITY {
		"negative infinity"
	} else {
		"negative finite"
	}
}

pub fn validate_mole_amount(value: f32) -> Result<f32, MixtureValueError> {
	if !value.is_finite() || value < 0.0 {
		return Err(MixtureValueError::InvalidValue {
			quantity: "mole amount",
			class: invalid_numeric_class(value),
		});
	}
	Ok(if value <= GAS_MIN_MOLES { 0.0 } else { value })
}

pub fn validate_volume(value: f32) -> Result<f32, MixtureValueError> {
	if !value.is_finite() || value < 0.0 {
		return Err(MixtureValueError::InvalidValue {
			quantity: "volume",
			class: invalid_numeric_class(value),
		});
	}
	Ok(value)
}

fn validate_mole_delta(value: f32) -> Result<f32, MixtureValueError> {
	validate_finite(value, "mole delta")
}

fn validate_finite(value: f32, quantity: &'static str) -> Result<f32, MixtureValueError> {
	if !value.is_finite() {
		return Err(MixtureValueError::InvalidValue {
			quantity,
			class: invalid_numeric_class(value),
		});
	}
	Ok(value)
}

#[derive(Debug)]
struct GasCache(AtomicF32);

impl Clone for GasCache {
	fn clone(&self) -> Self {
		Self(AtomicF32::new(self.0.load(Relaxed)))
	}
}

impl Default for GasCache {
	fn default() -> Self {
		Self(AtomicF32::new(f32::NAN))
	}
}

impl GasCache {
	pub fn invalidate(&self) {
		self.0.store(f32::NAN, Relaxed);
	}
	//cannot fix this, because f is FnMut and then() takes FnOnce
	pub fn get_or_else(&self, mut f: impl FnMut() -> f32) -> f32 {
		match self
			.0
			.fetch_update(Relaxed, Relaxed, |x| x.is_nan().then(&mut f))
		{
			Ok(_) => self.0.load(Relaxed),
			Err(x) => x,
		}
	}
	pub fn set(&self, v: f32) {
		self.0.store(v, Relaxed);
	}
}

pub fn visibility_step(gas_amt: f32) -> u32 {
	(gas_amt / MOLES_GAS_VISIBLE_STEP)
		.ceil()
		.clamp(1.0, TOTAL_VISIBLE_STATES) as u32
}

/// The data structure representing a Space Station 13 gas mixture.
/// The archive is maintained by the turf grid during processing, rather than by each mixture.
#[derive(Clone, Debug)]
pub struct Mixture {
	temperature: f32,
	pub volume: f32,
	min_heat_capacity: f32,
	moles: TinyVec<[f32; 8]>,
	cached_heat_capacity: GasCache,
	immutable: bool,
}

impl Default for Mixture {
	fn default() -> Self {
		Self::new()
	}
}

impl Mixture {
	pub(crate) fn mole_len(&self) -> usize {
		self.moles.len()
	}

	pub(crate) fn moles_spilled(&self) -> bool {
		self.moles.is_heap()
	}

	/// Makes an empty gas mixture.
	#[must_use]
	pub fn new() -> Self {
		Self {
			moles: TinyVec::new(),
			temperature: 2.7,
			volume: 2500.0,
			min_heat_capacity: 0.0,
			immutable: false,
			cached_heat_capacity: GasCache::default(),
		}
	}
	/// Makes an empty gas mixture with the given volume.
	#[must_use]
	pub fn from_vol(vol: f32) -> Self {
		let mut ret = Self::new();
		ret.volume = validate_volume(vol).unwrap_or(0.0);
		ret
	}
	/// Returns if any data is corrupt.
	pub fn is_corrupt(&self) -> bool {
		!self.temperature.is_normal()
			|| self.temperature < TCMB
			|| validate_volume(self.volume).is_err()
			|| !self.min_heat_capacity.is_finite()
			|| self.min_heat_capacity < 0.0
			|| self
				.moles
				.iter()
				.any(|amount| validate_mole_amount(*amount).is_err())
			|| self.moles.len() > total_num_gases()
	}
	/// Fixes any corruption found.
	pub fn fix_corruption(&mut self) {
		for amount in &mut self.moles {
			*amount = validate_mole_amount(*amount).unwrap_or(0.0);
		}
		self.garbage_collect();
		self.moles.truncate(total_num_gases());
		if self.temperature < TCMB || !self.temperature.is_normal() {
			self.temperature = T20C;
		}
		self.volume = validate_volume(self.volume).unwrap_or(0.0);
		if !self.min_heat_capacity.is_finite() || self.min_heat_capacity < 0.0 {
			self.min_heat_capacity = 0.0;
		}
		self.cached_heat_capacity.invalidate();
	}
	/// Returns the temperature of the mix. T
	pub fn get_temperature(&self) -> f32 {
		self.temperature
	}
	/// Returns the mixture volume in liters.
	pub fn get_volume(&self) -> f32 {
		self.volume
	}
	/// Sets a finite, non-negative volume, unless the mixture is immutable.
	pub fn set_volume(&mut self, volume: f32) -> Result<(), MixtureValueError> {
		let volume = validate_volume(volume)?;
		if !self.immutable {
			self.volume = volume;
		}
		Ok(())
	}
	/// Sets the temperature, if the mix isn't immutable. T
	pub fn set_temperature(&mut self, temp: f32) {
		if !self.immutable && temp.is_finite() {
			self.temperature = temp.max(TCMB);
		}
	}
	/// Sets the minimum heat capacity of this mix.
	pub fn set_min_heat_capacity(&mut self, amt: f32) {
		if !self.immutable && amt.is_finite() && amt >= 0.0 {
			self.min_heat_capacity = amt;
			self.cached_heat_capacity.invalidate();
		}
	}
	/// Returns an iterator over the gas keys and mole amounts thereof.
	pub fn enumerate(&self) -> impl Iterator<Item = (GasIDX, f32)> + '_ {
		self.moles.iter().copied().enumerate()
	}
	/// Allows closures to iterate over each gas.
	/// # Errors
	/// If the closure errors.
	pub fn for_each_gas(&self, mut f: impl FnMut(GasIDX, f32) -> Result<()>) -> Result<()> {
		self.enumerate().try_for_each(|(i, g)| f(i, g))?;
		Ok(())
	}
	/// As `for_each_gas`, but with mut refs to the mole counts instead of copies.
	/// # Errors
	/// If the closure errors.
	pub fn for_each_gas_mut(
		&mut self,
		mut f: impl FnMut(GasIDX, &mut f32) -> Result<()>,
	) -> Result<()> {
		let result = self
			.moles
			.iter_mut()
			.enumerate()
			.try_for_each(|(i, g)| f(i, g));
		for amount in &mut self.moles {
			*amount = validate_mole_amount(*amount).unwrap_or(0.0);
		}
		self.cached_heat_capacity.invalidate();
		self.garbage_collect();
		result
	}
	/// Returns (by value) the amount of moles of a given index the mix has. M
	pub fn get_moles(&self, idx: GasIDX) -> f32 {
		self.moles.get(idx).copied().unwrap_or(0.0)
	}
	/// Sets the mix to be internally immutable. Rust doesn't know about any of this, obviously.
	pub fn mark_immutable(&mut self) {
		self.immutable = true;
	}
	/// Returns whether this gas mixture is immutable.
	pub fn is_immutable(&self) -> bool {
		self.immutable
	}
	fn maybe_expand(&mut self, size: usize) {
		if self.moles.len() < size {
			self.moles.resize(size, 0.0);
		}
	}
	/// If mix is not immutable, sets the gas at the given `idx` to the given `amt`.
	pub fn set_moles(&mut self, idx: GasIDX, amt: f32) -> Result<(), MixtureValueError> {
		let amt = validate_mole_amount(amt)?;
		let gas_count = total_num_gases();
		if idx >= gas_count {
			return Err(MixtureValueError::GasIndexOutOfRange {
				index: idx,
				gas_count,
			});
		}
		if self.immutable {
			return Ok(());
		}
		if idx >= self.moles.len() && amt == 0.0 {
			return Ok(());
		}
		self.maybe_expand(idx + 1);
		self.moles[idx] = amt;
		self.cached_heat_capacity.invalidate();
		if amt == 0.0 {
			self.garbage_collect();
		}
		Ok(())
	}
	pub fn adjust_moles(&mut self, idx: GasIDX, amt: f32) -> Result<(), MixtureValueError> {
		let amt = validate_mole_delta(amt)?;
		let gas_count = total_num_gases();
		if idx >= gas_count {
			return Err(MixtureValueError::GasIndexOutOfRange {
				index: idx,
				gas_count,
			});
		}
		if self.immutable || amt == 0.0 || !amt.is_normal() {
			return Ok(());
		}
		let current = f64::from(self.get_moles(idx));
		let adjusted = (current + f64::from(amt)).max(0.0);
		if adjusted > f64::from(f32::MAX) {
			return Err(MixtureValueError::MoleOverflow { index: idx });
		}
		self.set_moles(idx, adjusted as f32)
	}
	pub fn adjust_multi(&mut self, adjustments: &[(usize, f32)]) -> Result<(), MixtureValueError> {
		let gas_count = total_num_gases();
		let mut results = BTreeMap::<GasIDX, f64>::new();
		for &(idx, delta) in adjustments {
			let delta = validate_mole_delta(delta)?;
			if idx >= gas_count {
				return Err(MixtureValueError::GasIndexOutOfRange {
					index: idx,
					gas_count,
				});
			}
			let current = results
				.get(&idx)
				.copied()
				.unwrap_or_else(|| f64::from(self.get_moles(idx)));
			let adjusted = (current + f64::from(delta)).max(0.0);
			if adjusted > f64::from(f32::MAX) {
				return Err(MixtureValueError::MoleOverflow { index: idx });
			}
			results.insert(idx, adjusted);
		}
		if self.immutable {
			return Ok(());
		}
		for (idx, amount) in results {
			self.set_moles(idx, amount as f32)?;
		}
		Ok(())
	}
	#[inline(never)] // mostly this makes it so that heat_capacity itself is inlined
	fn slow_heat_capacity(&self) -> f32 {
		with_specific_heats(|heats| {
			self.moles
				.iter()
				.copied()
				.zip(heats.iter())
				.fold(0.0, |acc, (amt, cap)| cap.mul_add(amt, acc))
		})
		.max(self.min_heat_capacity)
	}
	/// The heat capacity of the material. [joules?]/mole-kelvin.
	pub fn heat_capacity(&self) -> f32 {
		self.cached_heat_capacity
			.get_or_else(|| self.slow_heat_capacity())
	}
	fn heat_capacity_wide(&self) -> f64 {
		let capacity = self.heat_capacity();
		if capacity.is_finite() {
			return f64::from(capacity);
		}
		// Finite gas amounts can overflow the cache without representing an infinite reservoir.
		with_specific_heats(|heats| {
			self.moles
				.iter()
				.zip(heats)
				.fold(0.0, |acc, (&amount, &heat)| {
					f64::from(heat).mul_add(f64::from(amount), acc)
				})
		})
		.max(f64::from(self.min_heat_capacity))
	}
	/// Heat capacity of exactly one gas in this mix.
	pub fn partial_heat_capacity(&self, idx: GasIDX) -> f32 {
		self.moles
			.get(idx)
			.filter(|amt| amt.is_normal())
			.map_or(0.0, |amt| amt * with_specific_heats(|heats| heats[idx]))
	}
	/// The total mole count of the mixture. Moles.
	pub fn total_moles(&self) -> f32 {
		self.moles.iter().sum()
	}
	fn total_moles_wide(&self) -> f64 {
		self.moles.iter().copied().map(f64::from).sum()
	}
	pub(crate) fn ratio_for_amount(&self, amount: f32) -> f32 {
		let total = self.total_moles();
		if total.is_finite() {
			amount / total
		} else {
			(f64::from(amount) / self.total_moles_wide()) as f32
		}
	}
	/// Pressure. Kilopascals.
	pub fn return_pressure(&self) -> f32 {
		if self.volume <= 0.0 {
			return 0.0;
		}
		let pressure = self.total_moles() * R_IDEAL_GAS_EQUATION * self.temperature / self.volume;
		if pressure.is_finite() {
			pressure
		} else {
			(self.total_moles_wide()
				* f64::from(R_IDEAL_GAS_EQUATION)
				* f64::from(self.temperature)
				/ f64::from(self.volume)) as f32
		}
	}
	/// Thermal energy. Joules?
	pub fn thermal_energy(&self) -> f32 {
		self.heat_capacity() * self.temperature
	}
	fn blend_temperature_and_capacity(&self, giver: &Self, ratio: f32) -> (f32, f32) {
		let our_capacity = self.heat_capacity();
		let other_capacity = giver.heat_capacity() * ratio;
		let mut combined = our_capacity + other_capacity;
		let mut temperature = if combined > MINIMUM_HEAT_CAPACITY {
			weighted_temperature(
				our_capacity,
				self.temperature,
				other_capacity,
				giver.temperature,
			)
		} else {
			self.temperature
		};
		if !combined.is_finite() || !temperature.is_finite() {
			let our_capacity = self.heat_capacity_wide();
			let other_capacity = giver.heat_capacity_wide() * f64::from(ratio);
			let capacity = our_capacity + other_capacity;
			combined = capacity as f32;
			if capacity > f64::from(MINIMUM_HEAT_CAPACITY) {
				temperature = weighted_temperature_wide(
					our_capacity,
					self.temperature,
					other_capacity,
					giver.temperature,
				);
			}
		}
		(temperature, combined)
	}
	/// Merges one gas mixture into another.
	pub fn merge(&mut self, giver: &Self) {
		if self.immutable {
			return;
		}
		let (temperature, combined_heat_capacity) = self.blend_temperature_and_capacity(giver, 1.0);
		self.maybe_expand(giver.moles.len());
		self.moles
			.iter_mut()
			.zip(giver.moles.iter())
			.for_each(|(amount, added)| {
				*amount = (f64::from(*amount) + f64::from(*added)).min(f64::from(f32::MAX)) as f32;
			});
		self.set_temperature(temperature);
		// Minimum capacities belong to their mixtures and do not add with the gas.
		if self.min_heat_capacity == 0.0 && giver.min_heat_capacity == 0.0 {
			self.cached_heat_capacity.set(combined_heat_capacity);
		} else {
			self.cached_heat_capacity.invalidate();
		}
	}
	/// Turns a gas mixture into the weighted average of us and the giver, with the weights being (1-ratio, ratio), for self and the giver respectively.
	pub fn share_ratio(&mut self, giver: &Self, r: f32) {
		if self.immutable || !r.is_finite() {
			return;
		}
		let ratio = r.clamp(0.0, 1.0);
		self.multiply(1.0 - ratio);
		let (temperature, combined_heat_capacity) =
			self.blend_temperature_and_capacity(giver, ratio);
		self.maybe_expand(giver.moles.len());
		self.moles
			.iter_mut()
			.zip(giver.moles.iter())
			.for_each(|(amount, added)| {
				*amount = (f64::from(*amount) + f64::from(*added) * f64::from(ratio))
					.min(f64::from(f32::MAX)) as f32;
			});
		self.set_temperature(temperature);
		if self.min_heat_capacity == 0.0 && giver.min_heat_capacity == 0.0 {
			self.cached_heat_capacity.set(combined_heat_capacity);
		} else {
			self.cached_heat_capacity.invalidate();
		}
	}
	/// Transfers only the given gases from us to another mix.
	pub fn transfer_gases_to(
		&mut self,
		r: f32,
		gases: &[GasIDX],
		into: &mut Self,
	) -> Result<(), MixtureValueError> {
		if self.immutable || into.immutable {
			return Ok(());
		}
		if !r.is_finite() {
			return Err(MixtureValueError::InvalidValue {
				quantity: "transfer ratio",
				class: invalid_numeric_class(r),
			});
		}
		let ratio = r.clamp(0.0, 1.0);
		let initial_heat_capacity = into.heat_capacity();
		let initial_energy = initial_heat_capacity * into.temperature;
		let initial_energy_wide = (!initial_energy.is_finite())
			.then(|| into.heat_capacity_wide() * f64::from(into.temperature));
		let mut heat_transfer = 0.0;
		let mut transfers = TinyVec::<[(GasIDX, f32); 8]>::new();
		with_specific_heats(|heats| {
			for i in gases.iter().copied() {
				// A filter selects species, even if its caller lists one more than once.
				// Keep first-occurrence order and bound scratch to distinct source species.
				if transfers.iter().any(|&(index, _)| index == i) {
					continue;
				}
				if let (Some(orig), Some(specific_heat)) = (self.moles.get(i), heats.get(i)) {
					let delta = *orig * ratio;
					heat_transfer += delta * self.temperature * specific_heat;
					transfers.push((i, delta));
				}
			}
		});
		for &(idx, delta) in &transfers {
			let adjusted = f64::from(into.get_moles(idx)) + f64::from(delta);
			if adjusted > f64::from(f32::MAX) {
				return Err(MixtureValueError::MoleOverflow { index: idx });
			}
		}
		for &(idx, delta) in &transfers {
			self.moles[idx] -= delta;
			into.adjust_moles(idx, delta)?;
		}
		self.cached_heat_capacity.invalidate();
		into.cached_heat_capacity.invalidate();
		let new_heat_capacity = into.heat_capacity();
		if new_heat_capacity > MINIMUM_HEAT_CAPACITY {
			let mut temperature = (initial_energy + heat_transfer) / new_heat_capacity;
			if !temperature.is_finite() || !new_heat_capacity.is_finite() {
				let transferred_energy = with_specific_heats(|heats| {
					transfers
						.iter()
						.map(|&(idx, delta)| {
							f64::from(delta) * f64::from(self.temperature) * f64::from(heats[idx])
						})
						.sum::<f64>()
				});
				temperature = ((initial_energy_wide.unwrap_or(f64::from(initial_energy))
					+ transferred_energy)
					/ into.heat_capacity_wide()) as f32;
			}
			into.set_temperature(temperature);
		}
		Ok(())
	}
	/// Takes a percentage of this gas mixture's moles and puts it into another mixture. if this mix is mutable, also removes those moles from the original.
	pub fn remove_ratio_into(&mut self, mut ratio: f32, into: &mut Self) {
		if !ratio.is_finite() || ratio <= 0.0 {
			return;
		}
		ratio = ratio.min(1.0);
		if into.immutable {
			return;
		}
		into.copy_from_mutable(self);
		if self.immutable {
			into.moles
				.iter_mut()
				.for_each(|amount| *amount = quantize(*amount * ratio));
			into.cached_heat_capacity.invalidate();
			into.garbage_collect();
			return;
		}
		for (source_amount, removed_amount) in self.moles.iter_mut().zip(into.moles.iter_mut()) {
			*removed_amount = quantize(*source_amount * ratio);
			*source_amount -= *removed_amount;
		}
		self.cached_heat_capacity.invalidate();
		into.cached_heat_capacity.invalidate();
		self.garbage_collect();
		into.garbage_collect();
	}
	/// As `remove_ratio_into`, but a raw number of moles instead of a ratio.
	pub fn remove_into(&mut self, amount: f32, into: &mut Self) {
		self.remove_ratio_into(self.ratio_for_amount(amount), into);
	}
	/// A convenience function that makes the mixture for `remove_ratio_into` on the spot and returns it.
	#[must_use]
	pub fn remove_ratio(&mut self, ratio: f32) -> Self {
		let mut removed = Self::from_vol(self.volume);
		self.remove_ratio_into(ratio, &mut removed);
		removed
	}
	/// Like `remove_ratio`, but with moles.
	#[must_use]
	pub fn remove(&mut self, amount: f32) -> Self {
		self.remove_ratio(self.ratio_for_amount(amount))
	}
	/// Copies from a given gas mixture, if we're mutable.
	pub fn copy_from_mutable(&mut self, sample: &Self) {
		if self.immutable {
			return;
		}
		self.moles = sample.moles.clone();
		self.temperature = sample.temperature;
		if self.min_heat_capacity == sample.min_heat_capacity {
			self.cached_heat_capacity = sample.cached_heat_capacity.clone();
		} else {
			self.cached_heat_capacity.invalidate();
		}
	}
	/// Makes a copy of this gas mixture that is guaranteed mutable, regardless of whether this one is immutable
	pub fn copy_to_mutable(&self) -> Self {
		let mut new_mix = self.clone();
		new_mix.immutable = false;
		new_mix
	}
	/// A very simple finite difference solution to the heat transfer equation.
	/// Works well enough for our purposes, though perhaps called less often
	/// than it ought to be while we're working in Rust.
	/// Differs from the original by not using archive, since we don't put the archive into the gas mix itself anymore.
	pub fn temperature_share(
		&mut self,
		sharer: &mut Self,
		conduction_coefficient: f32,
	) -> Result<f32, MixtureValueError> {
		let (ours, theirs) = self.shared_temperatures(
			conduction_coefficient,
			sharer.temperature,
			sharer.heat_capacity(),
			|| sharer.heat_capacity_wide(),
		)?;
		self.set_temperature(ours);
		sharer.set_temperature(theirs);
		Ok(sharer.temperature)
	}
	/// As above, but you may put in any arbitrary coefficient, temp, heat capacity.
	/// Only used for superconductivity as of right now.
	pub fn temperature_share_non_gas(
		&mut self,
		conduction_coefficient: f32,
		sharer_temperature: f32,
		sharer_heat_capacity: f32,
	) -> Result<f32, MixtureValueError> {
		let (ours, theirs) = self.shared_temperatures(
			conduction_coefficient,
			sharer_temperature,
			sharer_heat_capacity,
			|| f64::from(sharer_heat_capacity),
		)?;
		self.set_temperature(ours);
		Ok(theirs)
	}
	fn shared_temperatures(
		&self,
		conduction_coefficient: f32,
		sharer_temperature: f32,
		sharer_heat_capacity: f32,
		sharer_capacity_wide: impl FnOnce() -> f64,
	) -> Result<(f32, f32), MixtureValueError> {
		validate_finite(conduction_coefficient, "heat conductivity")?;
		validate_finite(sharer_temperature, "sharer temperature")?;
		if sharer_heat_capacity.is_nan() || sharer_heat_capacity < 0.0 {
			return Err(MixtureValueError::InvalidValue {
				quantity: "sharer heat capacity",
				class: invalid_numeric_class(sharer_heat_capacity),
			});
		}
		let temperature_delta = self.temperature - sharer_temperature;
		if temperature_delta.abs() > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER {
			let self_heat_capacity = self.heat_capacity();

			if sharer_heat_capacity > MINIMUM_HEAT_CAPACITY
				&& self_heat_capacity > MINIMUM_HEAT_CAPACITY
			{
				let heat = conduction_coefficient
					* temperature_delta
					* harmonic_heat_capacity(self_heat_capacity, sharer_heat_capacity);
				let mut ours = self.temperature - heat / self_heat_capacity;
				let mut theirs = sharer_temperature + heat / sharer_heat_capacity;
				if !self_heat_capacity.is_finite()
					|| !sharer_heat_capacity.is_finite()
					|| !heat.is_finite()
					|| !ours.is_finite()
					|| !theirs.is_finite()
				{
					let (wide_ours, wide_theirs) = exchange_temperatures_wide(
						self.heat_capacity_wide(),
						self.temperature,
						sharer_capacity_wide(),
						sharer_temperature,
						conduction_coefficient,
					);
					ours = wide_ours.max(f64::from(TCMB)) as f32;
					theirs = wide_theirs.max(f64::from(TCMB)) as f32;
				}
				return Ok((
					validate_finite(ours, "mixture heat-exchange temperature")?.max(TCMB),
					validate_finite(theirs, "sharer heat-exchange temperature")?.max(TCMB),
				));
			}
		}
		Ok((self.temperature, sharer_temperature))
	}
	/// The second part of old compare(). Compares temperature, but only if this gas has sufficiently high moles.
	pub fn temperature_compare(&self, sample: &Self) -> bool {
		(self.get_temperature() - sample.get_temperature()).abs()
			> MINIMUM_TEMPERATURE_DELTA_TO_SUSPEND
			&& (self.total_moles() > MINIMUM_MOLES_DELTA_TO_MOVE)
	}
	/// Returns the maximum mole delta for an individual gas.
	pub fn compare(&self, sample: &Self) -> f32 {
		self.moles
			.iter()
			.copied()
			.zip_longest(sample.moles.iter().copied())
			.fold(0.0, |acc, pair| acc.max(pair.reduce(|a, b| (b - a).abs())))
	}
	pub fn compare_with(&self, sample: &Self, amt: f32) -> bool {
		self.moles
			.as_slice()
			.iter()
			.zip_longest(sample.moles.as_slice().iter())
			.rev()
			.any(|pair| match pair {
				Left(a) => a >= &amt,
				Right(b) => b >= &amt,
				Both(a, b) => (a - b).abs() >= amt,
			})
	}
	/// Compares complete mixture state with an explicit absolute numeric tolerance.
	pub fn approx_eq(&self, other: &Self, tolerance: f32) -> bool {
		if !tolerance.is_finite() || tolerance < 0.0 || self.immutable != other.immutable {
			return false;
		}
		(self.temperature - other.temperature).abs() <= tolerance
			&& (self.volume - other.volume).abs() <= tolerance
			&& (self.min_heat_capacity - other.min_heat_capacity).abs() <= tolerance
			&& self
				.moles
				.iter()
				.copied()
				.zip_longest(other.moles.iter().copied())
				.all(|pair| pair.reduce(|left, right| (left - right).abs()) <= tolerance)
	}
	/// Clears the moles from the gas.
	pub fn clear(&mut self) {
		if !self.immutable {
			self.moles.clear();
			self.cached_heat_capacity.invalidate();
		}
	}
	/// Resets the gas mixture to an initialized-with-volume state.
	pub fn clear_with_vol(&mut self, vol: f32) {
		self.temperature = 2.7;
		self.volume = validate_volume(vol).unwrap_or(0.0);
		self.min_heat_capacity = 0.0;
		self.immutable = false;
		self.clear();
	}
	/// Multiplies every gas molage with this value.
	pub fn multiply(&mut self, multiplier: f32) {
		if !self.immutable && multiplier.is_finite() && multiplier >= 0.0 {
			self.moles.iter_mut().for_each(|amount| {
				*amount =
					(f64::from(*amount) * f64::from(multiplier)).min(f64::from(f32::MAX)) as f32;
			});
			self.cached_heat_capacity.invalidate();
			self.garbage_collect();
		}
	}
	pub fn add(&mut self, num: f32) {
		if !self.immutable && num.is_finite() {
			self.moles.iter_mut().for_each(|amount| {
				*amount =
					(f64::from(*amount) + f64::from(num)).clamp(0.0, f64::from(f32::MAX)) as f32;
			});
			self.cached_heat_capacity.invalidate();
			self.garbage_collect();
		}
	}
	pub fn can_react_with_reactions(
		&self,
		reactions: &BTreeMap<ReactionPriority, Reaction>,
	) -> bool {
		// Reaction priorities are traversed in reverse order.
		reactions
			.values()
			.rev()
			.any(|reaction| reaction.check_conditions(self))
	}
	/// Checks if the proc can react with any reactions.
	pub fn can_react(&self) -> bool {
		with_reactions(|reactions| self.can_react_with_reactions(reactions))
	}
	pub fn all_reactable_with_slice(
		&self,
		reactions: &BTreeMap<ReactionPriority, Reaction>,
	) -> TinyVec<[u64; MAX_REACTION_TINYVEC_SIZE]> {
		// Reaction priorities are traversed in reverse order.
		reactions
			.values()
			.rev()
			.filter(|thin| thin.check_conditions(self))
			.map(|thin| thin.get_id())
			.collect()
	}
	/// Gets all of the reactions this mix should do.
	pub fn all_reactable(&self) -> TinyVec<[u64; MAX_REACTION_TINYVEC_SIZE]> {
		with_reactions(|reactions| self.all_reactable_with_slice(reactions))
	}
	/// Returns a tuple with oxidation power and fuel amount of this gas mixture.
	pub fn get_burnability(&self) -> (f32, f32) {
		use crate::types::FireInfo;
		super::with_gas_info(|gas_info| {
			self.moles
				.iter()
				.zip(gas_info)
				.fold((0.0, 0.0), |mut acc, (&amt, this_gas_info)| {
					if amt > GAS_MIN_MOLES {
						match this_gas_info.fire_info {
							FireInfo::Oxidation(oxidation) => {
								if self.temperature > oxidation.temperature() {
									let amount = amt
										* (1.0 - oxidation.temperature() / self.temperature)
											.max(0.0);
									acc.0 += amount * oxidation.power();
								}
							}
							FireInfo::Fuel(fire) => {
								if self.temperature > fire.temperature() {
									let amount = amt
										* (1.0 - fire.temperature() / self.temperature).max(0.0);
									acc.1 += amount / fire.burn_rate();
								}
							}
							FireInfo::None => (),
						}
					}
					acc
				})
		})
	}
	/// Returns only the oxidation power. Since this calculates burnability anyway, prefer `get_burnability`.
	pub fn get_oxidation_power(&self) -> f32 {
		self.get_burnability().0
	}
	/// Evaluates a hypothetical temperature without modifying an immutable reservoir.
	pub fn get_oxidation_power_at_temperature(&self, temperature: f32) -> f32 {
		let mut proposed = self.copy_to_mutable();
		proposed.set_temperature(temperature);
		proposed.get_oxidation_power()
	}
	/// Returns only fuel amount. Since this calculates burnability anyway, prefer `get_burnability`.
	pub fn get_fuel_amount(&self) -> f32 {
		self.get_burnability().1
	}
	/// Like `get_fire_info`, but takes a reference to a gas info vector,
	/// so one doesn't need to do a recursive lock on the global list.
	pub fn get_fire_info_with_lock(
		&self,
		gas_info: &[super::GasType],
	) -> (Vec<SpecificFireInfo>, Vec<SpecificFireInfo>) {
		use crate::types::FireInfo;
		self.moles
			.iter()
			.zip(gas_info)
			.enumerate()
			.filter_map(|(i, (&amt, this_gas_info))| {
				(amt > GAS_MIN_MOLES)
					.then(|| match this_gas_info.fire_info {
						FireInfo::Oxidation(oxidation) => (self.get_temperature()
							> oxidation.temperature())
						.then(|| {
							let amount = amt
								* (1.0 - oxidation.temperature() / self.get_temperature()).max(0.0);
							Either::Right((i, amount, amount * oxidation.power()))
						}),
						FireInfo::Fuel(fuel) => {
							(self.get_temperature() > fuel.temperature()).then(|| {
								let amount = amt
									* (1.0 - fuel.temperature() / self.get_temperature()).max(0.0);
								Either::Left((i, amount, amount / fuel.burn_rate()))
							})
						}
						FireInfo::None => None,
					})
					.flatten()
			})
			.partition_map(|r| r)
	}
	/// Returns two vectors:
	/// The first contains all oxidizers in this list, as well as their actual mole amounts and how much fuel they can oxidize.
	/// The second contains all fuel sources in this list, as well as their actual mole amounts and how much oxidizer they can react with.
	pub fn get_fire_info(&self) -> (Vec<SpecificFireInfo>, Vec<SpecificFireInfo>) {
		super::with_gas_info(|gas_info| self.get_fire_info_with_lock(gas_info))
	}
	/// Adds heat directly to the gas mixture, in joules (probably).
	pub fn adjust_heat(&mut self, heat: f32) -> Result<(), MixtureValueError> {
		validate_finite(heat, "heat adjustment")?;
		if self.immutable {
			return Ok(());
		}
		let cap = self.heat_capacity();
		if cap <= 0.0 {
			return Ok(());
		}
		let mut temperature = ((cap * self.temperature) + heat) / cap;
		if !temperature.is_finite() {
			let capacity = self.heat_capacity_wide();
			temperature = ((capacity * f64::from(self.temperature) + f64::from(heat)) / capacity)
				.max(f64::from(TCMB)) as f32;
		}
		self.set_temperature(validate_finite(temperature, "heat-adjusted temperature")?);
		Ok(())
	}
	/// Returns true if there's a visible gas in this mix.
	pub fn is_visible(&self) -> bool {
		self.enumerate()
			.any(|(i, gas)| gas_visibility(i).is_some_and(|amt| gas >= amt))
	}
	pub fn vis_hash(&self, gas_visibility: &[Option<f32>]) -> u64 {
		use std::hash::Hasher;
		let mut hasher: ahash::AHasher = ahash::AHasher::default();

		self.enumerate()
			.filter(|&(i, gas_amt)| {
				unsafe { gas_visibility.get_unchecked(i) }
					.filter(|&amt| gas_amt > amt)
					.is_some()
			})
			.for_each(|(i, gas_amt)| {
				hasher.write_usize(i);
				hasher.write_usize(visibility_step(gas_amt) as usize)
			});
		hasher.finish()
	}
	/// Compares the current vis hash to the provided one; returns true if they are
	pub fn vis_hash_changed(
		&self,
		gas_visibility: &[Option<f32>],
		hash_holder: &AtomicU64,
	) -> bool {
		let cur_hash = self.vis_hash(gas_visibility);
		let old_hash = hash_holder.swap(cur_hash, Relaxed);
		old_hash == 0 || old_hash != cur_hash
	}
	// Removes all redundant zeroes from the gas mixture.
	pub fn garbage_collect(&mut self) {
		let mut last_valid_found = 0;
		let mut found_valid = false;
		for (i, amt) in self.moles.iter_mut().enumerate() {
			if *amt > GAS_MIN_MOLES {
				last_valid_found = i;
				found_valid = true;
			} else {
				*amt = 0.0;
			}
		}
		let retained_len = if found_valid { last_valid_found + 1 } else { 0 };
		self.moles.truncate(retained_len);
	}
}

use std::ops::{Add, Mul};

/// Takes a copy of the mix, merges the right hand side, then returns the copy.
impl Add<&Mixture> for Mixture {
	type Output = Self;

	fn add(self, rhs: &Mixture) -> Self {
		let mut ret = self.copy_to_mutable();
		ret.merge(rhs);
		ret
	}
}

/// Takes a copy of the mix, merges the right hand side, then returns the copy.
impl Add<&Mixture> for &Mixture {
	type Output = Mixture;

	fn add(self, rhs: &Mixture) -> Mixture {
		let mut ret = self.copy_to_mutable();
		ret.merge(rhs);
		ret
	}
}

/// Makes a copy of the given mix, multiplied by a scalar.
impl Mul<f32> for Mixture {
	type Output = Self;

	fn mul(self, rhs: f32) -> Self {
		let mut ret = self.copy_to_mutable();
		ret.multiply(rhs);
		ret
	}
}

/// Makes a copy of the given mix, multiplied by a scalar.
impl Mul<f32> for &Mixture {
	type Output = Mixture;

	fn mul(self, rhs: f32) -> Mixture {
		let mut ret = self.copy_to_mutable();
		ret.multiply(rhs);
		ret
	}
}

#[cfg(test)]
mod tests {
	#[test]
	fn visibility_steps_match_the_paired_overlay_inventory() {
		for (moles, expected) in [(0.25, 1), (5.0, 20), (5.25, 21), (20.0, 80), (100.0, 80)] {
			assert_eq!(super::visibility_step(moles), expected);
		}
	}

	use super::*;
	use crate::gas::{
		types::{destroy_gas_statics, register_gas_manually, set_gas_statics_manually},
		GAS_TEST_LOCK,
	};

	fn initialize_gases() {
		set_gas_statics_manually();
		register_gas_manually("o2", 20.0);
		register_gas_manually("n2", 20.0);
		register_gas_manually("n2o", 20.0);
		register_gas_manually("co2", 20.0);
	}

	#[test]
	fn large_removal_keeps_quantized_moles_finite() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut results = Vec::new();
		for immutable in [false, true] {
			let mut source = Mixture::new();
			source.set_moles(0, 1.0e35).unwrap();
			if immutable {
				source.mark_immutable();
			}
			let removed = source.remove_ratio(0.5);
			results.push((immutable, source.get_moles(0), removed.get_moles(0)));
		}
		destroy_gas_statics();
		drop(_guard);
		assert_eq!(results, [(false, 5.0e34, 5.0e34), (true, 1.0e35, 5.0e34)],);
	}

	#[test]
	fn pressure_survives_overflowed_intermediates() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut single = Mixture::from_vol(1.0e6);
		single.set_moles(0, 1.0e36).unwrap();
		single.set_temperature(300.0);
		let mut combined = Mixture::from_vol(1.0e8);
		combined.set_moles(0, 2.0e38).unwrap();
		combined.set_moles(1, 2.0e38).unwrap();
		combined.set_temperature(300.0);
		let pressures = [single.return_pressure(), combined.return_pressure()];
		destroy_gas_statics();
		drop(_guard);
		// Ideal-gas golden values; two parts per million covers f32 operand rounding.
		for (pressure, expected) in pressures.into_iter().zip([2.493e33, 9.972e33]) {
			assert!((pressure / expected - 1.0).abs() < 2.0e-6, "{pressure}");
		}
	}

	#[test]
	fn mixture_temperatures_survive_overflowed_intermediate_energy() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut cold = Mixture::new();
		cold.set_moles(0, 1.0e35).unwrap();
		cold.set_temperature(300.0);
		let mut hot = cold.clone();
		hot.set_temperature(600.0);
		let mut merged = cold.clone();
		merged.merge(&hot);
		let mut shared = cold.clone();
		shared.share_ratio(&hot, 0.5);
		let mut transferred = cold.clone();
		hot.transfer_gases_to(1.0, &[0], &mut transferred).unwrap();
		let mut empty = Mixture::new();
		cold.transfer_gases_to(1.0, &[0], &mut empty).unwrap();
		let temperatures = [
			merged.get_temperature(),
			shared.get_temperature(),
			transferred.get_temperature(),
			empty.get_temperature(),
		];
		let moles = [
			merged.get_moles(0),
			shared.get_moles(0),
			transferred.get_moles(0),
			empty.get_moles(0),
			hot.get_moles(0),
			cold.get_moles(0),
		];
		destroy_gas_statics();
		drop(_guard);
		assert_eq!(moles, [2.0e35, 1.0e35, 2.0e35, 1.0e35, 0.0, 0.0]);
		for (actual, expected) in temperatures.into_iter().zip([450.0, 450.0, 450.0, 300.0]) {
			assert!((actual - expected).abs() < 0.0001, "{temperatures:?}");
		}
	}

	#[test]
	fn selective_transfer_capacity_overflow_preserves_weighted_temperature() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut source = Mixture::new();
		source.set_moles(0, 1.0e37).unwrap();
		source.set_temperature(600.0);
		let mut destination = source.clone();
		destination.set_temperature(300.0);
		source
			.transfer_gases_to(1.0, &[0], &mut destination)
			.unwrap();
		let temperature = destination.get_temperature();
		destroy_gas_statics();
		drop(_guard);
		// Each source capacity fits f32; the combined capacity does not.
		assert!((temperature - 450.0).abs() < 0.0001, "{temperature}");
	}

	fn mixture_at(amount: f32, temperature: f32) -> Mixture {
		let mut mixture = Mixture::new();
		mixture.set_moles(0, amount).unwrap();
		mixture.set_temperature(temperature);
		mixture
	}

	#[test]
	fn aggregate_capacity_preserves_blend_and_transfer_temperatures() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let cold = mixture_at(1.0e38, 300.0);
		let hot = mixture_at(1.0e38, 600.0);
		let mut merged = cold.clone();
		merged.merge(&hot);
		let mut shared = cold.clone();
		shared.share_ratio(&hot, 0.5);
		let mut source = hot.clone();
		let mut destination = cold.clone();
		source
			.transfer_gases_to(1.0, &[0], &mut destination)
			.unwrap();
		let mut zero_share = mixture_at(10.0, 300.0);
		zero_share.share_ratio(&hot, 0.0);
		let results = [
			merged.temperature,
			shared.temperature,
			destination.temperature,
		];
		let zero_result = (zero_share.temperature, zero_share.heat_capacity());
		let transferred_moles = (source.get_moles(0), destination.get_moles(0));
		destroy_gas_statics();
		drop(_guard);
		assert_eq!(transferred_moles, (0.0, 2.0e38));
		assert_eq!(zero_result, (300.0, 200.0));
		for temperature in results {
			assert!((temperature - 450.0).abs() < 0.0001, "{results:?}");
		}
	}

	#[test]
	fn aggregate_moles_allow_amount_based_removal() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut source = mixture_at(2.0e38, 300.0);
		source.set_moles(1, 2.0e38).unwrap();
		let removed = source.remove(1.0e38);
		let result = [
			source.get_moles(0),
			source.get_moles(1),
			removed.get_moles(0),
			removed.get_moles(1),
		];
		destroy_gas_statics();
		drop(_guard);
		for (actual, expected) in result.into_iter().zip([1.5e38, 1.5e38, 5.0e37, 5.0e37]) {
			assert!((actual / expected - 1.0).abs() < 2.0e-6, "{result:?}");
		}
	}

	#[test]
	fn aggregate_capacity_and_energy_allow_heat_exchange() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut results = Vec::new();
		for amount in [1.0e35, 1.0e38] {
			let mut hot = mixture_at(amount, 900.0);
			let mut cold = mixture_at(amount, 300.0);
			hot.temperature_share(&mut cold, 1.0).unwrap();
			results.push((hot.temperature, cold.temperature));
		}
		let mut hot = mixture_at(1.0e35, 900.0);
		let external = hot.temperature_share_non_gas(1.0, 300.0, 2.0e36).unwrap();
		results.push((hot.temperature, external));
		let mut reservoir_gas = mixture_at(1.0e38, 900.0);
		let reservoir = reservoir_gas
			.temperature_share_non_gas(0.4, 300.0, f32::INFINITY)
			.unwrap();
		destroy_gas_statics();
		drop(_guard);
		for &(hot, cold) in &results {
			assert!(
				(hot - 600.0).abs() < 0.0001 && (cold - 600.0).abs() < 0.0001,
				"{results:?}"
			);
		}
		assert!((reservoir_gas.temperature - 660.0).abs() < 0.0001);
		assert_eq!(reservoir, 300.0);
	}

	#[test]
	fn aggregate_capacity_and_energy_allow_heat_adjustment() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut results = Vec::new();
		for (amount, heat, expected) in [
			(1.0e35, 2.0e38, 400.0),
			(1.0e35, -2.0e38, 200.0),
			(2.0e37, 2.0e38, 300.5),
			(2.0e37, -2.0e38, 299.5),
		] {
			let mut mixture = mixture_at(amount, 300.0);
			mixture.adjust_heat(heat).unwrap();
			results.push((mixture.temperature, expected));
		}
		destroy_gas_statics();
		drop(_guard);
		for &(actual, expected) in &results {
			assert!((actual - expected).abs() < 0.0001, "{results:?}");
		}
	}

	#[test]
	fn heat_updates_reject_invalid_or_unrepresentable_results_before_mutation() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut hot = mixture_at(1.0, f32::MAX);
		let mut cold = mixture_at(1.0, 300.0);
		let mut rejected = vec![hot.temperature_share(&mut cold, f32::MAX).is_err()];
		for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
			rejected.push(hot.temperature_share(&mut cold, invalid).is_err());
		}
		for (temperature, capacity) in [(f32::NAN, 20.0), (300.0, f32::NAN), (300.0, -1.0)] {
			rejected.push(
				cold.temperature_share_non_gas(1.0, temperature, capacity)
					.is_err(),
			);
		}
		let mut small = mixture_at(0.001, 300.0);
		rejected.push(small.adjust_heat(f32::MAX).is_err());
		rejected.push(small.adjust_heat(f32::NAN).is_err());
		let unchanged = (hot.temperature, cold.temperature, small.temperature);
		small.adjust_heat(-f32::MAX).unwrap();
		destroy_gas_statics();
		drop(_guard);
		assert!(rejected.into_iter().all(|rejected| rejected));
		assert_eq!(unchanged, (f32::MAX, 300.0, 300.0));
		assert_eq!(small.temperature, TCMB);
	}

	#[test]
	fn heat_exchange_preserves_immutable_and_zero_capacity_cases() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut results = Vec::new();
		for (immutable_hot, immutable_cold) in [(true, false), (false, true), (true, true)] {
			let mut hot = mixture_at(1.0e38, 900.0);
			let mut cold = mixture_at(1.0e38, 300.0);
			if immutable_hot {
				hot.mark_immutable();
			}
			if immutable_cold {
				cold.mark_immutable();
			}
			let returned = hot.temperature_share(&mut cold, 1.0).unwrap();
			results.push((hot.temperature, if immutable_hot { 900.0 } else { 600.0 }));
			results.push((cold.temperature, if immutable_cold { 300.0 } else { 600.0 }));
			results.push((returned, cold.temperature));
		}
		let mut empty = Mixture::new();
		empty.adjust_heat(2.0e38).unwrap();
		let mut hot = mixture_at(1.0e38, 900.0);
		empty.temperature_share(&mut hot, 1.0).unwrap();
		results.extend([(empty.temperature, TCMB), (hot.temperature, 900.0)]);
		destroy_gas_statics();
		drop(_guard);
		for &(actual, expected) in &results {
			assert!((actual - expected).abs() < 0.0001, "{results:?}");
		}
	}

	#[test]
	fn cached_heat_capacity_respects_destination_floor_after_mixture_operations() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		type Operation = fn(&mut Mixture, &Mixture);
		let operations: [(&str, Operation, f32, f32); 3] = [
			("copy", Mixture::copy_from_mutable, 1.0, 20.0),
			("merge", Mixture::merge, 2.0, 40.0),
			("share", |src, giver| src.share_ratio(giver, 0.5), 1.0, 20.0),
		];
		let mut mismatches = Vec::new();
		for (name, operation, expected_moles, gas_capacity) in operations {
			for (source_floor, giver_floor, expected_capacity) in [
				(100.0, 0.0, 100.0),
				(0.0, 100.0, gas_capacity),
				(100.0, 300.0, 100.0),
				(10.0, 10.0, gas_capacity),
			] {
				let mut source = Mixture::new();
				source.set_moles(0, 1.0).unwrap();
				source.set_temperature(300.0);
				source.set_min_heat_capacity(source_floor);
				let mut giver = source.clone();
				giver.set_min_heat_capacity(giver_floor);
				// Warm both caches before mutation; uncomputed caches hide the copy defect.
				source.heat_capacity();
				giver.heat_capacity();
				operation(&mut source, &giver);
				assert_eq!(source.get_moles(0), expected_moles);
				let cached = source.heat_capacity();
				source.set_moles(0, expected_moles).unwrap();
				let recalculated = source.heat_capacity();
				if cached != expected_capacity || recalculated != expected_capacity {
					mismatches.push((
						name,
						source_floor,
						giver_floor,
						cached,
						recalculated,
						expected_capacity,
					));
				}
			}
		}
		destroy_gas_statics();
		assert!(
			mismatches.is_empty(),
			"stale mixture heat capacities: {mismatches:?}"
		);
	}

	#[test]
	fn selective_transfer_treats_repeated_gas_ids_as_one_selection() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut source = Mixture::new();
		source.set_moles(0, 10.0).unwrap();
		source.set_moles(1, 5.0).unwrap();
		source.set_temperature(400.0);
		let mut destination = Mixture::new();
		destination.set_moles(0, 2.0).unwrap();
		destination.set_moles(1, 1.0).unwrap();
		destination.set_temperature(200.0);
		source
			.transfer_gases_to(0.75, &[1, 0, 1, 0], &mut destination)
			.unwrap();
		assert_eq!((source.get_moles(0), source.get_moles(1)), (2.5, 1.25));
		assert_eq!(
			(destination.get_moles(0), destination.get_moles(1)),
			(9.5, 4.75)
		);
		// 3 mol at 200 K plus 11.25 mol at 400 K, with specific heat 20 J/(mol K).
		assert!((destination.get_temperature() - 357.89474).abs() < 0.0001);
		assert_eq!(source.get_temperature(), 400.0);
		assert!(!source.is_corrupt());
		assert!(!destination.is_corrupt());
		destroy_gas_statics();
	}

	#[test]
	fn selective_transfer_preflights_all_unique_gases_before_mutation() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		destroy_gas_statics();
		initialize_gases();
		let mut source = Mixture::new();
		source.set_moles(0, 10.0).unwrap();
		source.set_moles(1, 1.0e38).unwrap();
		let mut destination = Mixture::new();
		destination.set_moles(0, 5.0).unwrap();
		destination.set_moles(1, 3.0e38).unwrap();
		assert_eq!(
			source.transfer_gases_to(0.5, &[0, 1, 0], &mut destination),
			Err(MixtureValueError::MoleOverflow { index: 1 }),
		);
		assert_eq!((source.get_moles(0), source.get_moles(1)), (10.0, 1.0e38));
		assert_eq!(
			(destination.get_moles(0), destination.get_moles(1)),
			(5.0, 3.0e38)
		);
		destroy_gas_statics();
	}

	#[test]
	fn test_gases() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		let mut minimum_capacity = Mixture::new();
		assert_eq!(minimum_capacity.heat_capacity(), 0.0);
		minimum_capacity.set_min_heat_capacity(10.0);
		assert_eq!(minimum_capacity.heat_capacity(), 10.0);
		minimum_capacity.set_min_heat_capacity(20.0);
		assert_eq!(minimum_capacity.heat_capacity(), 20.0);
		minimum_capacity.set_min_heat_capacity(f32::NAN);
		assert_eq!(minimum_capacity.heat_capacity(), 20.0);

		let mut hot_capacity = Mixture::new();
		hot_capacity.set_min_heat_capacity(1e20);
		hot_capacity.set_temperature(1000.0);
		let mut cold_capacity = Mixture::new();
		cold_capacity.set_min_heat_capacity(1e20);
		cold_capacity.set_temperature(300.0);
		hot_capacity
			.temperature_share(&mut cold_capacity, 1.0)
			.unwrap();
		assert!((hot_capacity.get_temperature() - 650.0).abs() < 0.01);
		assert!((cold_capacity.get_temperature() - 650.0).abs() < 0.01);

		let mut into = Mixture::new();
		into.set_moles(0, 82.0).unwrap();
		into.set_moles(1, 22.0).unwrap();
		into.set_temperature(293.15);
		let mut source = Mixture::new();
		source.set_moles(2, 100.0).unwrap();
		source.set_temperature(313.15);
		into.merge(&source);
		// make sure that the merge successfuly moved the moles
		assert_eq!(into.get_moles(2), 100.0);
		assert_eq!(source.get_moles(2), 100.0); // source is not modified by merge
										  /*
										  make sure that the merge successfuly changed the temperature of the mix merged into:
										  test gases have heat capacities of (82 * 20 + 22 * 20) and (100 * 20) respectively, so total thermal energies of
										  (82 * 20 + 22 * 20) * 293.15 and (100 * 20) * 313.15 respectively once multiplied by temperatures. add those together,
										  then divide by new total heat capacity:
										  (609,752 + 626,300)/(2,080 + 2,000) =
										  ~
										  302.953
										  so we compare to see if it's relatively close to 302.953, cause of floating point precision
										  */
		assert!(
			(into.get_temperature() - 302.953).abs() < 0.01,
			"{} should be near 302.953, is {}",
			into.get_temperature(),
			(into.get_temperature() - 302.953)
		);

		// test merges
		// also tests multiply, copy_from_mutable
		let mut removed = Mixture::new();
		removed.set_moles(0, 22.0).unwrap();
		removed.set_moles(1, 82.0).unwrap();
		let new = removed.remove_ratio(0.5);
		assert!(removed.compare(&new) < MINIMUM_MOLES_DELTA_TO_MOVE);
		assert_eq!(removed.get_moles(0), 11.0);
		assert_eq!(removed.get_moles(1), 41.0);
		removed.mark_immutable();
		let new_two = removed.remove_ratio(0.5);
		assert!(removed.compare(&new_two) >= MINIMUM_MOLES_DELTA_TO_MOVE);
		assert_eq!(removed.get_moles(0), 11.0);
		assert_eq!(removed.get_moles(1), 41.0);
		assert_eq!(new_two.get_moles(0), 5.5);

		let mut quantized = Mixture::new();
		quantized.set_moles(0, 1.23456).unwrap();
		let quantized_removed = quantized.remove_ratio(0.5);
		let expected_removed = 0.6173;
		assert!((quantized_removed.get_moles(0) - expected_removed).abs() < 1e-6);
		assert!((quantized.get_moles(0) - (1.23456 - expected_removed)).abs() < 1e-6);

		let mut immutable_source = Mixture::new();
		immutable_source.set_moles(0, 10.0).unwrap();
		immutable_source.mark_immutable();
		let mut transfer_target = Mixture::new();
		immutable_source
			.transfer_gases_to(1.0, &[0], &mut transfer_target)
			.unwrap();
		assert_eq!(immutable_source.get_moles(0), 10.0);
		assert_eq!(transfer_target.get_moles(0), 0.0);

		let mut transfer_source = Mixture::new();
		transfer_source.set_moles(0, 10.0).unwrap();
		let mut immutable_target = Mixture::new();
		immutable_target.mark_immutable();
		transfer_source
			.transfer_gases_to(1.0, &[0], &mut immutable_target)
			.unwrap();
		assert_eq!(transfer_source.get_moles(0), 10.0);
		assert_eq!(immutable_target.get_moles(0), 0.0);

		let mut empty = Mixture::new();
		empty.set_moles(0, 0.0).unwrap();
		empty.garbage_collect();
		assert_eq!(empty.enumerate().count(), 0);
		empty.volume = 0.0;
		assert_eq!(empty.return_pressure(), 0.0);
		destroy_gas_statics();
	}

	#[test]
	fn set_temperature_clamps_to_cosmic_microwave_background() {
		let mut mixture = Mixture::new();

		mixture.set_temperature(-100.0);

		assert_eq!(mixture.get_temperature(), TCMB);
	}

	#[test]
	fn sub_centimole_gas_survives_active_merge_split_and_transfer() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();

		let mut first = Mixture::new();
		first.set_moles(0, 0.005).unwrap();
		let mut second = Mixture::new();
		second.set_moles(0, 0.005).unwrap();
		first.merge(&second);
		assert!((first.get_moles(0) - 0.01).abs() < 1e-6);

		let mut trace = Mixture::new();
		trace.set_moles(0, 0.0099).unwrap();
		let split = trace.remove_ratio(0.5);
		assert!((split.get_moles(0) - 0.005).abs() < 1e-6);
		assert!((trace.get_moles(0) + split.get_moles(0) - 0.0099).abs() < 1e-6);

		let mut source = Mixture::new();
		source.set_moles(0, 0.0075).unwrap();
		source.set_temperature(400.0);
		let energy_before = source.thermal_energy();
		let mut destination = Mixture::new();
		source
			.transfer_gases_to(1.0, &[0], &mut destination)
			.unwrap();
		assert_eq!(source.get_moles(0), 0.0);
		assert!((destination.get_moles(0) - 0.0075).abs() < 1e-6);
		assert!((destination.thermal_energy() - energy_before).abs() < 1e-3);

		destroy_gas_statics();
	}

	#[test]
	fn validators_reject_invalid_moles_and_volumes() {
		for invalid in [-1.0, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
			assert!(validate_mole_amount(invalid).is_err());
		}
		for invalid in [-1.0, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
			assert!(validate_volume(invalid).is_err());
		}
		assert_eq!(validate_mole_amount(0.0).unwrap(), 0.0);
		assert_eq!(validate_mole_amount(f32::MIN_POSITIVE / 2.0).unwrap(), 0.0);
		assert_eq!(validate_volume(0.0).unwrap(), 0.0);
	}

	#[test]
	fn mutators_reject_invalid_values_and_preserve_immutable_mixtures() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		let mut mixture = Mixture::new();
		mixture.set_moles(0, 5.0).unwrap();
		for invalid in [-1.0, f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
			assert!(mixture.set_moles(0, invalid).is_err());
			assert_eq!(mixture.get_moles(0), 5.0);
		}
		for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
			assert!(mixture.adjust_moles(0, invalid).is_err());
			assert_eq!(mixture.get_moles(0), 5.0);
		}
		mixture.adjust_moles(0, -10.0).unwrap();
		assert_eq!(mixture.get_moles(0), 0.0);
		mixture.set_moles(0, f32::MIN_POSITIVE / 2.0).unwrap();
		assert_eq!(mixture.enumerate().count(), 0);
		mixture.set_moles(0, 5.0).unwrap();
		mixture.mark_immutable();
		mixture.set_moles(0, 10.0).unwrap();
		mixture.adjust_moles(0, 10.0).unwrap();
		assert_eq!(mixture.get_moles(0), 5.0);
		destroy_gas_statics();
	}

	#[test]
	fn corruption_repair_restores_lawful_state() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		let mut mixture = Mixture::new();
		mixture.temperature = f32::NAN;
		mixture.volume = -5.0;
		mixture.moles = [1.0, -1.0, f32::INFINITY, f32::NAN].into_iter().collect();
		assert!(mixture.is_corrupt());
		mixture.fix_corruption();
		assert!(!mixture.is_corrupt());
		assert_eq!(mixture.volume, 0.0);
		assert!(mixture
			.enumerate()
			.all(|(_, amount)| amount.is_finite() && amount >= 0.0));
		destroy_gas_statics();
	}

	#[test]
	fn approximate_equality_is_explicit_and_tolerant_of_trailing_zeroes() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		let mut left = Mixture::new();
		let mut right = Mixture::new();
		left.set_moles(0, 1.0).unwrap();
		right.set_moles(0, 1.000_001).unwrap();
		right.set_moles(1, 0.0).unwrap();
		assert!(left.approx_eq(&right, 0.000_01));
		assert!(!left.approx_eq(&right, 0.000_000_1));
		assert!(!left.approx_eq(&right, f32::NAN));
		destroy_gas_statics();
	}

	#[test]
	fn generated_operations_preserve_lawful_state_and_moles() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		initialize_gases();
		for case in 1..=128_u32 {
			let mut source = Mixture::new();
			let mut target = Mixture::new();
			for gas in 0..3 {
				let source_amount = ((case * (gas as u32 + 3)) % 97) as f32 / 3.0;
				let target_amount = ((case * (gas as u32 + 7)) % 89) as f32 / 5.0;
				source.set_moles(gas, source_amount).unwrap();
				target.set_moles(gas, target_amount).unwrap();
			}
			let before = source.total_moles() + target.total_moles();
			let ratio = (case % 101) as f32 / 100.0;
			let removed = source.remove_ratio(ratio);
			target.merge(&removed);
			let after = source.total_moles() + target.total_moles();
			let tolerance = 1e-5_f32.max(before * 1e-5);
			assert!((before - after).abs() <= tolerance, "case {case}");
			assert!(source
				.enumerate()
				.chain(target.enumerate())
				.all(|(_, amount)| amount.is_finite() && amount >= 0.0));

			let transfer_before = source.total_moles() + target.total_moles();
			source
				.transfer_gases_to(ratio, &[0, 1, 2], &mut target)
				.unwrap();
			let transfer_after = source.total_moles() + target.total_moles();
			let transfer_tolerance = 1e-5_f32.max(transfer_before * 1e-5);
			assert!(
				(transfer_before - transfer_after).abs() <= transfer_tolerance,
				"transfer case {case}"
			);
			assert!(source
				.enumerate()
				.chain(target.enumerate())
				.all(|(_, amount)| amount.is_finite() && amount >= 0.0));
		}
		destroy_gas_statics();
	}
}
