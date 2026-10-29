package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

// The endpoint rules, ported from Offloader.Catalog.Endpoint.parse/3
// (server/lib/offloader/catalog/endpoint.ex). dev/validation-cases.yml pins both to the same
// findings: add a case there whenever a rule changes on either side.

var (
	endpointKeys  = []string{"name", "version", "owner", "description", "dataset", "serving_mode", "freshness", "tenant", "params", "combinations", "query", "columns", "pagination", "cache"}
	servingModes  = []string{"local_table", "remote_scan"}
	paramTypeList = []string{"string", "integer", "date", "enum", "boolean"}
	aggs          = []string{"sum", "avg", "min", "max", "count"}
	filterOps     = []string{"eq", "gte", "lte"}
	orderDirs     = []string{"asc", "desc"}
	cachePolicies = []string{"none", "snapshot"}
	// The column types each param type can bind (duckdbex binds a param by the column's type).
	filterable = map[string][]string{
		"string":  {"VARCHAR"},
		"enum":    {"VARCHAR"},
		"integer": {"INTEGER", "BIGINT", "DOUBLE"},
		"date":    {"DATE", "TIMESTAMP"},
		"boolean": {"BOOLEAN"},
	}
)

// readYAMLValue decodes a YAML file the way the server's parser (yamerl, YAML 1.2 core schema)
// does: timestamps stay strings and mapping keys keep their own type, so both validators judge
// the same values.
func readYAMLValue(path, rel string, out *findings) (any, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		out.add(rel, "", "yaml_error", "could not read file: "+err.Error(), "")
		return nil, false
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(b, &doc); err != nil {
		out.add(rel, "", "yaml_error", "could not parse YAML: "+err.Error(), "")
		return nil, false
	}
	return yamlValue(&doc), true
}

func yamlValue(n *yaml.Node) any {
	switch n.Kind {
	case yaml.DocumentNode:
		if len(n.Content) == 0 {
			return nil
		}
		return yamlValue(n.Content[0])
	case yaml.AliasNode:
		return yamlValue(n.Alias)
	case yaml.MappingNode:
		m := map[any]any{}
		for i := 0; i+1 < len(n.Content); i += 2 {
			m[yamlValue(n.Content[i])] = yamlValue(n.Content[i+1])
		}
		return m
	case yaml.SequenceNode:
		list := make([]any, 0, len(n.Content))
		for _, c := range n.Content {
			list = append(list, yamlValue(c))
		}
		return list
	}
	if n.Tag == "!!str" || n.Tag == "!!timestamp" {
		return n.Value
	}
	var v any
	if err := n.Decode(&v); err != nil {
		return n.Value
	}
	return v
}

// endpointCheck files findings for one endpoint file, judged against its dataset.
type endpointCheck struct {
	checker
	ds    datasetYML
	types map[string]string
}

