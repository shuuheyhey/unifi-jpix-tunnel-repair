"""Repository-facing documentation checks, without network or Git access."""
from pathlib import Path
import argparse
import json
import re
import unittest
from urllib.parse import unquote, urlsplit

from unifi_jpix.cli import parser

ROOT = Path(__file__).resolve().parents[1]


def anchors(document):
    seen = {}
    result = set()
    for heading in re.findall(r"^#{1,6} (.+)$", document, re.MULTILINE):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        result.add(f"{slug}-{count}" if count else slug)
    return result


class DocumentationTests(unittest.TestCase):
    def test_operator_command_table_matches_cli(self):
        document = (ROOT / "docs/guide.md").read_text()
        documented = set(re.findall(r"^\| `unifi-jpix ([a-z-]+)` \|", document, re.MULTILINE))
        subcommands = next(action for action in parser()._actions
                           if isinstance(action, argparse._SubParsersAction))
        self.assertEqual(documented, set(subcommands.choices))

    def test_architecture_lists_every_packaged_unit(self):
        document = (ROOT / "docs/architecture.md").read_text()
        documented = set(re.findall(r"^\| `(unifi-jpix-[\w.-]+)` \|", document, re.MULTILINE))
        self.assertEqual(documented, {path.name for path in (ROOT / "systemd-v2").iterdir()
                                     if path.is_file()})

    def test_configuration_reference_covers_example_fields(self):
        example = json.loads((ROOT / "config/config-v2.json.example").read_text())
        document = (ROOT / "docs/configuration.md").read_text()
        documented = set(re.findall(r"^\| `([^`]+)` \|", document, re.MULTILINE))

        def fields(value, prefix=""):
            for key, item in value.items():
                name = f"{prefix}.{key}" if prefix else key
                if isinstance(item, dict) and item:
                    yield from fields(item, name)
                elif isinstance(item, list):
                    for row in item:
                        yield from fields(row, name + "[]")
                else:
                    yield name

        self.assertFalse(set(fields(example)) - documented, "example fields missing from reference")

    def test_local_documentation_links_resolve(self):
        documents = [*ROOT.glob("*.md"), *(ROOT / "docs").glob("*.md"),
                     *(ROOT / ".github").rglob("*.md")]
        for source in documents:
            for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", source.read_text()):
                parsed = urlsplit(target)
                if parsed.scheme or parsed.netloc:
                    continue
                with self.subTest(source=source.relative_to(ROOT), target=target):
                    path = (source.parent / unquote(parsed.path)).resolve() if parsed.path else source
                    self.assertTrue(path.is_relative_to(ROOT), "link escapes repository")
                    self.assertTrue(path.exists(), "missing link target")
                    if parsed.fragment and path.suffix == ".md":
                        self.assertIn(unquote(parsed.fragment), anchors(path.read_text()))


if __name__ == "__main__":
    unittest.main()
