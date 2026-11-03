import json
import unittest
from datetime import datetime, timezone

import enricher
from enricher import assess
from generator import lookalike_names, registered_domain, typo_candidates

NOW = datetime(2026, 11, 3, tzinfo=timezone.utc)
PARKED = {"resolves": False, "has_mail": False, "registered_at": "2020-01-01T00:00:00Z"}


class GeneratorTest(unittest.TestCase):
    def test_lookalike_tricks(self):
        names = lookalike_names("acme")
        self.assertIn("acrne", names)       # rn looks like m
        self.assertIn("acm", names)         # missing letter
        self.assertIn("amce", names)        # swapped neighbours
        self.assertIn("acme-login", names)
        self.assertNotIn("acme", names)

    def test_candidates_skip_official_domain(self):
        domains = typo_candidates("acme")
        self.assertNotIn("acme.com", domains)
        self.assertIn("acme.net", domains)
        self.assertEqual(len(domains), len(set(domains)))

    def test_registered_domain(self):
        self.assertEqual(registered_domain("*.mail.Acme-Login.com"), "acme-login.com")


class AssessTest(unittest.TestCase):
    def test_first_sighting_is_new(self):
        item = assess("acrne.com", "acme", PARKED, None, NOW)
        self.assertEqual(item["status"], "new")
        self.assertEqual(item["first_seen"], item["checked_at"])

    def test_gaining_mail_is_a_change_and_raises_risk(self):
        before = assess("acrne.com", "acme", PARKED, None, NOW)
        armed = dict(PARKED, has_mail=True, resolves=True)
        after = assess("acrne.com", "acme", armed, before, NOW)
        self.assertEqual(after["status"], "changed")
        self.assertIn("gained mail servers", after["changes"])
        self.assertGreater(after["score"], before["score"])
        self.assertEqual(after["first_seen"], before["first_seen"])

    def test_same_facts_twice_is_unchanged(self):
        # Duplicate SQS deliveries must not look like changes
        before = assess("acrne.com", "acme", PARKED, None, NOW)
        again = assess("acrne.com", "acme", PARKED, before, NOW)
        self.assertEqual(again["status"], "unchanged")

    def test_young_domain_scores_higher(self):
        young = dict(PARKED, registered_at="2026-10-25T00:00:00Z")
        self.assertIn("registered 9 days ago", assess("acrne.com", "acme", young, None, NOW)["reasons"])


class EnricherHandlerTest(unittest.TestCase):
    def test_bad_message_is_reported_as_failure(self):
        event = {"Records": [{"messageId": "m1", "body": "not json"}]}
        self.assertEqual(enricher.handler(event, None), {"batchItemFailures": [{"itemIdentifier": "m1"}]})

    def test_unregistered_domain_is_skipped(self):
        original = enricher.dns
        enricher.dns = lambda name, rtype: (3, [])
        try:
            body = json.dumps({"domain": "acrne.com", "brand": "acme"})
            out = enricher.handler({"Records": [{"messageId": "m1", "body": body}]}, None)
        finally:
            enricher.dns = original
        self.assertEqual(out, {"batchItemFailures": []})


if __name__ == "__main__":
    unittest.main()