// validateEndpoint reports every problem in one endpoint file (a mapping) whose dataset exists.
func validateEndpoint(rel string, raw map[any]any, ds datasetYML, out *findings) {
	c := endpointCheck{checker: checker{rel: rel, out: out}, ds: ds, types: map[string]string{}}
	for _, col := range ds.Schema {
		c.types[col.Name] = col.Type
	}

	params, _ := raw["params"].([]any)
	var paramNames []any
	paramTypes := map[string]any{}
	for _, p := range params {
		if m, ok := p.(map[any]any); ok {
			if name, ok := m["name"].(string); ok {
				paramNames = append(paramNames, name)
				paramTypes[name] = m["type"]
			}
		}
	}
	query, _ := raw["query"].(map[any]any)
	selects, _ := query["select"].([]any)
	var selectAs []any
	for _, s := range selects {
		if m, ok := s.(map[any]any); ok {
			if as, ok := m["as"].(string); ok {
				selectAs = append(selectAs, as)
			}
		}
	}

	c.unknownKeys(raw, endpointKeys, "")
	c.identifier(raw["name"], "name")
	if _, ok := asInt(raw["version"]); !ok {
		c.add("version", "invalid_type", "version must be an integer", "")
	}
	if s, ok := raw["owner"].(string); !ok || s == "" {
		c.add("owner", "missing", "owner is required", "")
	}
	if m, ok := raw["serving_mode"]; ok && m != nil && !isOneOf(m, servingModes) {
		c.add("serving_mode", "invalid_value", fmt.Sprintf("serving_mode %v is invalid", m), "one of: "+strings.Join(servingModes, ", "))
	}
	c.freshness(raw["freshness"])
	c.tenant(raw)
	if p, ok := raw["params"]; ok && p != nil {
		if _, list := p.([]any); !list {
			c.add("params", "invalid_type", "params must be a list", "")
		}
	}
	c.params(params)
	c.defaultRanges(params, query)
	c.combinations(raw["combinations"], paramNames)
	if q, ok := raw["query"].(map[any]any); ok {
		c.unknownKeys(q, []string{"group_by", "select", "filters", "order_by"}, "query")
		c.selects(q, selectAs)
		c.filters(q["filters"], paramTypes)
		c.orderBy(q["order_by"], selectAs)
	} else {
		c.add("query", "missing", "query is required", "")
	}
	c.columns(raw["columns"], selectAs)
	c.pagination(raw["pagination"])
	c.cache(raw["cache"])
}

func (c endpointCheck) freshness(v any) {
	switch f := v.(type) {
	case nil:
	case map[any]any:
		c.unknownKeys(f, []string{"max_staleness_minutes"}, "freshness")
		if n, ok := asInt(f["max_staleness_minutes"]); !ok || n <= 0 {
			c.add("freshness.max_staleness_minutes", "invalid_value", "must be a positive integer", "")
		}
	default:
		c.add("freshness", "invalid_type", "freshness must be a mapping", "")
	}
}

// A tenant dataset requires the endpoint to bind its column; a non-tenant dataset forbids a
// binding. The case order mirrors the server's `tenant_errors`.
func (c endpointCheck) tenant(raw map[any]any) {
	t, present := raw["tenant"]
	tm, isMap := t.(map[any]any)
	_, hasColumn := tm["column"]
	dsCol := c.ds.TenantColumn
	switch {
	case isMap && hasColumn && dsCol != "":
		c.unknownKeys(tm, []string{"column"}, "tenant")
		col, ok := tm["column"].(string)
		switch {
		case !ok || !safeColumn(col):
			c.add("tenant.column", "unsafe_identifier", fmt.Sprintf("tenant.column %v is not a safe identifier", tm["column"]), "")
		case col != dsCol:
			c.add("tenant.column", "tenant_mismatch", fmt.Sprintf("tenant.column %q must equal the dataset tenant_column %q", col, dsCol), "the tenant filter is fixed by the dataset; it cannot be re-pointed per endpoint")
		}
	case (!present || t == nil) && dsCol != "":
		c.add("tenant", "missing", "tenant binding is required for a tenant dataset", fmt.Sprintf("bind %q, or drop tenant_column from the dataset to serve it publicly", dsCol))
	case !present || t == nil:
	case dsCol == "":
		c.add("tenant", "tenant_forbidden", fmt.Sprintf("dataset %q has no tenant_column, so this endpoint cannot bind a tenant", c.ds.ID), "remove the tenant binding, or add tenant_column to the dataset")
	default:
		c.add("tenant", "invalid_type", "tenant must be a mapping with a column", "")
	}
}

func (c endpointCheck) params(params []any) {
	var names []any
	for _, p := range params {
		if m, ok := p.(map[any]any); ok {
			if name, ok := m["name"].(string); ok {
				names = append(names, name)
			}
		}
	}
	if d := duplicateValues(names); len(d) > 0 {
		c.add("params", "duplicate_param", "duplicate param name(s): "+joinAny(d), "")
	}
	for i, p := range params {
		path := fmt.Sprintf("params[%d]", i)
		m, ok := p.(map[any]any)
		if !ok {
			c.add(path, "invalid_type", "param must be a mapping", "")
			continue
		}
		c.unknownKeys(m, []string{"name", "type", "required", "default", "enum", "max", "aliases"}, path)
		if name, ok := m["name"].(string); !ok || !safeIdent(name) {
			c.add(path+".name", "unsafe_identifier", fmt.Sprintf("param name %v is missing or not a safe identifier", m["name"]), "")
		}
		c.paramType(m, path)
		c.paramDefault(m, path)
		c.aliases(m, path)
	}
}

