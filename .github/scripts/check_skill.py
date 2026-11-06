#!/usr/bin/env python3
"""Checks the swift-microservices-architect skill against the authoring rules in CLAUDE.md.

Run from anywhere after every change to the skill, and fix until it passes:

    python3 .github/scripts/check_skill.py

It checks what a script can: the frontmatter, SKILL.md's size, the references and their
Contents lists, links and anchors, the plugin manifests, and the code style of every Swift
example. It exits non-zero when any check fails. The review that needs judgment is the
checklist in CLAUDE.md.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "swift-microservices-architect"
REFERENCES = SKILL / "references"

# Limits from the Agent Skills specification and Claude Code's skill loading.
MAX_NAME = 64
MAX_DESCRIPTION = 1024
MAX_SKILL_LINES = 500
MAX_SKILL_TOKENS = 5000  # recommended for the SKILL.md body; also what compaction keeps
SKILL_TOKEN_BUDGET = 4500  # headroom under the limit, so a new line makes room by removing one
CHARS_PER_TOKEN = 3.5  # a conservative estimate for English prose with code
CONTENTS_AFTER_LINES = 100

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def relative(path: Path) -> str:
    return str(path.relative_to(ROOT))


def outside_code(text: str):
    """Yields (line number, line) for lines outside fenced code blocks."""
    in_code = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            in_code = not in_code
            continue
        if not in_code:
            yield number, line


def swift_lines(text: str):
    """Yields (line number, line) for lines inside ```swift blocks, outside multi-line strings."""
    in_swift = in_string = False
    for number, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            in_swift = line.strip() == "```swift" if not in_swift else False
            continue
        if not in_swift:
            continue
        if line.count('"""') % 2 == 1:
            in_string = not in_string
            continue
        if not in_string:
            yield number, line


def slug(heading: str) -> str:
    text = re.sub(r"[`*_]", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def headings(text: str, level: str = "#") -> list[str]:
    return [line.lstrip("#").strip() for _, line in outside_code(text) if re.match(rf"{level}{{1,6}} ", line)]


# MARK: - Frontmatter


def check_frontmatter(skill_text: str) -> str:
    match = re.match(r"---\n(.*?)\n---\n", skill_text, re.S)
    if not match:
        fail("SKILL.md: the frontmatter must open the file between --- lines")
        return ""

    fields = {}
    for line in match.group(1).splitlines():
        key, separator, value = line.partition(":")
        if separator and re.fullmatch(r"[a-z][a-z0-9_-]*", key):
            fields[key] = value.strip()
        else:
            fail(f"frontmatter: keep each field on one line: {line[:60]}")

    if set(fields) != {"name", "description"}:
        fail(f"frontmatter: holds only name and description, found {sorted(fields)}")

    name = fields.get("name", "")
    if len(name) > MAX_NAME or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name):
        fail(f"frontmatter: name {name!r} must be at most {MAX_NAME} lowercase letters, digits and single hyphens")
    if name != SKILL.name:
        fail(f"frontmatter: name {name!r} must match the folder {SKILL.name!r}")
    if "anthropic" in name or "claude" in name:
        fail("frontmatter: name may not contain anthropic or claude")

    description = fields.get("description", "")
    if not 0 < len(description) <= MAX_DESCRIPTION:
        fail(f"frontmatter: description is {len(description)} characters, at most {MAX_DESCRIPTION}")
    if re.search(r"[<>]", description):
        fail("frontmatter: description may not contain angle brackets or XML tags")
    if re.match(r"(I|You|We|This skill)\b", description):
        fail("frontmatter: description is written in the third person, starting with what the skill does")
    if "Use when" not in description:
        fail("frontmatter: description says when to use the skill (Use when …)")

    if shutil.which("ruby"):
        script = 'require "yaml"; YAML.safe_load(File.read(ARGV[0], encoding: "UTF-8")[/\\A---\\n(.*?)\\n---\\n/m, 1])'
        result = subprocess.run(["ruby", "-e", script, str(SKILL / "SKILL.md")], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"frontmatter: not valid YAML: {result.stderr.strip()[:200]}")

    return description


# MARK: - SKILL.md size


def check_skill_size(skill_text: str) -> None:
    lines = skill_text.count("\n")
    tokens = len(skill_text) / CHARS_PER_TOKEN
    if lines > MAX_SKILL_LINES:
        fail(f"SKILL.md: {lines} lines, under {MAX_SKILL_LINES}")
    if tokens > SKILL_TOKEN_BUDGET:
        fail(f"SKILL.md: about {tokens:.0f} tokens, over the budget of {SKILL_TOKEN_BUDGET}; move detail to a reference")

    start = skill_text.find("\n## References")
    end = skill_text.find("\n## ", start + 1)
    if start < 0:
        fail("SKILL.md: no References section")
    elif (end if end > 0 else len(skill_text)) / CHARS_PER_TOKEN > MAX_SKILL_TOKENS:
        fail("SKILL.md: the References table ends past the first 5,000 tokens, which compaction keeps")
    print(f"SKILL.md: {lines} lines, about {tokens:.0f} tokens")


# MARK: - References


