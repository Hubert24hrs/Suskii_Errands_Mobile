import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import check_screen_parity

APP_ONLY = {"meetChat": "18+ chat is Android-app-only (OD-39)"}


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class CheckScreenParityTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.app("Future<void> f(WidgetRef ref) => ref.read(supportRepositoryProvider).openTicket(t);\n")
        self.website("export const F = () => supportRepository.openTicket(t);\n")

    def tearDown(self):
        self._tmp.cleanup()

    def app(self, body, name="a"):
        write(self.root, f"apps/mobile/lib/features/{name}.dart", body)

    def website(self, body, name="A"):
        write(self.root, f"apps/web-customer/src/app/{name}.tsx", body)

    def run_cli(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_screen_parity.main(["check_screen_parity.py", str(self.root)])
        return code, out.getvalue().splitlines()

    def test_the_same_feature_on_both_sides_passes(self):
        code, lines = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(lines, ["check_screen_parity: app screens call 1 repository methods, "
                                 "website screens 1; 0 gap(s)"])

    def test_a_method_on_one_side_only_is_a_gap(self):
        self.app("f(ref) => ref.read(supportRepositoryProvider).closeTicket(t);\n", "b")
        code, lines = self.run_cli()
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "::error::app only: support.closeTicket — a feature one app has and the other lacks")
        self.assertTrue(lines[-1].endswith("; 1 gap(s)"))

    def test_a_listed_method_level_difference_is_not_a_gap(self):
        self.app("f(ref) => ref.read(userRepositoryProvider).watchProfile();\n", "b")
        code, lines = self.run_cli()
        self.assertEqual(code, 0)
        self.assertIn("  app only: user.watchProfile (the app streams the profile; the website reads it "
                      "(getProfile))", lines)

    def test_every_app_call_on_an_app_only_repository_is_exempt(self):
        self.app("f(ref) {\n"
                 "  final chat = ref.read(meetChatRepositoryProvider);\n"
                 "  chat.sendMessage(m);\n"
                 "  ref.read(meetChatRepositoryProvider).markRead(c);\n"
                 "}\n", "b")
        with mock.patch.dict(check_screen_parity.PLATFORM_REPOSITORIES, APP_ONLY):
            code, lines = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(lines[:2], [
            "  app only: meetChat.markRead (18+ chat is Android-app-only (OD-39))",
            "  app only: meetChat.sendMessage (18+ chat is Android-app-only (OD-39))",
        ])

    def test_without_the_entry_the_same_calls_are_gaps(self):
        self.app("f(ref) => ref.read(meetChatRepositoryProvider).sendMessage(m);\n", "b")
        code, lines = self.run_cli()
        self.assertEqual(code, 1)
        self.assertIn("::error::app only: meetChat.sendMessage — a feature one app has and the other lacks", lines)

    def test_a_website_call_on_an_app_only_repository_is_a_gap_once(self):
        self.website("export const G = () => meetChatRepository.sendMessage(m);\n", "B")
        with mock.patch.dict(check_screen_parity.PLATFORM_REPOSITORIES, APP_ONLY):
            code, lines = self.run_cli()
        self.assertEqual(code, 1)
        errors = [line for line in lines if line.startswith("::error::")]
        self.assertEqual(errors, ["::error::website: meetChat.sendMessage — meetChat is app-only and the website "
                                  "must not call it (18+ chat is Android-app-only (OD-39))"])

    def test_matching_the_app_does_not_excuse_a_website_call_on_an_app_only_repository(self):
        # Parity would be satisfied; the owner's decision is that the website has no such feature.
        self.app("f(ref) => ref.read(meetChatRepositoryProvider).sendMessage(m);\n", "b")
        self.website("export const G = () => meetChatRepository.sendMessage(m);\n", "B")
        with mock.patch.dict(check_screen_parity.PLATFORM_REPOSITORIES, APP_ONLY):
            code, lines = self.run_cli()
        self.assertEqual(code, 1)
        self.assertIn("::error::website: meetChat.sendMessage — meetChat is app-only and the website must not "
                      "call it (18+ chat is Android-app-only (OD-39))", lines)

    def test_an_app_only_repository_does_not_exempt_its_neighbours(self):
        self.app("f(ref) => ref.read(meetChatRepositoryProvider).sendMessage(m);\n", "b")
        self.app("f(ref) => ref.read(meetEventsRepositoryProvider).join(e);\n", "c")
        with mock.patch.dict(check_screen_parity.PLATFORM_REPOSITORIES, APP_ONLY):
            _, gaps = check_screen_parity.report(check_screen_parity.app_calls(self.root),
                                                 check_screen_parity.website_calls(self.root))
        self.assertEqual(gaps, 1)

    def test_every_listed_repository_is_named_as_the_checker_sees_it_and_has_a_reason(self):
        for repository, reason in check_screen_parity.PLATFORM_REPOSITORIES.items():
            with self.subTest(repository=repository):
                self.assertEqual(repository, check_screen_parity._norm(repository))
                self.assertTrue(reason.strip())


if __name__ == "__main__":
    unittest.main()
