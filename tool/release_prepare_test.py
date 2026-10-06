import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('release_prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PrepareReleaseTest(unittest.TestCase):
    def test_missing_credentials_refuse_before_writing(self):
        result = subprocess.run(['python3', str(Path(__file__).with_name('release_prepare.py'))],
                                env={}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing release inputs', result.stderr)

    def test_partial_credentials_never_expose_values(self):
        with self.assertRaises(ValueError) as error:
            prepare.inputs({'KEYSTORE_PASSWORD': 'do-not-print-this'})
        self.assertNotIn('do-not-print-this', str(error.exception))
        self.assertIn('KEYSTORE_B64', str(error.exception))

    def test_java_property_escaping_preserves_password_characters(self):
        self.assertEqual(prepare.property_value(' x\\y\n=☃'), '\\ x\\\\y\\n\\=\\u2603')


if __name__ == '__main__':
    unittest.main()
