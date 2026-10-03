import pathlib
import unittest

import printf_inventory


class ProjectSourceTests(unittest.TestCase):
    def test_system_headers_do_not_add_formats_or_dynamic_calls(self):
        root = pathlib.Path("/project")
        source = (
            '# 1 "lib/ipmi_mc.c"\n'
            'printf("%lu", value);\n'
            '# 1 "/usr/include/vendor.h" 1 3\n'
            'const char *foreign = "%Lf";\n'
            'printf(foreign_format, value);\n'
            '# 20 "lib/ipmi_mc.c" 2\n'
            'printf("%02x", value);\n'
        )
        selected = printf_inventory.project_source(source, root)
        self.assertEqual(selected, 'printf("%lu", value);\nprintf("%02x", value);\n')
        self.assertEqual(
            [literals for _, literals in printf_inventory.formats(selected)],
            [["%lu"], ["%02x"]],
        )

    def test_project_headers_and_absolute_source_paths_remain_selected(self):
        source = (
            '# 1 "<built-in>"\n'
            'const char *foreign = "%p";\n'
            '# 1 "/project/include/ipmitool/ipmi_mc.h" 1\n'
            'const char *table = "%08x";\n'
            '# 2 "/project/lib/ipmi_mc.c" 2\n'
            'printf("%" "lu", value);\n'
        )
        self.assertEqual(
            printf_inventory.project_source(source, pathlib.Path("/project")),
            'const char *table = "%08x";\nprintf("%" "lu", value);\n',
        )

    def test_similarly_named_external_directories_are_not_project_sources(self):
        source = (
            '# 1 "/project-other/lib/ipmi_mc.c"\n'
            'printf("%p", value);\n'
            '# 1 "/project/other/lib/ipmi_mc.c"\n'
            'printf("%Lf", value);\n'
        )
        self.assertEqual(printf_inventory.project_source(source, pathlib.Path("/project")), "")


class FixedWidthTests(unittest.TestCase):
    def test_inventory_includes_promoted_and_narrow_integer_macro_forms(self):
        source = 'printf("%3" PRIu8 " %" PRId16, byte, word);'
        self.assertEqual(
            [[literals for _, literals in printf_inventory.formats(profile)]
             for profile in printf_inventory.fixed_width_sources(source)],
            [[["%3u %d"]], [["%3hhu %hd"]]],
        )

    def test_integer_macro_profiles_do_not_rewrite_literal_text_or_comments(self):
        source = '/* PRIu8 */ printf("PRIu8 %u", value); // PRId16\n'
        self.assertEqual(list(printf_inventory.fixed_width_sources(source)), [source, source])


if __name__ == "__main__":
    unittest.main()
