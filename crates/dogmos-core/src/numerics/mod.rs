pub mod conduction;
pub mod diffusion;
pub mod fusion;

/// Molar precision shared by gas removal and fire reactions.
pub const MOLAR_ACCURACY: f32 = 0.0001;

#[inline]
pub fn quantize_moles(amount: f32) -> f32 {
	let scaled = amount / MOLAR_ACCURACY;
	if scaled.is_finite() {
		scaled.round() * MOLAR_ACCURACY
	} else {
		// At these magnitudes, adjacent f32 values are already much farther apart
		// than the quantum. Scaling must not turn a finite amount into infinity.
		amount
	}
}

/// Heat-capacity-weighted temperature, preserving ordinary f32 rounding.
#[inline]
pub fn weighted_temperature(cap_a: f32, temp_a: f32, cap_b: f32, temp_b: f32) -> f32 {
	let combined_capacity = cap_a + cap_b;
	let temperature = (cap_a * temp_a + cap_b * temp_b) / combined_capacity;
	if combined_capacity.is_finite() && temperature.is_finite() {
		temperature
	} else {
		weighted_temperature_wide(f64::from(cap_a), temp_a, f64::from(cap_b), temp_b)
	}
}

#[inline]
pub fn weighted_temperature_wide(cap_a: f64, temp_a: f32, cap_b: f64, temp_b: f32) -> f32 {
	((cap_a * f64::from(temp_a) + cap_b * f64::from(temp_b)) / (cap_a + cap_b)) as f32
}

/// Wide heat exchange; actual infinite capacities are fixed-temperature reservoirs.
/// Capacities must be positive; thresholds and temperature floors belong to the caller.
pub fn exchange_temperatures_wide(
	cap_a: f64,
	temp_a: f32,
	cap_b: f64,
	temp_b: f32,
	coefficient: f32,
) -> (f64, f64) {
	let harmonic_capacity = if cap_a.is_infinite() {
		if cap_b.is_infinite() {
			0.0
		} else {
			cap_b
		}
	} else if cap_b.is_infinite() {
		cap_a
	} else {
		let smaller = cap_a.min(cap_b);
		smaller / (1.0 + smaller / cap_a.max(cap_b))
	};
	let heat = f64::from(coefficient) * (f64::from(temp_a) - f64::from(temp_b)) * harmonic_capacity;
	(
		f64::from(temp_a) - heat / cap_a,
		f64::from(temp_b) + heat / cap_b,
	)
}
