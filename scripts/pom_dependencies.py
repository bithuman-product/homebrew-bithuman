#!/usr/bin/env python3
"""Print `group:artifact:version` for each <dependency> a POM on stdin DECLARES.

Only the top-level <dependencies> block: <dependencyManagement> states versions for
descendants that may never be resolved, and <parent> is not a dependency at all.
Anything without a literal version (a property, or managed elsewhere) is skipped —
this tool reports only what it can name exactly; it never guesses a coordinate.
"""
import sys, xml.etree.ElementTree as ET

def tag(e):
    return e.tag.split('}')[-1]

def main():
    raw = sys.stdin.buffer.read()
    if not raw.strip():
        return 0
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as exc:
        print(f"unparseable POM: {exc}", file=sys.stderr)
        return 2
    for block in root:
        if tag(block) != 'dependencies':
            continue
        for dep in block:
            if tag(dep) != 'dependency':
                continue
            f = {tag(c): (c.text or '').strip() for c in dep}
            if f.get('scope') in ('test', 'provided', 'system'):
                continue
            if f.get('optional', '').lower() == 'true':
                continue
            g, a, v = f.get('groupId', ''), f.get('artifactId', ''), f.get('version', '')
            if not (g and a and v) or '${' in v:
                continue
            print(f"{g}:{a}:{v}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
