package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	repoWeb         = "https://github.com/askysh/benchbar"
	releasesAPIURL  = "https://api.github.com/repos/askysh/benchbar/releases?per_page=30"
	latestPageURL   = repoWeb + "/releases/latest"
	releasesPageURL = repoWeb + "/releases"
	// installerPS1URL is the one line installer the docs give. It is main's,
	// so it is the newest installer, and it installs any release by -Version.
	installerPS1URL = "https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1"
	oneLineInstall  = "irm " + installerPS1URL + " | iex"
)

// webTimeout bounds the release lookup. A variable so a test can shorten it.
var webTimeout = 10 * time.Second

// plainVersionRE is a release tag: X.Y.Z with an optional v. install.ps1
// -Version takes only this form, so a tag of any other form is skipped.
var plainVersionRE = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)$`)

// latestPageTagRE reads the tag out of the Location of the release page.
var latestPageTagRE = regexp.MustCompile(`/releases/tag/(v\d+\.\d+\.\d+)$`)

type ghAsset struct {
	Name string `json:"name"`
}

type ghRelease struct {
	TagName     string    `json:"tag_name"`
	Draft       bool      `json:"draft"`
	Prerelease  bool      `json:"prerelease"`
	PublishedAt string    `json:"published_at"`
	HTMLURL     string    `json:"html_url"`
	Assets      []ghAsset `json:"assets"`
}

// latestRelease is the release self-update would install.
type latestRelease struct {
	Version string
	URL     string
	// Source is "api", or "release_page" when the API was rate limited and
	// the release page's redirect named the tag (its Windows zip is then
	// not confirmed, as in install.ps1).
	Source string
	Note   string
}

// errNoWindowsBuild is a list of releases without one for this CPU.
var errNoWindowsBuild = errors.New("no published release has a Windows build for this PC yet")

// windowsZipName and windowsSumsName are the asset names install.ps1 looks for.
func windowsZipName(v, arch string) string { return fmt.Sprintf("benchbar-windows-%s-%s.zip", v, arch) }
func windowsSumsName(v string) string      { return fmt.Sprintf("benchbar-windows-%s-SHA256SUMS.txt", v) }

// pickRelease mirrors install.ps1's choice, so the version the check names
// is the version the installer would take: published releases only (no
// draft, no prerelease), newest published_at first, and the first one that
// has both the Windows zip for this CPU and its checksums file. The Windows
// zips are attached to a shared Mac and Windows release, sometimes later
// than the release itself, so GitHub's "latest" alone is not enough. One
// difference: a tag that is not X.Y.Z is skipped here, since -Version
// would refuse it.
func pickRelease(body []byte, arch string) (latestRelease, error) {
	var list []ghRelease
	if err := json.Unmarshal(body, &list); err != nil {
		return latestRelease{}, fmt.Errorf("GitHub's answer is not a release list: %v", err)
	}
	sort.SliceStable(list, func(i, j int) bool { return publishedAt(list[i]).After(publishedAt(list[j])) })
	for _, r := range list {
		if r.Draft || r.Prerelease {
			continue
		}
		m := plainVersionRE.FindStringSubmatch(r.TagName)
		if m == nil {
			continue
		}
		v := strings.TrimPrefix(r.TagName, "v")
		zip, sums := false, false
		for _, a := range r.Assets {
			zip = zip || a.Name == windowsZipName(v, arch)
			sums = sums || a.Name == windowsSumsName(v)
		}
		if zip && sums {
			url := r.HTMLURL
			if url == "" {
				url = releasesPageURL + "/tag/v" + v
			}
			return latestRelease{Version: v, URL: url, Source: "api"}, nil
		}
	}
	return latestRelease{}, errNoWindowsBuild
}

func publishedAt(r ghRelease) time.Time {
	t, _ := time.Parse(time.RFC3339, r.PublishedAt)
	return t
}

// findLatest asks GitHub for the release to install, in one request, with
// the release page as the fallback when the API is rate limited (as in
// install.ps1).
func findLatest(sys *System, arch string) (latestRelease, error) {
	if sys.Web == nil {
		return latestRelease{}, errors.New("no network client")
	}
	ctx, cancel := context.WithTimeout(sys.Ctx, webTimeout)
	defer cancel()
	resp, err := sys.Web.Get(ctx, releasesAPIURL, true)
	if err != nil {
		return latestRelease{}, webError(ctx, err)
	}
	switch {
	case resp.Status == 200:
		return pickRelease(resp.Body, arch)
	case resp.Status == 403 || resp.Status == 429:
		page, perr := sys.Web.Get(ctx, latestPageURL, false)
		if perr == nil && page.Status >= 300 && page.Status < 400 {
			if m := latestPageTagRE.FindStringSubmatch(page.Location); m != nil {
				v := strings.TrimPrefix(m[1], "v")
				return latestRelease{Version: v, URL: releasesPageURL + "/tag/" + m[1], Source: "release_page",
					Note: "GitHub's API refused the request (rate limit), so the release page named " + v + "; whether it has a Windows build for this PC yet was not checked"}, nil
			}
		}
		return latestRelease{}, errors.New("GitHub refused the request (rate limit). Try again in a few minutes")
	default:
		return latestRelease{}, fmt.Errorf("GitHub answered HTTP %d", resp.Status)
	}
}

func webError(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("GitHub did not answer within %d s (offline, or a proxy this check cannot use)", int(webTimeout.Seconds()))
	}
	return fmt.Errorf("could not reach GitHub (offline, or a proxy this check cannot use; set HTTPS_PROXY for one): %v", err)
}

// newerVersion is true when have is a release older than want. A dev build
// is never offered an update by the check: it was not installed from a
// release.
func newerVersion(have, want string) bool {
	h, ok1 := parsePlainVersion(have)
	w, ok2 := parsePlainVersion(want)
	return ok1 && ok2 && versionLess(h, w)
}

func parsePlainVersion(s string) ([3]int, bool) {
	if !plainVersionRE.MatchString(s) {
		return [3]int{}, false
	}
	return releaseVersion(s)
}
