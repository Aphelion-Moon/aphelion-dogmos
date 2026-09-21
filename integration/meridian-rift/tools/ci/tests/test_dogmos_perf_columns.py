from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
TIME_TRACK = ROOT / "code/controllers/subsystem/time_track.dm"


class DogmosPerfColumnsTest(unittest.TestCase):
	def test_dogmos_stage_costs_are_exported(self) -> None:
		text = TIME_TRACK.read_text(encoding="utf-8")
		for header, value in (
			('"air_equalize_cost"', "SSair.cost_equalize"),
			('"air_post_process_cost"', "SSair.cost_post_process"),
		):
			with self.subTest(header=header):
				self.assertEqual(text.count(header), 1)
				self.assertEqual(text.count(value), 1)


if __name__ == "__main__":
	unittest.main()
