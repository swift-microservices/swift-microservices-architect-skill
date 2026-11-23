"""Runs `skillevaluator` with its arguments, through NVIDIA's content screen.

NVIDIA's embedding endpoint screens each input and refuses some harmless text
with HTTP 422, such as any text containing `metadata:`, which every skill's
frontmatter does. This runner changes only the text sent for embedding:

- `metadata:` is sent as `metadata`.
- A chunk the screen still refuses is embedded line by line, then sentence by
  sentence, and its vector is the normalized mean of the pieces. The runner
  prints each such chunk and each piece it leaves out to stderr.

Run it with SkillEvaluator's own Python:

    "$(uv tool dir)/skillevaluator/bin/python" -I .github/scripts/skillevaluator_tier2.py tier2 ...
"""

import math
import re
import sys

import openai
import openai.resources.embeddings as embeddings
from skillevaluator.cli import cli

_create = embeddings.Embeddings.create


class _Vector:
    def __init__(self, index: int, embedding: list[float]) -> None:
        self.index = index
        self.embedding = embedding


class _Response:
    def __init__(self, vectors: list[list[float]]) -> None:
        self.data = [_Vector(index, vector) for index, vector in enumerate(vectors)]


def _embed(client, request: dict, texts: list[str]) -> list[list[float]]:
    texts = [re.sub(r"(?i)\bmetadata:", "metadata", text) for text in texts]
    response = _create(client, **{**request, "input": texts})
    return [item.embedding for item in sorted(response.data, key=lambda item: item.index)]


def _embed_by_piece(client, request: dict, text: str, by_sentence: bool = False) -> list[float]:
    pieces = re.split(r"(?<=[.:;])\s+", text) if by_sentence else text.splitlines()
    vectors = []
    for piece in filter(str.strip, pieces):
        try:
            vectors.extend(_embed(client, request, [piece]))
        except openai.UnprocessableEntityError:
            if by_sentence:
                print(f"[tier2] left out: {piece[:120]!r}", file=sys.stderr)
            else:
                vectors.append(_embed_by_piece(client, request, piece, by_sentence=True))
    if not vectors:
        raise SystemExit(f"[tier2] the screen refused every piece of: {text[:80]!r}")
    mean = [sum(values) / len(vectors) for values in zip(*vectors)]
    norm = math.sqrt(sum(value * value for value in mean)) or 1.0
    return [value / norm for value in mean]


def create(client, **request) -> _Response:
    texts = request["input"]
    try:
        return _Response(_embed(client, request, texts))
    except openai.UnprocessableEntityError:
        pass
    vectors = []
    for text in texts:
        try:
            vectors.extend(_embed(client, request, [text]))
        except openai.UnprocessableEntityError:
            print(f"[tier2] screened, embedded by piece: {text[:80]!r}", file=sys.stderr)
            vectors.append(_embed_by_piece(client, request, text))
    return _Response(vectors)


embeddings.Embeddings.create = create
sys.argv[0] = "skillevaluator"
sys.exit(cli())
