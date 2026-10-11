// probe reports what the running process can read, then optionally starts a
// child (spawn) or replaces itself (exec). It is installed as a root
// LaunchDaemon by run.sh to test Full Disk Access grants.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

var version = "dev"

// Files the job step creates or that exist on the image. The first is a
// control that needs no grant.
var checks = []string{
	"/etc/hosts",
	"/Library/Application Support/com.apple.TCC/TCC.db",
	"/Users/runner/Library/Application Support/com.apple.TCC/TCC.db",
	"/Users/runner/Library/Safari/probe.txt",
	"/Users/runner/Library/Mail/probe.txt",
	"/Users/runner/Library/Safari",
	"/Library/Preferences/com.apple.TimeMachine.plist",
}

func try(p string) string {
	fi, err := os.Stat(p)
	if err != nil {
		return "err " + err.Error()
	}
	if fi.IsDir() {
		if _, err := os.ReadDir(p); err != nil {
			return "denied " + err.Error()
		}
		return "ok"
	}
	f, err := os.Open(p)
	if err != nil {
		return "denied " + err.Error()
	}
	defer f.Close()
	if _, err := f.Read(make([]byte, 1)); err != nil {
		return "denied " + err.Error()
	}
	return "ok"
}

func main() {
	exe, _ := os.Executable()
	id := fmt.Sprintf("%s[%s]", exe, version)
	fmt.Printf("START %s pid=%d ppid=%d uid=%d\n", id, os.Getpid(), os.Getppid(), os.Getuid())
	for _, p := range checks {
		fmt.Printf("READ %s %q: %s\n", id, p, try(p))
	}
	if svc := os.Getenv("PROBE_KC"); svc != "" {
		out, err := exec.Command("/usr/bin/security", "find-generic-password", "-s", svc, "-w", "/Library/Keychains/System.keychain").CombinedOutput()
		res := strings.TrimSpace(string(out))
		if err != nil {
			res = fmt.Sprintf("FAIL %v: %s", err, res)
		} else {
			res = "OK value=" + res
		}
		fmt.Printf("KEYCHAIN %s %s\n", id, res)
	}
	args := os.Args[1:]
	if len(args) >= 2 {
		switch args[0] {
		case "spawn":
			cmd := exec.Command(args[1], args[2:]...)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			err := cmd.Run()
			code := 0
			var ee *exec.ExitError
			if errors.As(err, &ee) {
				code = ee.ExitCode()
			} else if err != nil {
				code = -1
			}
			fmt.Printf("CHILD %s %s exit=%d err=%v\n", id, args[1], code, err)
		case "exec":
			fmt.Printf("EXEC %s -> %s\n", id, args[1])
			err := syscall.Exec(args[1], args[1:], os.Environ())
			fmt.Printf("EXECFAIL %s %v\n", id, err)
		}
	}
	fmt.Printf("DONE %s\n", id)
}
