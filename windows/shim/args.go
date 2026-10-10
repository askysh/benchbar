package main

import (
	"fmt"
	"strings"
)

type parsedArgs struct {
	bools map[string]bool
	vals  map[string]string
	pos   []string
}

// parseFlags accepts the listed flags anywhere among the arguments.
// Value flags take "--name value" or "--name=value".
func parseFlags(args, boolFlags, valFlags []string) (*parsedArgs, error) {
	p := &parsedArgs{bools: map[string]bool{}, vals: map[string]string{}}
	in := func(list []string, s string) bool {
		for _, x := range list {
			if x == s {
				return true
			}
		}
		return false
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "-") || a == "-" {
			p.pos = append(p.pos, a)
			continue
		}
		name, val, hasVal := strings.Cut(a, "=")
		switch {
		case in(boolFlags, name) && !hasVal:
			p.bools[name] = true
		case in(valFlags, name):
			if !hasVal {
				if i+1 >= len(args) {
					return nil, fmt.Errorf("%s needs a value", name)
				}
				i++
				val = args[i]
			}
			p.vals[name] = val
		default:
			return nil, fmt.Errorf("unknown option %s", a)
		}
	}
	return p, nil
}
