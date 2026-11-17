"""The GDD equipment rules against the shared cases (the GDScript twin reads the same file).

usage: python3 -m unittest discover tools/character/garments
"""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import garment_rules as rules  # noqa: E402

CASES = os.path.join(HERE, "..", "..", "..", "test", "data", "character", "garment_rules_cases.json")


class GarmentRulesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(CASES) as f:
            cls.cases = json.load(f)
        cls.items = {}
        for name, item in cls.cases["items"].items():
            cls.items[name] = dict(item, id=name)

    def test_zone_codes(self):
        for case in self.cases["zones"]:
            self.assertEqual(rules.parse_zone(case["code"]) is not None, case["valid"], case["code"])

    def test_overlaps(self):
        for case in self.cases["overlaps"]:
            self.assertEqual(rules.zones_overlap(case["a"], case["b"]), case["overlap"], case)
            self.assertEqual(rules.zones_overlap(case["b"], case["a"]), case["overlap"], "symmetric: %s" % case)

    def test_sets(self):
        for case in self.cases["sets"]:
            worn = [self.items[n] for n in case["worn"]]
            got = rules.conflict(worn[0], worn[1])
            self.assertEqual(got, case["conflict"], case["worn"])
            kept = [i["id"] for i in rules.keep_compatible(worn)]
            if case["conflict"]:
                self.assertEqual(kept, case["kept"], case["worn"])
                continue
            self.assertEqual(kept, case["worn"])
            self.assertEqual([i["id"] for i in rules.stack_order(worn)], case["order"], case["worn"])
            self.assertEqual([i["id"] for i in worn if rules.blocked(i, worn)], case["blocked"], case["worn"])

    def test_codes(self):
        for case in self.cases["codes"]:
            self.assertEqual(rules.code_of(self.items[case["item"]]), case["code"])

    def test_items_are_valid(self):
        for name, item in self.items.items():
            self.assertEqual(rules.check_item(item), [], name)
        self.assertTrue(rules.check_item({"zones": ["3G"], "support": 0, "layer": 7, "access": 2}))


if __name__ == "__main__":
    unittest.main()
