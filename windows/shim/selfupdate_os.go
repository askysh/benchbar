package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// WebClient makes one GET request. followRedirects false returns a redirect
// as it is, with its Location.
type WebClient interface {
	Get(ctx context.Context, url string, followRedirects bool) (WebResponse, error)
}

// WebResponse is what self-update reads from an answer.
type WebResponse struct {
	Status   int
	Location string
	Body     []byte
}

// Launcher starts a program and waits for it to end.
type Launcher interface {
	Run(ctx context.Context, spec LaunchSpec) (exit int, err error)
}

// LaunchSpec is one program start. Env is the whole environment of the
// child. Stdin is nil for none.
type LaunchSpec struct {
	Path   string
	Args   []string
	Env    []string
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// webBodyLimit bounds what is read from GitHub: 30 releases with their
// assets are well under it.
const webBodyLimit = 8 << 20

type httpWeb struct{}

func (httpWeb) Get(ctx context.Context, u string, follow bool) (WebResponse, error) {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.Proxy = webProxy
	client := &http.Client{Transport: tr}
	if !follow {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return WebResponse{}, err
	}
	req.Header.Set("User-Agent", "benchbar.exe/"+version)
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := client.Do(req)
	if err != nil {
		return WebResponse{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, webBodyLimit))
	if err != nil {
		return WebResponse{}, err
	}
	return WebResponse{Status: resp.StatusCode, Location: resp.Header.Get("Location"), Body: body}, nil
}

// webProxy is HTTPS_PROXY and the rest of the proxy environment first, then
// the Windows proxy settings (Internet Options, the ones install.ps1 uses).
// A proxy auto config script and a proxy that wants your Windows sign in
// are not supported here; the error message says to set HTTPS_PROXY then.
func webProxy(req *http.Request) (*url.URL, error) {
	if u, err := http.ProxyFromEnvironment(req); u != nil || err != nil {
		return u, err
	}
	server, override, ok := systemProxySettings()
	if !ok {
		return nil, nil
	}
	return pickProxy(server, override, req.URL.Hostname()), nil
}

// pickProxy reads the Internet Options proxy: ProxyServer is "host:port" or
// "http=host:port;https=host:port"; ProxyOverride lists hosts that go
// direct, with * wildcards and <local> for names without a dot.
func pickProxy(server, override, host string) *url.URL {
	host = strings.ToLower(host)
	for _, o := range strings.Split(override, ";") {
		o = strings.ToLower(strings.TrimSpace(o))
		switch {
		case o == "":
		case o == "<local>":
			if !strings.Contains(host, ".") {
				return nil
			}
		default:
			if ok, _ := path.Match(o, host); ok {
				return nil
			}
		}
	}
	chosen := ""
	if strings.Contains(server, "=") {
		byScheme := map[string]string{}
		for _, part := range strings.Split(server, ";") {
			k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
			if ok {
				byScheme[strings.ToLower(k)] = strings.TrimSpace(v)
			}
		}
		chosen = byScheme["https"]
		if chosen == "" {
			chosen = byScheme["http"]
		}
	} else {
		chosen = strings.TrimSpace(server)
	}
	if chosen == "" {
		return nil
	}
	if !strings.Contains(chosen, "://") {
		chosen = "http://" + chosen
	}
	u, err := url.Parse(chosen)
	if err != nil || u.Host == "" {
		return nil
	}
	return u
}

type osLauncher struct{}

// Run waits for the program. Ctrl+C reaches the child from the console
// itself, so the shim only keeps it from ending the wait early.
func (osLauncher) Run(ctx context.Context, s LaunchSpec) (int, error) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt)
	defer signal.Stop(ch)
	cmd := exec.CommandContext(ctx, s.Path, s.Args...)
	cmd.Env = s.Env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = s.Stdin, s.Stdout, s.Stderr
	cmd.WaitDelay = 5 * time.Second
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	return -1, err
}

// windowsPowerShellPath is powershell.exe in the system folder, never one
// found earlier on PATH.
func windowsPowerShellPath() (string, error) {
	if dir := systemDir(); dir != "" {
		p := filepath.Join(dir, "WindowsPowerShell", "v1.0", "powershell.exe")
		if fileExists(p) {
			return p, nil
		}
	}
	return exec.LookPath("powershell.exe")
}
