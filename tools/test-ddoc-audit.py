#!/usr/bin/env python3
"""Compiler-backed positive/negative probes for the public documentation gate."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ddoc_audit', Path(__file__).with_name('check-ddoc.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

SOURCE = '''/++ Documented module. +/
module imagery.fixture;
/++ Public template with private implementation. +/
struct Box(T)
{
    private int hidden;
    private bool helper() { return true; }
private:
    int hiddenByLabel;
    bool hiddenLabelFunction() { return false; }
public:
    /++ Public stored value. +/
    T value;
    /++ Return a supplied flag.
    Params:
        flag = Boolean value to return.
    Returns: The supplied flag.
    +/
    bool read(bool flag) { return flag; }
}
/++ Public choice. +/
enum Choice
{
    /++ First choice. +/
    first,
    /++ Second choice. +/
    second
}
/// Use the public template value and method.
unittest
{
    Box!int box;
    box.value=1;
    assert(box.read(true));
}
'''


class DocumentationGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='imagery-ddoc-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source/imagery/fixture.d'
        self.source.parent.mkdir(parents=True)
        self.compiler = os.environ.get('DC', 'dmd')
        if not shutil.which(self.compiler):
            self.skipTest(f'{self.compiler} unavailable')

    def compile(self, source=SOURCE):
        self.source.write_text(source)
        subprocess.run([self.compiler, '-o-', '-Xfraw.json', '-Dfignored.html',
                        'source/imagery/fixture.d'], cwd=self.root,
                       check=True, capture_output=True, text=True)
        return json.loads((self.root / 'raw.json').read_text())

    def test_complete_public_surface(self):
        modules = self.compile()
        names = {name for module in modules for name, _ in audit.public_symbols(module, self.root)}
        self.assertIn('Box.value', names)
        self.assertIn('Box.read', names)
        self.assertNotIn('Box.hidden', names)
        self.assertNotIn('Box.helper', names)
        self.assertNotIn('Box.hiddenByLabel', names)
        self.assertNotIn('Box.hiddenLabelFunction', names)
        _, failures = audit.audit(modules, self.root)
        self.assertEqual([], failures)

    def test_removed_public_comment_fails(self):
        modules = self.compile(SOURCE.replace('/++ Public stored value. +/', ''))
        _, failures = audit.audit(modules, self.root)
        self.assertTrue(any('Box.value: missing Ddoc' in f for f in failures), failures)

    def test_missing_parameter_fails(self):
        modules = self.compile(SOURCE.replace('flag = Boolean value to return.', 'No argument entry.'))
        _, failures = audit.audit(modules, self.root)
        self.assertTrue(any('missing Params entry for flag' in f for f in failures), failures)

    def test_removed_return_contract_fails(self):
        modules = self.compile(SOURCE.replace('Returns: The supplied flag.', ''))
        _, failures = audit.audit(modules, self.root)
        self.assertTrue(any('missing Returns section' in f for f in failures), failures)

    def test_detached_family_example_fails(self):
        site = self.root / 'site'
        site.mkdir()
        self.assertTrue(audit.check_example_pages(site))

    def test_missing_throw_contract_fails(self):
        source = SOURCE.replace('return flag;', 'if (flag) throw new Exception("probe"); return false;')
        modules = self.compile(source)
        _, failures = audit.audit(modules, self.root)
        self.assertTrue(any('explicit throw lacks Throws' in f for f in failures), failures)

    def test_undocumented_foreign_forward_fails(self):
        source = SOURCE.replace('module imagery.fixture;',
                                'module imagery.fixture;\npublic import std.math : abs;')
        modules = self.compile(source)
        _, failures = audit.audit(modules, self.root)
        self.assertTrue(any('undocumented external forward abs' in f for f in failures), failures)

    def test_missing_module_fails(self):
        self.compile()
        _, failures = audit.audit([], self.root)
        self.assertTrue(any('Module absent' in f for f in failures), failures)

    def test_missing_rendered_page_fails(self):
        modules = self.compile()
        site = self.root / 'site'
        site.mkdir()
        _, failures = audit.audit(modules, self.root, site)
        self.assertTrue(any('missing rendered page' in f for f in failures), failures)


if __name__ == '__main__':
    unittest.main()