def check_references(skill_text: str, readme_text: str) -> None:
    references_section = skill_text[skill_text.find("\n## References") :]
    for path in sorted(REFERENCES.glob("*.md")):
        link = f"references/{path.name}"
        if f"]({link})" not in references_section:
            fail(f"{link}: not listed in SKILL.md's References table")
        if path.name not in readme_text:
            fail(f"{link}: not named in README.md's layout")

        text = read(path)
        if text.count("\n") <= CONTENTS_AFTER_LINES:
            continue
        listed = re.search(r"## Contents\n((?:- .*\n)+)", text)
        sections = [line[3:].strip() for _, line in outside_code(text) if line.startswith("## ") and line != "## Contents"]
        items = [line[2:].strip() for line in listed.group(1).splitlines()] if listed else []
        if items != sections:
            fail(f"{link}: its Contents list must match its ## headings, in order")


# MARK: - Links and anchors


def check_links() -> None:
    files = [ROOT / "README.md", ROOT / "CLAUDE.md", *sorted(SKILL.rglob("*.md"))]
    link = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
    for path in files:
        for number, line in outside_code(read(path)):
            for target in link.findall(line):
                if target.startswith(("http://", "https://", "mailto:")):
                    continue
                file_part, _, anchor = target.partition("#")
                destination = (path.parent / file_part).resolve() if file_part else path
                if not destination.exists():
                    fail(f"{relative(path)}:{number}: no file for {target}")
                elif anchor and destination.suffix == ".md":
                    anchors = {slug(heading) for heading in headings(read(destination))}
                    if anchor not in anchors:
                        fail(f"{relative(path)}:{number}: no heading for #{anchor}")


# MARK: - Manifests


def check_manifests(description: str) -> None:
    plugin = json.loads(read(ROOT / ".claude-plugin" / "plugin.json"))
    marketplace = json.loads(read(ROOT / ".claude-plugin" / "marketplace.json"))
    entry = next((item for item in marketplace.get("plugins", []) if item.get("name") == SKILL.name), None)
    if entry is None:
        fail(f"marketplace.json: no plugin entry named {SKILL.name}")
        return

    if plugin.get("description") != description:
        fail("plugin.json: its description must match SKILL.md's")
    if entry.get("description") != description:
        fail("marketplace.json: the plugin entry's description must match SKILL.md's")

    versions = {plugin.get("version"), marketplace.get("version"), entry.get("version")}
    if len(versions) != 1:
        fail(f"manifests: the three versions must agree, found {sorted(map(str, versions))}")


# MARK: - Swift examples


def balanced_arguments(text: str, start: int) -> str:
    """Returns the text between the parenthesis at start and its match."""
    depth = 0
    for index in range(start, len(text)):
        depth += {"(": 1, ")": -1}.get(text[index], 0)
        if depth == 0:
            return text[start + 1 : index]
    return text[start + 1 :]


def top_level_values(arguments: str) -> list[str]:
    values, depth, current = [], 0, ""
    for character in arguments:
        depth += {"(": 1, "[": 1, "{": 1, ")": -1, "]": -1, "}": -1}.get(character, 0)
        if character == "," and depth == 0:
            values.append(current)
            current = ""
        else:
            current += character
    values.append(current)
    return [re.sub(r"^\s*\w+:\s*", "", value).strip() for value in values if value.strip()]


def is_constant(value: str) -> bool:
    return bool(re.match(r'(\.|\d|\[|"|true\b|false\b|nil\b|$)', value))


def check_swift_examples() -> None:
    initializer = re.compile(r"(\(|\w: |, )([A-Z][\w.]*(?:<[^<>()]*>)?)\(")
    method_result = re.compile(r"(\(|\w: |, )[a-z]\w*(?:\.[a-z]\w*)*\.(\w+)\(")
    effect = re.compile(r"(\(|\w: |, )(try|await) ")
    declaration = re.compile(r"^\s+(let|var) \w+: [^=]+$")

    for path in sorted(SKILL.rglob("*.md")):
        lines = list(swift_lines(read(path)))
        for position, (number, line) in enumerate(lines):
            code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
            where = f"{relative(path)}:{number}"
            if effect.search(code):
                fail(f"{where}: a try or await inside an argument; build the value in a let first")
            for match in initializer.finditer(code):
                arguments = balanced_arguments(code, match.end() - 1)
                if not all(is_constant(value) for value in top_level_values(arguments)):
                    fail(f"{where}: {match.group(2)}(…) takes a variable inside an argument; build it in a let first")
            for match in method_result.finditer(code):
                # Hummingbird's route builder stays inline: controller.addRoutes(to: group.group("loans")).
                if match.group(2) != "group":
                    fail(f"{where}: a method's result inside an argument; build it in a let first")
            if declaration.match(line):
                following = [text.strip() for _, text in lines[position + 1 : position + 4]]
                if any(text.startswith("do {") for text in following):
                    fail(f"{where}: declared before a do for its catches to fill; end each path in its own catch")


# MARK: - Plugin


def check_plugin() -> None:
    if not shutil.which("claude"):
        print("plugin: skipped, no claude command; run claude plugin validate . yourself")
        return

    result = subprocess.run(["claude", "plugin", "validate", str(ROOT)], capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode != 0 or "Validation passed" not in output:
        fail(f"claude plugin validate failed:\n{output.strip()[-800:]}")


def main() -> int:
    skill_text = read(SKILL / "SKILL.md")
    readme_text = read(ROOT / "README.md")

    description = check_frontmatter(skill_text)
    check_skill_size(skill_text)
    check_references(skill_text, readme_text)
    check_links()
    check_manifests(description)
    check_swift_examples()
    check_plugin()

    for message in failures:
        print(f"FAIL {message}")
    print("All checks passed." if not failures else f"{len(failures)} checks failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
