package main

import (
	"encoding/json"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// dev/validation-cases.yml lists broken projects with the exact findings the server reports
// (server/test/offloader/validation_corpus_test.exs checks that side). `offloader validate` must
// report the same ones, so the CLI and the container can't drift apart silently.
func TestValidateMatchesServerCorpus(t *testing.T) {
	b, err := os.ReadFile("../dev/validation-cases.yml")
	if err != nil {
		t.Fatal(err)
	}
	var corpus struct {
		Base struct {
			Project, Dataset, Endpoint map[string]any
		}
		Cases []struct {
			Name                       string
			Project, Dataset, Endpoint map[string]any
			Files                      map[string]string
			Expect                     [][]string
		}
	}
	if err := yaml.Unmarshal(b, &corpus); err != nil {
		t.Fatal(err)
	}

	for _, c := range corpus.Cases {
		t.Run(c.Name, func(t *testing.T) {
			files := map[string]string{
				"offloader.yml":      overlay(t, corpus.Base.Project, c.Project),
				"datasets/usage.yml": overlay(t, corpus.Base.Dataset, c.Dataset),
				"endpoints/e.yml":    overlay(t, corpus.Base.Endpoint, c.Endpoint),
			}
			for rel, body := range c.Files {
				files[rel] = body
			}

			got := [][]string{}
			for _, f := range validateProject(writeProject(t, files)) {
				got = append(got, []string{f.File, f.Path, f.Code})
			}
			want := c.Expect
			if want == nil {
				want = [][]string{}
			}
			sortTriples(got)
			sortTriples(want)
			if !reflect.DeepEqual(got, want) {
				t.Errorf("findings differ from the server's\n got: %v\nwant: %v", got, want)
			}
		})
	}
}

// A case's top-level keys replace the base's; a null drops the key. Written as JSON, which
// every YAML parser reads.
func overlay(t *testing.T, base, changes map[string]any) string {
	merged := map[string]any{}
	for k, v := range base {
		merged[k] = v
	}
	for k, v := range changes {
		merged[k] = v
	}
	for k, v := range merged {
		if v == nil {
			delete(merged, k)
		}
	}
	b, err := json.Marshal(merged)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func sortTriples(list [][]string) {
	sort.Slice(list, func(i, j int) bool {
		return strings.Join(list[i], "\x00") < strings.Join(list[j], "\x00")
	})
}
