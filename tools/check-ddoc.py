#!/usr/bin/env python3
"""Audit compiler-produced, unfiltered JSON and the rendered public Ddoc surface."""
import argparse
import bisect
import collections
import json
from pathlib import Path
import re
import sys

IGNORED_KINDS = {'import', 'generated function', 'shared static constructor'}


def source_visibility(text):
    """Recover protection labels/blocks omitted in uninstantiated template JSON.

    Skip strings and nested D comments so examples and diagnostics cannot alter
    the source protection state. This supplements, rather than parses, the AST.
    """
    token = re.compile(r'[A-Za-z_]\w*|[^\s]')
    items = []
    i = 0
    while i < len(text):
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
            continue
        if text.startswith('/*', i):
            end = text.find('*/', i + 2)
            i = len(text) if end < 0 else end + 2
            continue
        if text.startswith('/+', i):
            depth = 1
            i += 2
            while i < len(text) and depth:
                if text.startswith('/+', i): depth += 1; i += 2
                elif text.startswith('+/', i): depth -= 1; i += 2
                else: i += 1
            continue
        if text[i] in ('"', "'", '`'):
            quote = text[i]
            i += 1
            while i < len(text):
                if text[i] == '\\' and quote != '`': i += 2
                elif text[i] == quote: i += 1; break
                else: i += 1
            continue
        match = token.match(text, i)
        if match:
            items.append((i, match.group()))
            i = match.end()
        else:
            i += 1
    stack = ['public']
    offsets, protection = [], []
    aggregate = False
    names = {'public', 'private', 'package', 'protected', 'export'}
    for index, (offset, word) in enumerate(items):
        offsets.append(offset)
        protection.append(stack[-1])
        after = items[index + 1][1] if index + 1 < len(items) else ''
        before = items[index - 1][1] if index else ''
        if word in names and after == ':':
            stack[-1] = 'public' if word == 'export' else word
        elif word in {'struct', 'class', 'union', 'interface', 'enum'}:
            aggregate = True
        elif word == '{':
            stack.append(before if before in names else 'public' if aggregate else stack[-1])
            aggregate = False
        elif word == '}':
            if len(stack) > 1: stack.pop()
            aggregate = False
        elif word == ';':
            aggregate = False
    return offsets, protection


def public_symbols(module, root):
    """Flatten public declarations, preserving overloads and hiding private containers.

    DMD omits protection on uninstantiated template members. Recover explicit
    private/package/protected modifiers from their compiler-reported source
    position, rather than treating those members as public by default.
    """
    source = root / module['file']
    text = source.read_text()
    source_lines = text.splitlines(True)
    lines = text.splitlines()
    line_offsets = [0]
    for line in source_lines:
        line_offsets.append(line_offsets[-1] + len(line))
    offsets, protections = source_visibility(text)

    def walk(node, parent=''):
        kind = node['kind']
        name = node.get('name', '')
        if node.get('protection', 'public') != 'public' or kind in IGNORED_KINDS:
            return
        if name.startswith('__') or name.startswith('_sharedStatic') :
            return
        if name == '~this':
            line = lines[node.get('line', 1) - 1]
            if not re.search(r'~\s*this\s*\(', line):
                return
        if kind != 'module' and not node.get('line'):
            return
        if kind != 'module' and 'protection' not in node:
            prefix = lines[node['line'] - 1][:node.get('char', 1) - 1]
            position = line_offsets[node['line'] - 1] + node.get('char', 1) - 1
            at = bisect.bisect_right(offsets, position) - 1
            if (re.search(r'\b(private|package|protected)\b', prefix) or
                    (at >= 0 and protections[at] not in {'public', 'export'})):
                return
        qualified = f'{parent}.{name}' if parent else name
        members = node.get('members', [])
        # Function and aggregate templates have a same-name wrapper in DMD JSON.
        if kind == 'template' and len(members) == 1 and members[0].get('name') == name:
            child = dict(members[0])
            child['comment'] = node.get('comment', child.get('comment', ''))
            child['protection'] = node.get('protection', 'public')
            yield from walk(child, parent)
            return
        if kind != 'module':
            yield qualified, node
        for member in members:
            yield from walk(member, '' if kind == 'module' else qualified)

    yield from walk(module)


