import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check_dogmos_frontier_writers.py"
spec = importlib.util.spec_from_file_location("frontier_writers", SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class FrontierWriterTests(unittest.TestCase):
    def test_unreviewed_direct_and_aliased_writers_are_rejected(self):
        for body in (
            "SSair.active_turfs += target",
            "SSair.active_turfs.Remove(target)",
            "SSair.active_turfs[1] = target",
            "SSair.active_turfs.len = 0",
            "SSair.active_turfs.len--",
            'SSair.vars["active_turfs"] = list()',
            'SSair.vars["active_turfs"].Cut()',
            'var/list/alias = SSair.vars["active_turfs"]\n\talias.Cut()',
            "var/list/alias = SSair.active_turfs\n\talias.Cut()",
            "var/list/alias = SSair.active_turfs\n\tvar/list/second = alias\n\tsecond += target",
        ):
            with self.subTest(body=body):
                self.assertTrue(guard.check_source("fixture.dm", "/datum/example/proc/change()\n\t" + body))

    def test_bare_air_member_writes_are_rejected(self):
        source = "/datum/controller/subsystem/air/proc/unreviewed()\n\tactive_turfs.Cut()"
        self.assertTrue(guard.check_source("air.dm", source))

    def test_reviewed_helpers_and_private_test_oracle_are_allowed(self):
        for owner in (
            "/datum/controller/subsystem/air/proc/dogmos_add_frontier_member",
            "/datum/unit_test/dogmos_runtime_frontier_journal/Run",
        ):
            self.assertFalse(guard.check_source("fixture.dm", owner + "()\n\tSSair.active_turfs += target"))

    def test_comments_copies_strings_and_other_subsystems_are_not_writers(self):
        source = '''/datum/example/proc/read()
    // SSair.active_turfs.Cut()
    /* SSair.active_turfs += target */
    var/example = "SSair.active_turfs -= target"
    var/list/copy = SSair.active_turfs.Copy()
    copy.Cut()
    SSliquids.active_turfs -= target
    var/list/other = list()
    other.Add(target)
'''
        self.assertFalse(guard.check_source("fixture.dm", source))

    def test_alias_ownership_does_not_leak_between_procs(self):
        source = "/datum/example/proc/read()\n\tvar/list/alias = SSair.active_turfs\n/datum/example/proc/change()\n\tvar/list/alias = list()\n\talias.Cut()"
        self.assertFalse(guard.check_source("fixture.dm", source))


if __name__ == "__main__":
    unittest.main()
