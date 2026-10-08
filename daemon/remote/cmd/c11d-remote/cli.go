package main

import (
	"fmt"
	"os"
)

const remoteCLIDisabledMessage = "c11 commands are not available over c11 ssh in this version"

// Keep the remote CLI entry points available for existing shell wrappers, but
// never connect to a command socket, including an explicitly supplied address.
func runCLI(args []string) int {
	if len(args) == 0 {
		cliUsage()
		return 2
	}
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h", "help":
			cliUsage()
			return 0
		}
	}
	fmt.Fprintln(os.Stderr, remoteCLIDisabledMessage)
	return 1
}

func cliUsage() {
	fmt.Fprintln(os.Stderr, "Usage: c11 --help")
	fmt.Fprintln(os.Stderr, remoteCLIDisabledMessage)
}