def audit(modules, root, site=None):
    failures = []
    rows = []
    expected_modules = {str(p.relative_to(root)) for p in (root / 'source').rglob('*.d')}
    actual_modules = {m['file'] for m in modules}
    for missing in sorted(expected_modules - actual_modules):
        failures.append(f'Module absent from compiler JSON: {missing}')
    for module in modules:
        symbols = list(public_symbols(module, root))
        count = collections.Counter()
        names = set()
        forwarded = []
        for node in module.get('members', []):
            if node['kind'] != 'import' or node.get('protection', 'public') != 'public':
                continue
            if node['name'].split('.')[0] == 'imagery':
                continue
            selected = node.get('selective', [])
            forwarded.append({'module': node['name'], 'names': selected})
            comment = module.get('comment', '')
            for name in [node['name']] + selected:
                if name not in comment:
                    failures.append(f"{module['file']}: undocumented external forward {name}")
        for name, node in symbols:
            names.add(name)
            count[node['kind']] += 1
            comment = node.get('comment', '').strip()
            label = f"{module['file']}:{node['line']}: {name}"
            if not comment:
                failures.append(f'{label}: missing Ddoc')
            if '[CHECK:' in comment:
                failures.append(f'{label}: unresolved draft claim')
            if node['kind'] in {'function', 'constructor'}:
                params = {p['name'] for p in node.get('parameters', [])}
                documented = set(re.findall(r'^\s*(\w+)\s*=', comment, re.M))
                for parameter in sorted(params - documented):
                    failures.append(f'{label}: missing Params entry for {parameter}')
                signature = node.get('type', node.get('originalType', ''))
                is_void = bool(re.search(r'\bvoid\s*\(', signature) or
                               node.get('deco', '').endswith('Zv'))
                if node['kind'] == 'function' and not is_void and 'Returns:' not in comment:
                    failures.append(f'{label}: missing Returns section')
                body = '\n'.join((root / module['file']).read_text().splitlines()[
                    node['line'] - 1:node.get('endline', node['line'])])
                if 'throw new ' in body and 'Throws:' not in comment:
                    failures.append(f'{label}: explicit throw lacks Throws section')
            # Do not enforce a word blacklist: candidate, validity and ownership
            # terms can carry essential image-domain/lifetime meaning.
            if site is not None:
                base = site / Path(*module['name'].split('.'))
                page = base / f'{name}.html'
                if node['kind'] == 'enum member':
                    page = base / f"{name.rsplit('.', 1)[0]}.html"
                if not page.is_file() or not page.stat().st_size:
                    failures.append(f'{label}: missing rendered page {page}')
        if symbols and not module.get('comment', '').strip():
            failures.append(f"{module['file']}: missing module Ddoc")
        # DMD emits documented tests as function nodes with a source-code field.
        # Count the source spelling independently of private helper tests.
        text = (root / module['file']).read_text()
        examples = len(re.findall(r'(?m)^(?:[ \t]*///[^\n]*\n)+(?:[ \t]*(?:@\w+|nothrow|pure)\s+)*[ \t]*unittest\b', text))
        if symbols and not examples:
            failures.append(f"{module['file']}: no documented public-family example")
        rows.append({'module': module['name'], 'declarations': len(symbols),
                     'symbolFamilies': len(names), 'documentedExamples': examples,
                     'kinds': dict(count), 'foreignReexports': forwarded})
    return rows, failures


def check_example_pages(site):
    """Verify important family examples attach to their published type pages."""
    families = {
        'analysis/feature_regions/Source': 'path costs',
        'analysis/cost_path/CostPath': 'Example',
        'analysis/feature_worker32/Float32FeatureWorker': 'Example',
        'analysis/hessian_lines/HessianLineParams': 'multiscale line',
        'analysis/structure_tensor/StructureTensorParams': 'ramp direction',
        'analysis/feature_requests/FeatureRequests': 'Example',
        'analysis/region_graph/RegionGraph': 'Build, query and merge',
        'analysis/color_slic/ColorSlicSegmentation': 'complete segmentation',
        'presentation/levels/Levels': 'Construct identity settings',
    }
    failures = []
    for name, marker in families.items():
        page = site / 'imagery' / (name + '.html')
        text = page.read_text() if page.is_file() else ''
        if '<h2>Example</h2>' not in text or marker not in text:
            failures.append(f'{page}: missing attached family example')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('json', type=Path)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--site', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    rows, failures = audit(json.loads(args.json.read_text()), args.root, args.site)
    if args.site:
        failures.extend(check_example_pages(args.site))
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({'modules': rows, 'failures': failures}, indent=2) + '\n')
    for row in rows:
        print(f"{row['module']}: {row['declarations']} public declarations, "
              f"{row['documentedExamples']} documented examples")
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"DDOC_AUDIT={'FAIL' if failures else 'PASS'}: "
          f"{sum(r['declarations'] for r in rows)} declarations, {len(failures)} failures")
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
