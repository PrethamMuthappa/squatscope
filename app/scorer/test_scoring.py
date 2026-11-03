import json
import unittest

from app import handler
from scoring import score_domain


class ScoreDomainTest(unittest.TestCase):
    def test_lookalike_phishing_domain_is_high_risk(self):
        result = score_domain("paypa1-secure-login.com")
        self.assertEqual(result["risk"], "high")

    def test_official_domain_is_low_risk(self):
        self.assertEqual(score_domain("www.paypal.com")["score"], 0)

    def test_misspelling_is_flagged(self):
        result = score_domain("gooogle.com")
        self.assertGreaterEqual(result["score"], 40)

    def test_unrelated_domain_is_low_risk(self):
        self.assertEqual(score_domain("example.org")["risk"], "low")

    def test_url_input_is_cleaned(self):
        self.assertEqual(score_domain("https://PayPa1.com/login")["domain"], "paypa1.com")

    def test_custom_brand_is_detected(self):
        result = score_domain("acme-login.com", ["acme"])
        self.assertIn("contains the brand name 'acme'", result["reasons"])

    def test_custom_brand_official_domain_is_low_risk(self):
        self.assertEqual(score_domain("acme.com", ["acme"])["score"], 0)

    def test_invalid_domain_raises(self):
        with self.assertRaises(ValueError):
            score_domain("not a domain")


class HandlerTest(unittest.TestCase):
    def test_post_body(self):
        resp = handler({"body": json.dumps({"domain": "paypa1.com"})}, None)
        self.assertEqual(resp["statusCode"], 200)

    def test_missing_domain_is_400(self):
        self.assertEqual(handler({}, None)["statusCode"], 400)

    def test_add_brand_validates_name(self):
        event = {"routeKey": "POST /brands", "body": json.dumps({"name": "a b"})}
        self.assertEqual(handler(event, None)["statusCode"], 400)

    def test_add_brand_ok(self):
        event = {"routeKey": "POST /brands", "body": json.dumps({"name": "Acme"})}
        resp = handler(event, None)
        self.assertEqual(resp["statusCode"], 201)
        self.assertEqual(json.loads(resp["body"]), {"added": "acme"})

    def test_get_brands_lists_builtin(self):
        body = json.loads(handler({"routeKey": "GET /brands"}, None)["body"])
        self.assertIn("paypal", body["builtin"])

    def test_unknown_route_is_404(self):
        self.assertEqual(handler({"routeKey": "GET /nope"}, None)["statusCode"], 404)


if __name__ == "__main__":
    unittest.main()
