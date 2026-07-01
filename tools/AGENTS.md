# tools - how we build

The tools are optional operator helpers around the primary self-hostable
Offloader container. They validate config and manifests, run endpoint smoke
tests, collect diagnostics, and produce redacted support bundles.

Do not make the product depend on tools for normal deployment. A standard V1
deployment must work by running the container with env vars and mounted config.

## Gate

Once the Go module exists, run from `tools/`:

```sh
gofmt -l -s .
go vet ./...
go mod tidy
git diff --exit-code go.mod go.sum
go test -race -count=1 ./...
```

## Style

- Use stdlib first.
- Keep commands small and explicit.
- Never print secrets by default.
- Support bundle export must redact before writing artifacts.
- Config validation errors should include file path, field path, and an operator
  hint.
