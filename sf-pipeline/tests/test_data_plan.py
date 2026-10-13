"""Tests for data_plan.py."""

import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts")))
import data_plan  # noqa: E402

PLAN = {
    "dataSet": "Accounts with contacts",
    "templates": [
        {"name": "Contacts", "object": "Contact", "fields": ["LastName", "Email", "AccountId"],
         "externalId": "Ext_Id__c", "order": 1, "limit": 100},
        {"name": "Accounts", "object": "Account", "fields": ["Name", "Industry"],
         "filter": "Industry != null", "externalId": "External_Id__c", "order": 2},
    ],
    "relationships": [{"parent": "Accounts", "child": "Contacts", "field": "AccountId"}],
}


class DataPlan(unittest.TestCase):
    def test_parents_first_and_lookup_by_external_id(self):
        steps = data_plan.build_steps(PLAN)
        self.assertEqual([s["name"] for s in steps], ["Accounts", "Contacts"])
        acc, con = steps
        self.assertEqual(acc["soql"], "SELECT External_Id__c, Name, Industry FROM Account WHERE Industry != null")
        self.assertIn("Account.External_Id__c", con["soql"])
        self.assertNotIn("AccountId", con["soql"])
        self.assertTrue(con["soql"].endswith("LIMIT 100"))
        self.assertEqual(con["externalId"], "Ext_Id__c")

    def test_custom_lookup_relationship_name(self):
        self.assertEqual(data_plan.relationship_name("Parent_Invoice__c"), "Parent_Invoice__r")
        self.assertEqual(data_plan.relationship_name("OwnerId"), "Owner")

    def test_external_id_required(self):
        bad = {"templates": [{"name": "X", "object": "Account", "fields": ["Name"]}]}
        with self.assertRaises(data_plan.PlanError):
            data_plan.build_steps(bad)

    def test_cycle_rejected(self):
        cyc = {"templates": [{"name": "A", "object": "A__c", "externalId": "E__c"},
                             {"name": "B", "object": "B__c", "externalId": "E__c"}],
               "relationships": [{"parent": "A", "child": "B", "field": "A__c"},
                                 {"parent": "B", "child": "A", "field": "B__c"}]}
        with self.assertRaises(data_plan.PlanError):
            data_plan.build_steps(cyc)

    def test_injection_in_field_rejected(self):
        bad = {"templates": [{"name": "X", "object": "Account", "externalId": "E__c",
                              "fields": ["Name FROM User --"]}]}
        with self.assertRaises(data_plan.PlanError):
            data_plan.build_steps(bad)


if __name__ == "__main__":
    unittest.main()
