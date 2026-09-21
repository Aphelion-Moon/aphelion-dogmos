use crate::turfs::{
	capture_two_turf_heat_trace,
	katmos::{capture_two_turf_equalize_trace, LegacyStageTrace},
	processing::capture_two_turf_diffusion_trace,
};
use std::collections::BTreeMap;

const LEGACY_STAGE_TRANSCRIPT: &str = include_str!("fixtures/legacy_stage_transcript_v1.txt");
const TRANSCRIPT_HEADER: &str = "DOGMOS_LEGACY_STAGE_TRANSCRIPT_V1";

fn parse_legacy_stage_fixture(
	captured: &BTreeMap<&str, LegacyStageTrace>,
) -> BTreeMap<String, LegacyStageTrace> {
	let mut lines = LEGACY_STAGE_TRANSCRIPT.lines();
	assert_eq!(lines.next(), Some(TRANSCRIPT_HEADER));
	let rows = lines.collect::<Vec<_>>();
	assert_eq!(
		rows.len(),
		3,
		"expected three legacy stage transcript rows; captured {captured:?}"
	);
	rows.into_iter()
		.map(|row| {
			let fields = row.split('|').collect::<Vec<_>>();
			assert_eq!(fields.len(), 10, "malformed legacy stage transcript row");
			let pressure_events = match fields[4] {
				"none" => Vec::new(),
				"pressure_difference" => vec![(
					fields[9].parse().unwrap(),
					fields[5].parse().unwrap(),
					fields[6].parse().unwrap(),
					fields[7].parse().unwrap(),
					fields[8].parse().unwrap(),
				)],
				kind => panic!("unknown legacy stage event kind {kind}"),
			};
			(
				fields[0].to_owned(),
				LegacyStageTrace {
					work_items: fields[1].parse().unwrap(),
					left_value: fields[2].parse().unwrap(),
					right_value: fields[3].parse().unwrap(),
					pressure_events,
				},
			)
		})
		.collect()
}

#[test]
fn native_stage_and_event_traces_match_golden_fixture() {
	let legacy = BTreeMap::from([
		("process_turfs", capture_two_turf_diffusion_trace()),
		("equalize", capture_two_turf_equalize_trace()),
		("turf_heat", capture_two_turf_heat_trace()),
	]);
	let fixture = parse_legacy_stage_fixture(&legacy);
	for (stage, trace) in &legacy {
		assert_eq!(trace, &fixture[*stage]);
	}
}
