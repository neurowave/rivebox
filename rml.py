"""Tiny RML builder: E(tag, **attrs)(children...) -> element; str() renders XML."""
from __future__ import annotations


def esc(s) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


class E:
    def __init__(self, _tag: str, **attrs):
        self.tag = _tag
        self.attrs = {k.rstrip("_"): v for k, v in attrs.items() if v is not None}
        self.kids: list = []

    def __call__(self, *kids) -> "E":
        for k in kids:
            if k is None:
                continue
            if isinstance(k, (list, tuple)):
                self(*k)
            else:
                self.kids.append(k)
        return self

    def add(self, *kids) -> "E":
        return self(*kids)

    def render(self, ind: int = 0, out: list | None = None) -> list:
        out = [] if out is None else out
        pad = "    " * ind
        a = "".join(f' {k}="{esc(_fmt(v))}"' for k, v in self.attrs.items())
        if not self.kids:
            out.append(f"{pad}<{self.tag}{a}/>")
        else:
            out.append(f"{pad}<{self.tag}{a}>")
            for k in self.kids:
                if isinstance(k, E):
                    k.render(ind + 1, out)
                else:
                    out.append(pad + "    " + str(k))
            out.append(f"{pad}</{self.tag}>")
        return out

    def __str__(self) -> str:
        return "\n".join(self.render())


def _fmt(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        s = f"{v:.6f}".rstrip("0").rstrip(".")
        return s if s not in ("", "-0") else "0"
    return str(v)


class Ids:
    def __init__(self, client: int = 0, start: int = 1000):
        self.c = client
        self.n = start

    def __call__(self) -> str:
        self.n += 1
        return f"{self.c}:{self.n}"