func (c endpointCheck) paramType(p map[any]any, path string) {
	switch t := p["type"]; {
	case t == "enum":
		if list, ok := p["enum"].([]any); !ok || len(list) == 0 {
			c.add(path+".enum", "missing", "enum params must list their allowed values", "")
		}
	case isOneOf(t, paramTypeList):
	default:
		c.add(path+".type", "invalid_value", fmt.Sprintf("type %v is invalid", t), "one of: "+strings.Join(paramTypeList, ", "))
	}
}

// A declared default must satisfy the param's own type.
func (c endpointCheck) paramDefault(p map[any]any, path string) {
	d := p["default"]
	if d == nil {
		return
	}
	valid := true
	switch p["type"] {
	case "string":
		_, valid = d.(string)
	case "date":
		s, ok := d.(string)
		valid = ok && isISODate(s)
	case "integer":
		n, ok := integerDefault(d)
		max, hasMax := asInt(p["max"])
		valid = ok && (!hasMax || n <= max)
	case "enum":
		list, _ := p["enum"].([]any)
		valid = containsAny(list, d)
	case "boolean":
		_, valid = d.(bool)
	}
	if !valid {
		c.add(path+".default", "invalid_default", fmt.Sprintf("default %v does not satisfy the param's type", d), "the default is used verbatim when the param is omitted")
	}
}

func (c endpointCheck) aliases(p map[any]any, path string) {
	a, present := p["aliases"]
	if !present || a == nil {
		return
	}
	apath := path + ".aliases"
	m, ok := a.(map[any]any)
	if !ok {
		c.add(apath, "invalid_type", "aliases must be a mapping", "")
		return
	}
	for k, v := range m {
		_, ks := k.(string)
		_, vs := v.(string)
		if !ks || !vs {
			c.add(apath, "invalid_type", fmt.Sprintf("alias %v must map a string to a string", k), "")
		}
	}
	if t := p["type"]; t != "string" && t != "enum" {
		c.add(apath, "invalid_value", fmt.Sprintf("aliases are not supported on %v params", t), "only string and enum params can declare aliases")
	}
	if list, ok := p["enum"].([]any); ok && p["type"] == "enum" {
		for k, v := range m {
			if !containsAny(list, v) {
				c.add(apath, "invalid_value", fmt.Sprintf("alias %v maps to %v, which is not an allowed enum value", k, v), "")
			}
		}
	}
}

// An integer default binds like a request value, so it must fit every column it filters.
func (c endpointCheck) defaultRanges(params []any, query map[any]any) {
	filters, _ := query["filters"].([]any)
	for i, p := range params {
		m, ok := p.(map[any]any)
		if !ok || m["type"] != "integer" {
			continue
		}
		n, ok := integerDefault(m["default"])
		if !ok {
			continue
		}
		lo, hi := int64(math.MinInt64), int64(math.MaxInt64)
		for _, f := range filters {
			if fm, ok := f.(map[any]any); ok && same(fm["param"], m["name"]) {
				if col, ok := fm["column"].(string); ok && c.types[col] == "INTEGER" {
					lo, hi = max(lo, math.MinInt32), min(hi, math.MaxInt32)
				}
			}
		}
		if n < lo || n > hi {
			c.add(fmt.Sprintf("params[%d].default", i), "invalid_default", fmt.Sprintf("default %d is outside %d..%d, the range of the columns it filters", n, lo, hi), "the default is used verbatim when the param is omitted")
		}
	}
}

