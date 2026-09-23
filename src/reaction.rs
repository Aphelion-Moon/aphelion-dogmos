#[cfg(feature = "citadel_reactions")]
mod citadel;

#[cfg(feature = "yogs_reactions")]
mod yogs;

#[cfg(feature = "aphelion_reactions")]
mod aphelion;

use crate::{
	ffi::OwnedByondValue,
	gas::{gas_idx_from_string, GasIDX, Mixture},
};
use byondapi::prelude::*;
use eyre::{Context, Result};
use float_ord::FloatOrd;
use hashbrown::HashMap;
use rustc_hash::FxBuildHasher;
use std::{
	cell::{Cell, RefCell},
	hash::{Hash, Hasher},
	rc::Rc,
};

pub type ReactionPriority = FloatOrd<f32>;
pub type ReactionIdentifier = u64;

#[derive(Clone, Debug)]
pub struct Reaction {
	id: ReactionIdentifier,
	priority: ReactionPriority,
	min_temp_req: Option<f32>,
	max_temp_req: Option<f32>,
	min_ener_req: Option<f32>,
	min_fire_req: Option<f32>,
	min_gas_reqs: Vec<(GasIDX, f32)>,
}

type ReactFunc = fn(ByondValue, ByondValue) -> Result<ByondValue>;

#[derive(Clone)]
pub(crate) enum ReactionSide {
	ByondSide(Rc<OwnedByondValue>),
	RustSide(ReactFunc),
}

thread_local! {
	// Keep the source id beside each reaction so profiling can report a readable name without a
	// second lookup table.
	static REACTION_VALUES: RefCell<HashMap<ReactionIdentifier, (ReactionSide, String), FxBuildHasher>> = Default::default();
	static DISPATCH_DEPTH: Cell<usize> = const { Cell::new(0) };
}

pub(crate) struct ReactionDispatch;

impl ReactionDispatch {
	pub(crate) fn begin() -> Self {
		DISPATCH_DEPTH.with(|depth| depth.set(depth.get() + 1));
		Self
	}
}

impl Drop for ReactionDispatch {
	fn drop(&mut self) {
		DISPATCH_DEPTH.with(|depth| depth.set(depth.get() - 1));
	}
}

pub(crate) fn ensure_registry_idle() -> Result<()> {
	if DISPATCH_DEPTH.with(Cell::get) != 0 {
		return Err(eyre::eyre!(
			"Cannot replace the Dogmos reaction registry during active dispatch"
		));
	}
	Ok(())
}

pub(crate) type ReactionValues = HashMap<ReactionIdentifier, (ReactionSide, String), FxBuildHasher>;

/// Swap the dispatch table without releasing old BYOND references yet. The caller
/// must publish the matching eligibility table before dropping the returned map.
pub(crate) fn publish_reaction_values(values: ReactionValues) -> ReactionValues {
	REACTION_VALUES.with_borrow_mut(|current| std::mem::replace(current, values))
}

/// Runs a reaction given a `ReactionIdentifier`. Returns the result of the reaction, error or success.
/// # Errors
/// If the reaction itself has a runtime.
pub fn react_by_id(
	id: ReactionIdentifier,
	src: ByondValue,
	holder: ByondValue,
) -> Result<ByondValue> {
	let _dispatch = ReactionDispatch::begin();
	let reaction = REACTION_VALUES
		.with_borrow(|r| r.get(&id).cloned())
		.ok_or_else(|| eyre::eyre!("Reaction with invalid id"))?;
	match reaction.0 {
		ReactionSide::ByondSide(val) => val
			.call_id(byond_string!("react"), &[src, holder])
			.wrap_err("calling byond side react in react_by_id"),
		ReactionSide::RustSide(func) => {
			func(src, holder).wrap_err("calling rust side react in react_by_id")
		}
	}
}

/// Returns the source id for profiling, or `None` for an invalid reaction id.
pub fn reaction_name_by_id(id: ReactionIdentifier) -> Option<String> {
	REACTION_VALUES.with_borrow(|r| r.get(&id).map(|(_side, name)| name.clone()))
}

