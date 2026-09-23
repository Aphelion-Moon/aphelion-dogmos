//! Experimental Meridian mixture-fusion profile v1. Default-off integration only.
//! The chaotic map is adapted from the retained Citadel/V6 implementation at
//! d82f95abc447ac5ef152a91d1f841f1ff2f7cd88. Energy response is deliberately bounded;
//! these commissioning values are not a qualified player recipe.

macro_rules! profile {
	($($name:ident = $value:expr;)*) => {
		$(pub const $name: f64 = $value;)*
		pub fn dm_defines() -> String {
			let mut output = String::new();
			$(output.push_str(&format!("#define DOGMOS_FUSION_{} {}\n", stringify!($name), $name));)*
			output
		}
	};
}

profile! {
	PROFILE_VERSION = 1.0;
	MIN_MOLES = 250.0;
	MIN_TEMPERATURE = 10000.0;
	MAX_TEMPERATURE = 100000000.0;
	MAX_VOLUME = 1000000.0;
	MAX_MOLES = 1000000000.0;
	STEP_DECISECONDS = 20.0;
	FUEL_PER_STEP = 1.0;
	TOROID_THRESHOLD = 5.96;
	GAS_POWER_FACTOR = 3.0;
	BINDING_ENERGY = 20000000.0;
	ENDOTHERMAL_THRESHOLD = 2.0;
	WASTE_COEFFICIENT = 0.002;
	SCALE_DIVISOR = 10.0;
	MIN_SCALE = 50.0;
	BASE_TEMP_SCALE = 6.0;
	SLOPE_DIVISOR = 1250.0;
	MAX_ENERGY_FRACTION = 0.25;
}

#[derive(Clone, Copy, Debug)]
pub struct FusionInput {
	pub plasma: f64,
	pub carbon_dioxide: f64,
	pub tritium: f64,
	pub temperature: f64,
	pub volume: f64,
	pub heat_capacity: f64,
	pub gas_power: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FusionOutput {
	pub plasma: f64,
	pub carbon_dioxide: f64,
	pub tritium: f64,
	pub waste: f64,
	pub water_product: bool,
	pub energy: f64,
	pub energy_delta: f64,
	pub instability: f64,
}

/// One authoritative opportunity, without catch-up. None means currently ineligible.
/// Errors are atomic: callers must validate all proposed gas/temperature writes before commit.
pub fn step(input: FusionInput) -> Result<Option<FusionOutput>, &'static str> {
	let finite = [
		input.plasma,
		input.carbon_dioxide,
		input.tritium,
		input.temperature,
		input.volume,
		input.heat_capacity,
		input.gas_power,
	]
	.into_iter()
	.all(f64::is_finite);
	if !finite
		|| input.volume <= 0.0
		|| input.volume > MAX_VOLUME
		|| input.heat_capacity <= 0.0
		|| input.temperature <= 0.0
		|| input.temperature > MAX_TEMPERATURE
		|| [input.plasma, input.carbon_dioxide, input.tritium]
			.into_iter()
			.any(|n| !(0.0..=MAX_MOLES).contains(&n))
	{
		return Err("fusion input outside profile bounds");
	}
	if input.plasma < MIN_MOLES
		|| input.carbon_dioxide < MIN_MOLES
		|| input.tritium < FUEL_PER_STEP
		|| input.temperature < MIN_TEMPERATURE
	{
		return Ok(None);
	}
	let scale = (input.volume / SCALE_DIVISOR).max(MIN_SCALE);
	let temperature_scale = input.temperature.log10() - BASE_TEMP_SCALE;
	let toroid = TOROID_THRESHOLD
		+ if temperature_scale <= 0.0 {
			temperature_scale
		} else {
			4.0_f64.powf(temperature_scale) / SLOPE_DIVISOR
		};
	if !toroid.is_finite() || toroid <= 0.0 {
		return Err("invalid fusion toroid");
	}
	let instability = (input.gas_power * GAS_POWER_FACTOR).rem_euclid(toroid);
	let plasma = ((input.plasma - MIN_MOLES) / scale
		- instability * ((input.carbon_dioxide - MIN_MOLES) / scale).sin())
	.rem_euclid(toroid);
	let carbon = ((input.carbon_dioxide - MIN_MOLES) / scale - plasma).rem_euclid(toroid);
	let plasma = plasma * scale + MIN_MOLES;
	let carbon_dioxide = carbon * scale + MIN_MOLES;
	let delta = (input.plasma - plasma).min(toroid * scale * 1.5);
	let raw_energy = if delta > 0.0 || instability <= ENDOTHERMAL_THRESHOLD {
		(delta * BINDING_ENERGY).max(0.0)
	} else {
		delta * BINDING_ENERGY * (instability - ENDOTHERMAL_THRESHOLD).sqrt()
	};
	let initial_energy = input.temperature * input.heat_capacity;
	if !initial_energy.is_finite() || !raw_energy.is_finite() {
		return Err("fusion energy overflow");
	}
	let energy_delta = raw_energy.clamp(
		-initial_energy * MAX_ENERGY_FRACTION,
		initial_energy * MAX_ENERGY_FRACTION,
	);
	let output = FusionOutput {
		plasma,
		carbon_dioxide,
		tritium: input.tritium - FUEL_PER_STEP,
		waste: scale * WASTE_COEFFICIENT * FUEL_PER_STEP,
		water_product: delta > 0.0,
		energy: initial_energy + energy_delta,
		energy_delta,
		instability,
	};
	if ![
		output.plasma,
		output.carbon_dioxide,
		output.tritium,
		output.waste,
		output.energy,
		output.instability,
	]
	.into_iter()
	.all(|v| v.is_finite() && v >= 0.0 && v <= f64::from(f32::MAX))
	{
		return Err("invalid fusion result");
	}
	Ok(Some(output))
}