func (c endpointCheck) combinations(v any, paramNames []any) {
	if v == nil {
		return
	}
	combos, ok := v.([]any)
	if !ok {
		c.add("combinations", "invalid_type", "combinations must be a list of param-name lists", "")
		return
	}
	for i, combo := range combos {
		path := fmt.Sprintf("combinations[%d]", i)
		names, ok := combo.([]any)
		if !ok {
			c.add(path, "invalid_type", "combination must be a list of param names", "")
			continue
		}
		for _, name := range names {
			if !containsAny(paramNames, name) {
				c.add(path, "unknown_param", fmt.Sprintf("combination references param %v which is not declared", name), "")
			}
		}
		if d := duplicateValues(names); len(d) > 0 {
			c.add(path, "duplicate_param", "duplicate name(s): "+joinAny(d), "")
		}
	}
}

func (c endpointCheck) selects(q map[any]any, selectAs []any) {
	selects, ok := q["select"].([]any)
	if !ok || len(selects) == 0 {
		c.add("query.select", "missing", "query.select is required and must be a non-empty list", "")
		return
	}
	if d := duplicateValues(selectAs); len(d) > 0 {
		c.add("query.select", "duplicate_column", "duplicate output column(s): "+joinAny(d), "")
	}
	for i, s := range selects {
		path := fmt.Sprintf("query.select[%d]", i)
		m, ok := s.(map[any]any)
		if !ok {
			c.add(path, "invalid_type", "select item must be a mapping", "")
			continue
		}
		c.unknownKeys(m, []string{"as", "column", "agg"}, path)
		if as, ok := m["as"].(string); !ok || !safeColumn(as) {
			c.add(path+".as", "unsafe_identifier", fmt.Sprintf("%s.as %v is missing or not a safe identifier", path, m["as"]), "")
		}
		c.columnInDataset(m["column"], path+".column")
		if agg := m["agg"]; agg != nil {
			if !isOneOf(agg, aggs) {
				c.add(path+".agg", "invalid_value", fmt.Sprintf("agg %v is invalid", agg), "one of: "+strings.Join(aggs, ", "))
			}
			if col, ok := m["column"].(string); ok && c.types[col] == "JSON" {
				c.add(path+".agg", "invalid_agg_on_json", fmt.Sprintf("column %q is JSON (nested) and cannot be aggregated", col), "select it without agg to serve the nested document")
			}
		}
	}
	c.groupBy(q["group_by"], selects, selectAs)
}

// Grouping is explicit: with group_by every plain output column must be grouped, and every
// group_by name must be an output column; without it, nothing may be aggregated.
func (c endpointCheck) groupBy(v any, selects, selectAs []any) {
	if v == nil {
		v = []any{}
	}
	groupBy, ok := v.([]any)
	if !ok {
		c.add("query.group_by", "invalid_type", "group_by must be a list", "")
		return
	}
	var plain []any
	hasAgg := false
	for _, s := range selects {
		if m, ok := s.(map[any]any); ok {
			if m["agg"] != nil {
				hasAgg = true
			} else if as, ok := m["as"].(string); ok {
				plain = append(plain, as)
			}
		}
	}
	if len(groupBy) == 0 {
		if hasAgg {
			c.add("query.group_by", "missing_group_by", "aggregations require group_by", "list the grouping output columns, or remove agg")
		}
		return
	}
	var unknown []any
	for _, g := range groupBy {
		if !containsAny(selectAs, g) {
			unknown = append(unknown, g)
		}
	}
	if len(unknown) > 0 {
		c.add("query.group_by", "unknown_column", "group_by names not in select: "+joinAny(unknown), "")
	}
	if ungrouped := subtract(plain, groupBy); len(ungrouped) > 0 {
		c.add("query.group_by", "ungrouped_column", "non-aggregated select columns must be grouped: "+joinAny(ungrouped), "")
	}
}

