# Capture Expected Test Logs

Tests that intentionally exercise warning or error paths must not dump expected
logs into normal test output. Keep ExUnit log capture enabled for the suite, and
use explicit `capture_log` around any test that needs to assert on log text.

If noisy output appears during `mix test` or `make check`, treat it as test
hygiene work: capture expected logs, then investigate any remaining noise as a
real race, unexpected failure path, or missing synchronization.
