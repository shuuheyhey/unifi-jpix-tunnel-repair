"""Repository-facing documentation checks, without network or Git access."""
from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit

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