func (c endpointCheck) filters(v any, paramTypes map[string]any) {
	if v == nil {
		return
	}
	filters, ok := v.([]any)
	if !ok {
		c.add("query.filters", "invalid_type", "filters must be a list", "")
		return
	}
	for i, f := range filters {
		path := fmt.Sprintf("query.filters[%d]", i)
		m, ok := f.(map[any]any)
		if !ok {
			c.add(path, "invalid_type", "filter must be a mapping", "")
			continue
		}
		c.unknownKeys(m, []string{"column", "op", "param"}, path)
		c.columnInDataset(m["column"], path+".column")
		if col, ok := m["column"].(string); ok && c.ds.TenantColumn != "" && col == c.ds.TenantColumn {
			c.add(path+".column", "tenant_filter_forbidden", fmt.Sprintf("filters may not target the tenant column %q", col), "the tenant filter is inserted from the API key; it cannot be a request filter")
		}
		op := m["op"]
		if !isOneOf(op, filterOps) {
			c.add(path+".op", "invalid_value", fmt.Sprintf("op %v is invalid", op), "one of: "+strings.Join(filterOps, ", "))
		}
		name, isName := m["param"].(string)
		ptype, declared := paramTypes[name]
		if !isName || !declared {
			c.add(path+".param", "unknown_param", fmt.Sprintf("filter references param %v which is not declared", m["param"]), "")
		}
		_, hasColumn := m["column"]
		_, hasParam := m["param"]
		col, _ := m["column"].(string)
		if fits, known := filterable[fmt.Sprint(ptype)]; known && hasColumn && hasParam && isName {
			if ctype, ok := c.types[col]; ok && !contains(fits, ctype) {
				c.add(path+".param", "incompatible_filter", fmt.Sprintf("%v param %q cannot filter %s column %q", ptype, name, ctype, col), filterHint(ctype))
			}
		}
		if isOneOf(op, filterOps) && op != "eq" && isName && ptype == "boolean" {
			c.add(path+".op", "incompatible_filter", fmt.Sprintf("op %v cannot compare boolean param %q", op, name), "boolean params filter with op: eq")
		}
	}
}

func filterHint(ctype string) string {
	var fit []string
	for _, ptype := range []string{"date", "enum", "integer", "string", "boolean"} {
		if contains(filterable[ptype], ctype) {
			fit = append(fit, ptype)
		}
	}
	if len(fit) == 0 {
		return ctype + " columns cannot be filtered"
	}
	return ctype + " columns take " + strings.Join(fit, " or ") + " params"
}

func (c endpointCheck) orderBy(v any, selectAs []any) {
	if v == nil {
		return
	}
	orders, ok := v.([]any)
	if !ok {
		c.add("query.order_by", "invalid_type", "order_by must be a list", "")
		return
	}
	for i, o := range orders {
		path := fmt.Sprintf("query.order_by[%d]", i)
		m, ok := o.(map[any]any)
		if !ok {
			c.add(path, "invalid_type", "order_by item must be a mapping", "")
			continue
		}
		c.unknownKeys(m, []string{"column", "dir"}, path)
		if col, ok := m["column"].(string); !ok || !containsAny(selectAs, col) {
			c.add(path+".column", "unknown_column", fmt.Sprintf("order_by column %v must be an output column (a select `as`)", m["column"]), "")
		}
		if dir := m["dir"]; dir != nil && !isOneOf(dir, orderDirs) {
			c.add(path+".dir", "invalid_value", fmt.Sprintf("dir %v is invalid", dir), "asc or desc")
		}
	}
}

func (c endpointCheck) columns(v any, selectAs []any) {
	cols, ok := v.([]any)
	if !ok || len(cols) == 0 {
		c.add("columns", "missing", "columns allowlist is required and must be a non-empty list", "")
		return
	}
	if extra := subtract(cols, selectAs); len(extra) > 0 {
		c.add("columns", "column_not_selected", "allowlist columns not produced by select: "+joinAny(extra), "")
	}
	if missing := subtract(selectAs, cols); len(missing) > 0 {
		c.add("columns", "column_not_allowlisted", "select produces columns missing from the allowlist: "+joinAny(missing), "every response column must be explicitly allowlisted")
	}
}

