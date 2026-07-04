package main

// codes is a test helper: the machine-stable codes of a findings list, for
// asserting that a specific validation error was (or wasn't) reported.
func (fs findings) codes() []string {
	out := make([]string, len(fs))
	for i, f := range fs {
		out[i] = f.Code
	}
	return out
}