/// Bounded current-state explanation using the same eligibility predicate as execution.
pub(crate) fn explain(mix: &Mixture) -> Vec<(String, &'static str, f32, bool, String)> {
	crate::gas::with_reactions(|reactions| {
		reactions
			.values()
			.rev()
			.take(128)
			.map(|reaction| {
				let (name, implementation) = REACTION_VALUES.with_borrow(|values| {
					values.get(&reaction.id).map_or(
						("unknown".into(), "unavailable"),
						|(side, name)| {
							(
								name.clone(),
								match side {
									ReactionSide::ByondSide(_) => "DM",
									ReactionSide::RustSide(_) => "native",
								},
							)
						},
					)
				});
				let mut detail = Vec::new();
				if let Some(value) = reaction.min_temp_req {
					detail.push(format!(
						"temperature >= {value} K (actual {})",
						mix.get_temperature()
					));
				}
				if let Some(value) = reaction.max_temp_req {
					detail.push(format!(
						"temperature <= {value} K (actual {})",
						mix.get_temperature()
					));
				}
				if let Some(value) = reaction.min_ener_req {
					detail.push(format!(
						"energy >= {value} J (actual {})",
						mix.thermal_energy()
					));
				}
				if let Some(value) = reaction.min_fire_req {
					let (oxidizer, fuel) = mix.get_burnability();
					detail.push(format!(
						"fire reagents >= {value} (actual {})",
						oxidizer.min(fuel)
					));
				}
				for &(index, value) in &reaction.min_gas_reqs {
					let gas = crate::gas::with_gas_info(|info| info[index].id.clone());
					detail.push(format!(
						"{gas} >= {value} mol (actual {})",
						mix.get_moles(index)
					));
				}
				(
					name,
					implementation,
					reaction.priority.0,
					reaction.check_conditions(mix),
					detail.join("; "),
				)
			})
			.collect()
	})
}

pub(crate) fn clear_reaction_values() -> ReactionValues {
	REACTION_VALUES.with_borrow_mut(std::mem::take)
}

#[cfg(test)]
pub(crate) fn install_test_reaction_value(
	id: ReactionIdentifier,
	name: &str,
	byond_side: bool,
) -> Reaction {
	fn rust_reaction(_src: ByondValue, _holder: ByondValue) -> Result<ByondValue> {
		Ok(ByondValue::null())
	}

	let side = if byond_side {
		ReactionSide::ByondSide(Rc::new(OwnedByondValue::adopt(ByondValue::null())))
	} else {
		ReactionSide::RustSide(rust_reaction)
	};
	REACTION_VALUES.with_borrow_mut(|values| {
		values.insert(id, (side, name.into()));
	});
	Reaction {
		id,
		priority: FloatOrd(id as f32),
		min_temp_req: None,
		max_temp_req: None,
		min_ener_req: None,
		min_fire_req: None,
		min_gas_reqs: Vec::new(),
	}
}

impl Reaction {
	/// Takes a `/datum/gas_reaction` and makes a byond reaction out of it.
	pub(crate) fn from_byond_reaction(
		reaction: OwnedByondValue,
	) -> Result<(Self, ReactionSide, String)> {
		let priority = FloatOrd(
			reaction
				.read_number_id(byond_string!("priority"))
				.map_err(|_| eyre::eyre!("Reaction priority must be a number!"))?,
		);
		let id_value = OwnedByondValue::adopt(
			reaction
				.read_var_id(byond_string!("id"))
				.map_err(|_| eyre::eyre!("Reaction id must be a string!"))?,
		);
		let string_id = id_value
			.get_string()
			.map_err(|_| eyre::eyre!("Reaction id must be a string!"))?;
		if !priority.0.is_finite() || string_id.is_empty() {
			return Err(eyre::eyre!(
				"Reaction id must be nonempty and priority finite"
			));
		}
		let func = {
			#[cfg(feature = "citadel_reactions")]
			{
				citadel::func_from_id(string_id.as_str())
			}
			#[cfg(feature = "yogs_reactions")]
			{
				yogs::func_from_id(string_id.as_str())
			}
			#[cfg(feature = "aphelion_reactions")]
			{
				aphelion::func_from_id(string_id.as_str())
			}
			#[cfg(not(any(
				feature = "aphelion_reactions",
				feature = "citadel_reactions",
				feature = "yogs_reactions",
			)))]
			{
				None
			}
		};

		let id = {
			let mut state = rustc_hash::FxHasher::default();
			string_id.as_bytes().hash(&mut state);
			state.finish()
		};

		let our_reaction = {
			let min_reqs = reaction
				.read_var_id(byond_string!("min_requirements"))
				.ok()
				.map(OwnedByondValue::adopt)
				.filter(|value| value.is_list());
			if let Some(min_reqs) = min_reqs {
				let mut min_gas_reqs: Vec<(GasIDX, f32)> = Vec::new();
				let mut min_temp_req = None;
				let mut max_temp_req = None;
				let mut min_ener_req = None;
				let mut min_fire_req = None;
				for (key, amount) in min_reqs.iter()? {
					let key = OwnedByondValue::adopt(key);
					let amount = OwnedByondValue::adopt(amount);
					let key = key.get_string().wrap_err_with(|| {
						format!("Reaction {string_id} requirement key must be a string")
					})?;
					let amount = amount.get_number().wrap_err_with(|| {
						format!("Reaction {string_id} requirement {key} must be numeric")
					})?;
					if !amount.is_finite() || amount < 0.0 {
						return Err(eyre::eyre!("Reaction {string_id} requirement {key} must be finite and non-negative"));
					}
					match key.as_str() {
						"TEMP" => min_temp_req = Some(amount),
						"MAX_TEMP" => max_temp_req = Some(amount),
						"ENER" => min_ener_req = Some(amount),
						"FIRE_REAGENTS" => min_fire_req = Some(amount),
						_ => {
							let index = gas_idx_from_string(&key).wrap_err_with(|| {
								format!("Reaction {string_id} has unsupported requirement {key}")
							})?;
							min_gas_reqs.push((index, amount));
						}
					}
				}
				if min_temp_req
					.zip(max_temp_req)
					.is_some_and(|(min, max)| min > max)
				{
					return Err(eyre::eyre!(
						"Reaction {string_id} has inverted temperature bounds"
					));
				}
				Ok(Reaction {
					id,
					priority,
					min_temp_req,
					max_temp_req,
					min_ener_req,
					min_fire_req,
					min_gas_reqs,
				})
			} else {
				Err(eyre::eyre!(format!(
					"Reaction {string_id} doesn't have a gas requirements list!"
				)))
			}
		}?;

		let side = match func {
			Some(function) => ReactionSide::RustSide(function),
			None => ReactionSide::ByondSide(Rc::new(reaction)),
		};
		Ok((our_reaction, side, string_id))
	}
	/// Gets the reaction's identifier.
	#[must_use]
	pub fn get_id(&self) -> ReactionIdentifier {
		self.id
	}
	/// Checks if the given gas mixture can react with this reaction.
	pub fn check_conditions(&self, mix: &Mixture) -> bool {
		self.min_temp_req
			.is_none_or(|temp_req| mix.get_temperature() >= temp_req)
			&& self
				.max_temp_req
				.is_none_or(|temp_req| mix.get_temperature() <= temp_req)
			&& self
				.min_gas_reqs
				.iter()
				.all(|&(k, v)| mix.get_moles(k) >= v)
			&& self
				.min_ener_req
				.is_none_or(|ener_req| mix.thermal_energy() >= ener_req)
			&& self.min_fire_req.is_none_or(|fire_req| {
				let (oxi, fuel) = mix.get_burnability();
				oxi.min(fuel) >= fire_req
			})
	}
	/// Returns the priority of the reaction.
	#[must_use]
	pub fn get_priority(&self) -> ReactionPriority {
		self.priority
	}
	/// Calls the reaction with the given arguments.
	/// # Errors
	/// If the reaction itself has a runtime error, this will propagate it up.
	pub fn react(&self, src: ByondValue, holder: ByondValue) -> Result<ByondValue> {
		react_by_id(self.id, src, holder)
	}
}

