package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCLIRefusesCommandRelayWithoutConnecting(t *testing.T) {
	for _, network := range []string{"tcp", "unix"} {
		t.Run(network, func(t *testing.T) {
			address := "127.0.0.1:0"
			if network == "unix" {
				// Keep below the Unix socket path limit on macOS.
				dir, err := os.MkdirTemp("/tmp", "c11d-")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.RemoveAll(dir) })
				address = filepath.Join(dir, "command.sock")
			}
			listener, err := net.Listen(network, address)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			address = listener.Addr().String()

			t.Setenv("C11_SOCKET_PATH", address)
			t.Setenv("CMUX_SOCKET_PATH", address)
			t.Setenv("CMUX_RELAY_ID", "test-relay")
			t.Setenv("CMUX_RELAY_TOKEN", "unused")
			home := t.TempDir()
			t.Setenv("HOME", home)
			if err := os.MkdirAll(filepath.Join(home, ".cmux"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(home, ".cmux", "socket_addr"), []byte(address), 0o600); err != nil {
				t.Fatal(err)
			}

			for _, args := range [][]string{
				{"--socket", address, "ping"},
				{"--socket", address, "--json", "list-workspaces"},
				{"--socket", address, "rpc", "system.capabilities"},
				{"--socket", address, "browser", "get-url"},
				{"ping"},
			} {
				if code := runCLI(args); code != 1 {
					t.Fatalf("runCLI(%q) = %d, want 1", args, code)
				}
			}
			t.Setenv("C11_SOCKET_PATH", "")
			if code := runCLI([]string{"ping"}); code != 1 {
				t.Fatalf("legacy environment invocation = %d, want 1", code)
			}
			t.Setenv("CMUX_SOCKET_PATH", "")
			if code := runCLI([]string{"ping"}); code != 1 {
				t.Fatalf("saved socket invocation = %d, want 1", code)
			}

			deadline := time.Now().Add(25 * time.Millisecond)
			switch listener := listener.(type) {
			case *net.TCPListener:
				err = listener.SetDeadline(deadline)
			case *net.UnixListener:
				err = listener.SetDeadline(deadline)
			}
			if err != nil {
				t.Fatal(err)
			}
			conn, err := listener.Accept()
			if conn != nil {
				conn.Close()
				t.Fatal("disabled CLI connected to the command socket")
			}
			if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
				t.Fatalf("Accept = %v, want timeout without a connection", err)
			}
		})
	}
}

func TestCLIHelpAndNoArgs(t *testing.T) {
	for _, arg := range []string{"--help", "-h", "help"} {
		if code := runCLI([]string{arg}); code != 0 {
			t.Errorf("runCLI(%q) = %d, want 0", arg, code)
		}
	}
	if code := runCLI(nil); code != 2 {
		t.Errorf("runCLI(nil) = %d, want 2", code)
	}
}

func TestRemoteCLIInvocationDispatch(t *testing.T) {
	for _, argv0 := range []string{"c11", "cmux", "c11d-remote-current", "cmuxd-remote-current"} {
		if !shouldRunCLIForInvocation(argv0, []string{"ping"}) {
			t.Errorf("%s ping must use the disabled CLI entry point", argv0)
		}
	}
	for _, command := range []string{"version", "serve", "cli"} {
		if shouldRunCLIForInvocation("c11d-remote", []string{command}) {
			t.Errorf("daemon command %s must retain daemon dispatch", command)
		}
	}
}