#[cfg(test)]
mod tests {
	use super::*;
	fn input() -> FusionInput {
		FusionInput {
			plasma: 500.0,
			carbon_dioxide: 500.0,
			tritium: 10.0,
			temperature: 10000.0,
			volume: 2500.0,
			heat_capacity: 120000.0,
			gas_power: 500.0,
		}
	}
	#[test]
	fn bounded_atomic_step() {
		let source = input();
		let result = step(source).unwrap().unwrap();
		assert_eq!(result.tritium, 9.0);
		assert_eq!(result.waste, 0.5);
		assert!(
			(result.energy - source.temperature * source.heat_capacity).abs()
				<= source.temperature * source.heat_capacity * 0.25
		);
		assert_eq!(
			step(FusionInput {
				temperature: 9999.0,
				..source
			})
			.unwrap(),
			None
		);
		assert!(step(FusionInput {
			volume: 0.0,
			..source
		})
		.is_err());
		assert!(step(FusionInput {
			gas_power: f64::NAN,
			..source
		})
		.is_err());
	}

	#[test]
	fn energy_directions_products_and_nonproductive_opportunity() {
		for (power, direction, water) in
			[(0.0, 0.0_f64, false), (0.1, 1.0, true), (1.0, -1.0, false)]
		{
			let source = FusionInput {
				gas_power: power,
				..input()
			};
			let result = step(source).unwrap().unwrap();
			assert_eq!(
				result.energy_delta.total_cmp(&0.0),
				direction.total_cmp(&0.0)
			);
			assert_eq!(result.water_product, water);
			assert_eq!(result.tritium, source.tritium - FUEL_PER_STEP);
			assert_eq!(result.waste, 0.5);
			assert!(
				(result.energy - source.temperature * source.heat_capacity).abs()
					<= source.temperature * source.heat_capacity * MAX_ENERGY_FRACTION
			);
		}
	}

	#[test]
	fn activation_fuel_and_volume_boundaries() {
		let source = FusionInput {
			plasma: MIN_MOLES,
			carbon_dioxide: MIN_MOLES,
			tritium: FUEL_PER_STEP,
			..input()
		};
		assert_eq!(step(source).unwrap().unwrap().tritium, 0.0);
		for ineligible in [
			FusionInput {
				plasma: MIN_MOLES - 0.01,
				..source
			},
			FusionInput {
				carbon_dioxide: MIN_MOLES - 0.01,
				..source
			},
			FusionInput {
				tritium: 0.0,
				..source
			},
		] {
			assert_eq!(step(ineligible).unwrap(), None);
		}
		for volume in [0.001, MAX_VOLUME] {
			let result = step(FusionInput { volume, ..source }).unwrap().unwrap();
			assert!(result.plasma.is_finite() && result.carbon_dioxide.is_finite());
		}
		for invalid in [
			FusionInput {
				volume: MAX_VOLUME + 1.0,
				..source
			},
			FusionInput {
				temperature: f64::INFINITY,
				..source
			},
			FusionInput {
				plasma: f64::NAN,
				..source
			},
			FusionInput {
				carbon_dioxide: -1.0,
				..source
			},
			FusionInput {
				heat_capacity: 0.0,
				..source
			},
		] {
			assert!(step(invalid).is_err());
		}
	}
}