#[cfg(test)]
mod dispatch_tests {
	use super::*;
	use crate::gas::{
		types::{destroy_gas_statics, register_gas_manually, set_gas_statics_manually},
		GAS_TEST_LOCK,
	};
	use std::collections::BTreeMap;

	fn probe_during_dispatch(_src: ByondValue, _holder: ByondValue) -> Result<ByondValue> {
		assert!(ensure_registry_idle().is_err());
		assert_eq!(reaction_name_by_id(17).as_deref(), Some("probe"));
		Ok(ByondValue::null())
	}

	#[test]
	fn rust_dispatch_releases_registry_borrow_but_blocks_replacement() {
		let mut values = ReactionValues::default();
		values.insert(
			17,
			(
				ReactionSide::RustSide(probe_during_dispatch),
				"probe".into(),
			),
		);
		publish_reaction_values(values);
		assert!(react_by_id(17, ByondValue::null(), ByondValue::null()).is_ok());
		assert!(ensure_registry_idle().is_ok());
		clear_reaction_values();
	}

	#[test]
	fn reaction_chain_uses_starting_eligibility_snapshot() {
		let _guard = GAS_TEST_LOCK.lock().unwrap();
		set_gas_statics_manually();
		register_gas_manually("o2", 20.0);
		register_gas_manually("n2", 20.0);
		let mut mix = Mixture::new();
		mix.set_moles(0, 1.0).unwrap();
		let mut reactions = BTreeMap::new();
		for (id, gas_index) in [(17, 0), (18, 1)] {
			reactions.insert(
				FloatOrd(id as f32),
				Reaction {
					id,
					priority: FloatOrd(id as f32),
					min_temp_req: None,
					max_temp_req: None,
					min_ener_req: None,
					min_fire_req: None,
					min_gas_reqs: vec![(gas_index, 1.0)],
				},
			);
		}
		let starting_chain = mix.all_reactable_with_slice(&reactions);
		assert_eq!(starting_chain.as_slice(), &[17]);
		mix.set_moles(0, 0.0).unwrap();
		mix.set_moles(1, 1.0).unwrap();
		assert_eq!(starting_chain.as_slice(), &[17]);
		assert_eq!(mix.all_reactable_with_slice(&reactions).as_slice(), &[18]);
		destroy_gas_statics();
	}
}
