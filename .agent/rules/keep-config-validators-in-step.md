# Keep the Config Validators in Step

Config is validated twice: by the server (`Offloader.Catalog` and its Dataset, Endpoint and
Key parsers) and by `offloader validate` (`tools/validate.go`, `tools/validate_endpoint.go`),
which users run in CI before a deploy. `dev/validation-cases.yml` holds both to the same
`[file, path, code]` findings; `server/test/offloader/validation_corpus_test.exs` and
`tools/validate_corpus_test.go` each check every case.

When you add or change a validation rule on either side, add a corpus case first. It fails on
the side you haven't changed yet; then make both pass. A parser must never crash on a
malformed shape (a string where a list belongs, a list where a mapping belongs): report
`invalid_type` for that field instead, and add a case for it.