func (c endpointCheck) pagination(v any) {
	switch p := v.(type) {
	case nil:
	case map[any]any:
		c.unknownKeys(p, []string{"default_limit", "max_limit"}, "pagination")
		def, okDef := asInt(p["default_limit"])
		max, okMax := asInt(p["max_limit"])
		switch {
		case !okDef || def <= 0:
			c.add("pagination.default_limit", "invalid_value", "must be a positive integer", "")
		case !okMax || max <= 0:
			c.add("pagination.max_limit", "invalid_value", "must be a positive integer", "")
		case def > max:
			c.add("pagination.default_limit", "invalid_value", fmt.Sprintf("default_limit %d exceeds max_limit %d", def, max), "")
		}
	default:
		c.add("pagination", "invalid_type", "pagination must be a mapping", "")
	}
}

func (c endpointCheck) cache(v any) {
	if v == nil {
		return
	}
	m, ok := v.(map[any]any)
	policy, hasPolicy := m["policy"]
	if !ok || !hasPolicy {
		c.add("cache", "invalid_type", "cache must be a mapping with a policy", "")
		return
	}
	c.unknownKeys(m, []string{"policy"}, "cache")
	if !isOneOf(policy, cachePolicies) {
		c.add("cache.policy", "invalid_value", fmt.Sprintf("cache.policy %v is invalid", policy), "one of: "+strings.Join(cachePolicies, ", "))
	}
}

func (c endpointCheck) columnInDataset(v any, path string) {
	col, ok := v.(string)
	switch {
	case !ok || !safeColumn(col):
		c.add(path, "unsafe_identifier", fmt.Sprintf("column %v is missing or not a safe identifier", v), "")
	case c.types[col] == "":
		c.add(path, "unknown_column", fmt.Sprintf("column %q is not in dataset %q", col, c.ds.ID), "")
	}
}

// ── value helpers ────────────────────────────────────────────────────────────

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func isOneOf(v any, allowed []string) bool {
	s, ok := v.(string)
	return ok && contains(allowed, s)
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func containsAny(list []any, v any) bool {
	for _, x := range list {
		if same(x, v) {
			return true
		}
	}
	return false
}

// same compares decoded YAML scalars by value and type, as the server's `===` does.
func same(a, b any) bool {
	switch a.(type) {
	case map[any]any, []any:
		return false
	}
	switch b.(type) {
	case map[any]any, []any:
		return false
	}
	return a == b
}

// subtract is the server's list difference (`--`): each element of b removes one match from a.
func subtract(a, b []any) []any {
	left := append([]any(nil), a...)
	for _, x := range b {
		for i, y := range left {
			if same(x, y) {
				left = append(left[:i], left[i+1:]...)
				break
			}
		}
	}
	return left
}

func duplicateValues(list []any) []any {
	var seen, dups []any
	for _, v := range list {
		if containsAny(seen, v) {
			if !containsAny(dups, v) {
				dups = append(dups, v)
			}
		} else {
			seen = append(seen, v)
		}
	}
	return dups
}

func joinAny(list []any) string {
	parts := make([]string, len(list))
	for i, v := range list {
		parts[i] = fmt.Sprint(v)
	}
	return strings.Join(parts, ", ")
}

func asInt(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int64:
		return n, true
	case uint64:
		if n > math.MaxInt64 {
			return math.MaxInt64, true
		}
		return int64(n), true
	}
	return 0, false
}

// An integer default is an integer or a string that parses as one, as on the server.
func integerDefault(v any) (int64, bool) {
	if n, ok := asInt(v); ok {
		return n, true
	}
	if s, ok := v.(string); ok {
		n, err := strconv.ParseInt(s, 10, 64)
		return n, err == nil
	}
	return 0, false
}

func isISODate(s string) bool {
	for _, layout := range []string{"2006-01-02", "20060102"} {
		if _, err := time.Parse(layout, s); err == nil {
			return true
		}
	}
	return false
}
