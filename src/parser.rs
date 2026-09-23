use crate::gas::{gas_idx_from_string, Mixture};
use eyre::{eyre, Result};
use nom::branch::alt;
use nom::bytes::complete::tag;
use nom::character::complete::alphanumeric1;
use nom::combinator::recognize;
use nom::multi::{many1_count, separated_list0};
use nom::number::complete::float;
use nom::sequence::separated_pair;
use nom::IResult;

//parses gas id, must be an alphanumeric
fn parse_gas_id(input: &str) -> IResult<&str, &str> {
	recognize(many1_count(alt((alphanumeric1, tag("_")))))(input)
}

//parses moles in floating point form
fn parse_moles(input: &str) -> IResult<&str, f32> {
	float(input)
}

/// Parses gas strings, invalid patterns will be ignored
/// E.g: "o2=2500;plasma=5000;TEMP=370" will return vec![("o2", 2500_f32), ("plasma", 5000_f32), ("TEMP", 370_f32)]
pub(crate) fn parse_gas_string(input: &str) -> IResult<&str, Vec<(&str, f32)>> {
	separated_list0(
		tag(";"),
		separated_pair(parse_gas_id, tag("="), parse_moles),
	)(input)
}

/// Strict validation for loading. Empty input clears gases; outer whitespace and one trailing
/// semicolon are accepted. Internal whitespace is not part of the legacy grammar. Duplicate
/// keys use their last value. The permissive parser remains available for prefix inspection.
pub(crate) fn load_gas_string(air: &mut Mixture, input: &str) -> Result<()> {
	let input = input.trim();
	let input = input.strip_suffix(';').unwrap_or(input);
	let (remainder, entries) = parse_gas_string(input).map_err(|_| eyre!("Invalid gas string"))?;
	if !remainder.is_empty() {
		return Err(eyre!("Invalid gas string suffix: {remainder}"));
	}
	let mut proposed = air.copy_to_mutable();
	proposed.clear();
	for (key, value) in entries {
		if !value.is_finite() {
			return Err(eyre!("Gas string {key} requires a finite number"));
		}
		if key == "TEMP" {
			proposed.set_temperature(value);
		} else {
			let index = gas_idx_from_string(key)?;
			proposed.set_moles(index, value)?;
		}
	}
	// This preserves volume, minimum heat capacity and immutable-reservoir behavior.
	air.copy_from_mutable(&proposed);
	Ok(())
}

#[test]
fn loading_is_atomic_and_preserves_public_mixture_properties() {
	use crate::gas::{register_gas_manually, set_gas_statics_manually, GAS_TEST_LOCK};
	let _guard = GAS_TEST_LOCK.lock().unwrap();
	set_gas_statics_manually();
	register_gas_manually("o2", 20.0);
	let mut air = Mixture::from_vol(125.0);
	air.set_moles(0, 7.0).unwrap();
	air.set_temperature(300.0);
	for invalid in [
		"o2=10;garbage",
		"o2=10;unknown=5",
		"NOT_TEMP=500",
		"o2=-1",
		"o2=NaN",
		"TEMP=inf",
		"o2=1;;",
	] {
		assert!(load_gas_string(&mut air, invalid).is_err(), "{invalid}");
		assert_eq!(air.get_moles(0), 7.0);
		assert_eq!(air.get_temperature(), 300.0);
	}
	load_gas_string(&mut air, " o2=10;o2=3;TEMP=0; ").unwrap();
	assert_eq!(air.get_moles(0), 3.0);
	assert_eq!(air.get_temperature(), crate::gas::constants::TCMB);
	assert_eq!(air.get_volume(), 125.0);
	load_gas_string(&mut air, "").unwrap();
	assert_eq!(air.get_moles(0), 0.0);
}

#[test]
fn test_parser() {
	let test_str = "o2=2500;plasma=5000;TEMP=370";
	let result = parse_gas_string(test_str).unwrap();

	assert_eq!(
		result,
		(
			"",
			vec![("o2", 2500_f32), ("plasma", 5000_f32), ("TEMP", 370_f32)]
		)
	);
}
