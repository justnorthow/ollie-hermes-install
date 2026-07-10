import os, tempfile, unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
SEED_PATH = os.path.join(HERE, "..", "scripts", "lib", "seed-operator-role.py")


def load_mod():
    return SourceFileLoader("seed_operator_role", SEED_PATH).load_module()


class TestHelpers(unittest.TestCase):
    def test_find_user_case_insensitive(self):
        m = load_mod()
        users = [{"id": "u1", "email": "JB@Example.com"}, {"id": "u2", "email": "x@y.z"}]
        self.assertEqual(m.find_user(users, "jb@example.com"), "u1")
        self.assertIsNone(m.find_user(users, "absent@example.com"))

    def test_build_role_payload(self):
        m = load_mod()
        self.assertEqual(
            m.build_role_payload("inst-1", "u1"),
            [{"instance_id": "inst-1", "user_id": "u1", "tier": "platform_operator"}],
        )

    def test_extract_users_from_dict(self):
        m = load_mod()
        data = {"users": [{"id": "u1", "email": "test@example.com"}]}
        self.assertEqual(m.extract_users(data), [{"id": "u1", "email": "test@example.com"}])

    def test_extract_users_from_list(self):
        m = load_mod()
        data = [{"id": "u2", "email": "test2@example.com"}]
        self.assertEqual(m.extract_users(data), [{"id": "u2", "email": "test2@example.com"}])

    def test_extract_users_dict_with_garbage_users(self):
        m = load_mod()
        data = {"users": "garbage"}
        self.assertEqual(m.extract_users(data), [])

    def test_extract_users_with_garbage_input(self):
        m = load_mod()
        self.assertEqual(m.extract_users("garbage"), [])
        self.assertEqual(m.extract_users(None), [])
        self.assertEqual(m.extract_users(123), [])

    def test_load_supabase_env(self):
        m = load_mod()
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("OTHER=x\nSUPABASE_URL=https://abc.supabase.co\nSUPABASE_SERVICE_ROLE_KEY=sk\n")
        url, key = m.load_supabase_env(f.name)
        self.assertEqual(url, "https://abc.supabase.co")
        self.assertEqual(key, "sk")

    def test_load_supabase_env_missing_raises(self):
        m = load_mod()
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("OTHER=x\n")
        with self.assertRaises(SystemExit):
            m.load_supabase_env(f.name)


if __name__ == "__main__":
    unittest.main()
